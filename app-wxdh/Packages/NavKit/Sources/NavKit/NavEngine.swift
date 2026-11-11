import CoreKit
import CoreLocation
import Foundation

/// 实时会话（NAV-37：一个活动会话，终态只写一次）
public struct NavSession: Identifiable, Equatable {
    public let id: String
    public var mode: TravelMode
    public var destination: Place
    public var origin: Place
    public var route: RouteOption
    public var startedAt: Date
    public var terminalReason: TerminalReason?

    public enum TerminalReason: String, Equatable {
        case arrived, exited, interrupted
    }

    public static func == (lhs: NavSession, rhs: NavSession) -> Bool { lhs.id == rhs.id }
}

/// 导航引擎：路径匹配、下一动作推进、偏航重算、到达/退出终态、旧回调隔离
@MainActor
public final class NavEngine: ObservableObject {
    // MARK: - 对外状态

    @Published public private(set) var phase: NavPhase = .idle
    @Published public private(set) var session: NavSession?
    @Published public private(set) var routes: [RouteOption] = []
    @Published public private(set) var selectedRouteId: String?
    @Published public private(set) var currentStepIndex: Int = 0
    @Published public private(set) var distanceToManeuver: Double = 0
    @Published public private(set) var remainingDistance: Double = 0
    @Published public private(set) var remainingTime: Double = 0
    @Published public private(set) var offRouteDistance: Double = 0
    @Published public private(set) var isFollowing = true
    @Published public private(set) var isWeakLocation = false
    @Published public private(set) var lastFailure: NavFailure?
    @Published public private(set) var isBackgroundNavigating = false
    /// 起步时间（用于统计与完成页）
    @Published public private(set) var traveledDistance: Double = 0

    public var voice: VoiceService
    private let location: LocationService
    private let router = RouteService()

    private var requestCounter = 0
    private var stepEndProgress: [Double] = []
    private var routeLength: Double = 0
    private var offRouteStreak = 0
    private var lastFix: LocationSnapshot?
    private var arrivalHandled = false
    private var rerouteInFlight = false
    private var startInFlight = false

    public init(location: LocationService, voice: VoiceService) {
        self.location = location
        self.voice = voice
    }

    // MARK: - 规划（路线方案页）

    public func plan(origin: Place, destination: Place, mode: TravelMode) async {
        let requestId = nextRequestId()
        phase = .planning
        lastFailure = nil
        routes = []
        selectedRouteId = nil
        let result = await router.routes(from: origin, to: destination, mode: mode, requestId: requestId)
        // 旧请求晚到：只接当前代次（NAV-37）
        guard requestId == currentRequestId else { return }
        if let failure = result.failure, result.routes.isEmpty {
            phase = .failed(failure)
            lastFailure = failure
            return
        }
        routes = result.routes
        selectedRouteId = result.routes.first?.id
        phase = .ready
    }

    private var currentRequestId = ""

    private func nextRequestId() -> String {
        requestCounter += 1
        let id = "req-\(requestCounter)-\(Int(Date().timeIntervalSince1970))"
        currentRequestId = id
        return id
    }

    public func selectRoute(_ id: String) {
        guard routes.contains(where: { $0.id == id }) else { return }
        selectedRouteId = id
    }

    /// 规划前置条件不满足（无有效起点/定位不可用）时直接进入对应失败态
    public func fail(_ failure: NavFailure) {
        routes = []
        selectedRouteId = nil
        lastFailure = failure
        phase = .failed(failure)
    }

    public var selectedRoute: RouteOption? {
        routes.first { $0.id == selectedRouteId }
    }

    // MARK: - 开始（NAV-19/20：内部再次核验，单会话防连点）

    public enum StartFailure: Error {
        case location(NavFailure)
        case noRoute
        case alreadyActive
    }

    public func start(origin: Place, destination: Place) async throws {
        guard !phase.isActiveSession, !startInFlight else { throw StartFailure.alreadyActive }
        guard let route = selectedRoute else { throw StartFailure.noRoute }

        startInFlight = true
        phase = .starting
        defer { startInFlight = false }

        // 起点不是当前位置时，实时导航不能把设备瞬移过去（NAV-19）
        var startOrigin = origin
        if origin.source != .device {
            guard let fix = await location.requestSingleFix(), fix.isUsable else {
                phase = .ready
                throw StartFailure.location(.locationUnavailable)
            }
            let devicePlace = fix.place
            if origin.distance(to: devicePlace) > 120 {
                // 用当前位置重算到原终点
                let requestId = nextRequestId()
                let result = await router.routes(from: devicePlace, to: destination,
                                                 mode: route.mode, requestId: requestId)
                guard requestId == currentRequestId, let fresh = result.routes.first else {
                    phase = .ready
                    throw StartFailure.location(.locationUnavailable)
                }
                routes = result.routes
                selectedRouteId = fresh.id
                startOrigin = devicePlace
            } else {
                startOrigin = devicePlace
            }
        } else {
            guard let fix = await location.requestSingleFix(), fix.isUsable else {
                phase = .ready
                throw StartFailure.location(.locationUnavailable)
            }
            startOrigin = fix.place
        }

        guard let finalRoute = selectedRoute else {
            phase = .ready
            throw StartFailure.noRoute
        }

        beginSession(route: finalRoute, origin: startOrigin, destination: destination)
    }

    private func beginSession(route: RouteOption, origin: Place, destination: Place) {
        let id = "sess-\(Int(Date().timeIntervalSince1970))-\(requestCounter)"
        let newSession = NavSession(id: id, mode: route.mode, destination: destination,
                                    origin: origin, route: route, startedAt: Date(),
                                    terminalReason: nil)
        session = newSession
        arrivalHandled = false
        offRouteStreak = 0
        traveledDistance = 0
        rerouteInFlight = false
        currentStepIndex = 0
        prepareRouteMetrics(route)
        phase = .active
        isFollowing = true
        voice.resetSessionKeys()

        // 起步播报：路线概要 + 首条有效动作（V01）
        let summary = "开始导航，全程\(route.distanceText)，预计\(route.timeText)"
        let firstAction = route.steps.first?.instruction ?? ""
        voice.speak(summary + (firstAction.isEmpty ? "" : "。") + firstAction, priority: .turn)

        location.startContinuous { [weak self] fix in
            self?.handle(fix: fix)
        }
    }

    private func prepareRouteMetrics(_ route: RouteOption) {
        routeLength = Geo.length(of: route.polyline)
        var cumulative = 0.0
        stepEndProgress = route.steps.map { step in
            cumulative += step.distance
            return cumulative
        }
        remainingDistance = route.distance
        remainingTime = route.expectedTravelTime
        distanceToManeuver = route.steps.first?.distance ?? 0
    }

    // MARK: - 位置处理（NAV-22/23/25/26）

    private func handle(fix: LocationSnapshot) {
        guard phase.isActiveSession, var current = session else { return }
        lastFix = fix

        // 弱定位/过期不编确定转向
        if !fix.isUsable {
            if !isWeakLocation {
                isWeakLocation = true
                voice.announceOnce(key: "weak-\(current.id)", text: "定位信号较弱，正在重新获取")
            }
            return
        }
        if isWeakLocation {
            isWeakLocation = false
            voice.announceOnce(key: "weak-recovered-\(current.id)", text: "定位已恢复")
        }

        let match = Geo.match(fix.place.gcj02Coordinate, on: current.route.polyline)
        offRouteDistance = match.offRouteDistance

        // 剩余里程/时间按当前路线更新（NAV-23）
        remainingDistance = max(0, routeLength - match.progress)
        let ratio = routeLength > 0 ? remainingDistance / routeLength : 1
        remainingTime = current.route.expectedTravelTime * ratio
        traveledDistance = min(match.progress, routeLength)

        // 步骤推进
        advanceStepIfNeeded(progress: match.progress, fix: fix)
        updateManeuverDistance(progress: match.progress)

        // 到达判定（引擎能力范围内的真实到达）
        if !arrivalHandled {
            let toDestination = Geo.distance(fix.place.gcj02Coordinate,
                                             current.destination.gcj02Coordinate)
            if toDestination <= current.mode.arrivalRadius ||
                (currentStepIndex >= current.route.steps.count - 1 &&
                 remainingDistance <= current.mode.arrivalRadius) {
                arrive()
                return
            }
        }

        // 偏航判定：连续 3 次超阈值才确认（避免 GPS 漂移误判，NAV-25）
        if offRouteDistance > current.mode.offRouteThreshold {
            offRouteStreak += 1
            if offRouteStreak >= 3 && !rerouteInFlight {
                triggerReroute()
            }
        } else {
            offRouteStreak = 0
        }
    }

    private func advanceStepIfNeeded(progress: Double, fix: LocationSnapshot) {
        guard let current = session else { return }
        var index = currentStepIndex
        // 走过当前机动点：推进到下一有效动作
        while index < current.route.steps.count - 1,
              progress >= stepEndProgress[index] - 8 {
            index += 1
        }
        if index != currentStepIndex {
            currentStepIndex = index
            let step = current.route.steps[index]
            if !step.instruction.isEmpty {
                voice.announceOnce(key: "\(current.id)-step-\(index)-now",
                                   text: step.instruction, priority: .turn)
            }
        }
    }

    private func updateManeuverDistance(progress: Double) {
        guard let current = session, currentStepIndex < stepEndProgress.count else { return }
        let remain = max(0, stepEndProgress[currentStepIndex] - progress)
        distanceToManeuver = remain

        // 分档播报，每档只播一次（NAV-28 / V02）
        guard let step = current.route.steps[safe: currentStepIndex],
              !step.instruction.isEmpty else { return }
        for threshold in current.mode.announceDistances where remain <= threshold {
            let key = "\(current.id)-step-\(currentStepIndex)-\(Int(threshold))"
            if remain > 0 {
                voice.announceOnce(key: key,
                                   text: "前方\(Int(threshold))米，\(step.instruction)",
                                   priority: .turn)
            }
        }
    }

    // MARK: - 偏航重算（NAV-25）

    private func triggerReroute() {
        guard let current = session, let fix = lastFix, !rerouteInFlight else { return }
        rerouteInFlight = true
        phase = .rerouting
        voice.announceOnce(key: "reroute-\(current.id)-\(Int(Date().timeIntervalSince1970))",
                           text: "已偏离路线，正在重新规划", priority: .turn)

        Task { [weak self] in
            guard let self else { return }
            let requestId = self.nextRequestId()
            let from = fix.place
            let result = await self.router.routes(from: from, to: current.destination,
                                                  mode: current.mode, requestId: requestId)
            await MainActor.run {
                guard self.phase == .rerouting || self.phase == .active else {
                    self.rerouteInFlight = false
                    return
                }
                // 终态已写则丢弃迟到结果（NAV-37）
                guard var session = self.session, session.id == current.id else {
                    self.rerouteInFlight = false
                    return
                }
                if let fresh = result.routes.first, result.failure == nil {
                    session.route = fresh
                    self.session = session
                    self.routes = [fresh]
                    self.selectedRouteId = fresh.id
                    self.currentStepIndex = 0
                    self.prepareRouteMetrics(fresh)
                    self.offRouteStreak = 0
                    self.phase = .active
                    self.voice.announceOnce(key: "reroute-ok-\(session.id)-\(Int(Date().timeIntervalSince1970))",
                                            text: "路线已更新。" + (fresh.steps.first?.instruction ?? ""),
                                            priority: .turn)
                } else {
                    self.phase = .active
                    self.lastFailure = result.failure ?? .serviceError
                    self.voice.announceOnce(key: "reroute-fail-\(session.id)-\(Int(Date().timeIntervalSince1970))",
                                            text: "重新规划失败，请检查网络后重试", priority: .turn)
                }
                self.rerouteInFlight = false
            }
        }
    }

    /// 用户手动重试重算（失败后）
    public func retryReroute() {
        offRouteStreak = 3
        triggerReroute()
    }

    // MARK: - 终态

    public func arrive() {
        guard phase.isActiveSession, var current = session, !arrivalHandled else { return }
        arrivalHandled = true
        current.terminalReason = .arrived
        session = current
        phase = .arrived
        voice.speak("已到达目的地，导航结束", priority: .terminal)
        teardownSession()
    }

    /// 主动退出：回路线规划（覆盖旧版直接回首页，NAV-34）
    public func exit() {
        guard phase.isActiveSession, var current = session else { return }
        current.terminalReason = .exited
        session = current
        phase = .ended
        voice.speak("导航已结束", priority: .terminal)
        teardownSession()
    }

    private func teardownSession() {
        location.stopContinuous()
        offRouteStreak = 0
        rerouteInFlight = false
        isBackgroundNavigating = false
        isFollowing = true
    }

    /// 回到规划态：保留目标/方式/路线选择意图（NAV-34）
    public func returnToPlanning() {
        if phase == .arrived || phase == .ended {
            phase = .ready
        }
    }

    /// 页面销毁不等于结束会话；这里只标记 UI 可见性（NAV-39）
    public func setFollowing(_ following: Bool) {
        isFollowing = following
    }

    // MARK: - 前后台（NAV-31）

    public func handleScenePhase(_ isBackground: Bool) {
        guard phase.isActiveSession else { return }
        if isBackground {
            if location.isContinuous {
                isBackgroundNavigating = true
                if let id = session?.id {
                    voice.announceOnce(key: "bg-\(id)", text: "地图持续为您导航中", priority: .normal)
                }
            }
        } else {
            isBackgroundNavigating = false
            // 回前台：不重播导航开始，只按当前有效动作恢复（V11/V15）
            if let step = session?.route.steps[safe: currentStepIndex],
               !step.instruction.isEmpty, distanceToManeuver > 0 {
                voice.speak("继续\(step.instruction)", priority: .turn)
            }
        }
    }

    /// 冷启动恢复：不假装一直在导航（NAV-32）
    public func resetForColdStart() {
        if phase.isActiveSession || phase == .arrived {
            phase = .idle
            session = nil
            routes = []
            selectedRouteId = nil
        }
    }

    public var nextStep: NavStep? {
        session?.route.steps[safe: currentStepIndex]
    }

    public var nextRoadName: String? {
        guard let step = nextStep, !step.roadName.isEmpty else { return nil }
        return step.roadName
    }

    public var etaDate: Date {
        Date().addingTimeInterval(remainingTime)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
