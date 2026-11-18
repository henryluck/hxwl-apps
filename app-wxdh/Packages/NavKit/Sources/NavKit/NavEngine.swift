import AMapFoundationKit
import AMapNaviKit
import Combine
import CoreKit
import CoreLocation
import Foundation

/// 实时会话（对外形状保留：UI 依赖）
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

/// 导航引擎（高德导航 SDK 版）：算路/导航全部委托 NaviService（官方 Manager），
/// 这里只维护会话状态机与 UI 绑定数据（phase/routes/剩余时距镜像官方 liveInfo）。
@MainActor
public final class NavEngine: ObservableObject {
    // MARK: - 对外状态（保持既有 UI 契约）

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
    @Published public private(set) var traveledDistance: Double = 0

    /// 当前诱导信息（官方 updateNaviInfo 镜像）
    @Published public private(set) var liveInfo: LiveNaviInfo?

    public var voice: VoiceService
    private let location: LocationService
    let navi = NaviService.shared

    private var requestCounter = 0
    private var startInFlight = false
    /// 【Bug 行37】启动代次：cancelPendingStart / 新 start 递增，旧代次的异步续体全部作废
    private var startGeneration = 0
    private var currentRequestId = ""
    /// 当前会话是否用模拟导航（模拟器验证用；真机 GPS）
    private var emulatorSession = false

    public init(location: LocationService, voice: VoiceService) {
        self.location = location
        self.voice = voice
        navi.attachVoice(voice)
        // 官方到达回调 → 引擎终态
        navi.onArrived = { [weak self] in
            self?.arrive()
        }
        // 官方实时诱导信息镜像（剩余时距/当前道路）
        navi.$liveInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let self, let info else { return }
                self.liveInfo = info
                self.remainingDistance = Double(info.remainDistance)
                self.remainingTime = Double(info.remainTime)
                self.distanceToManeuver = Double(info.segmentRemainDistance)
            }
            .store(in: &cancellables)
        navi.$isRecalculating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recalculating in
                guard let self, self.phase.isActiveSession else { return }
                self.phase = recalculating ? .rerouting : .active
            }
            .store(in: &cancellables)
        navi.$gpsSignal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signal in
                // 官方信号强度：0 强 1 弱 2 无信号
                self?.isWeakLocation = (signal == 2)
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 规划（官方 calculateDriveRoute / calculateWalkRoute / calculateRideRoute）

    public func plan(origin: Place, destination: Place, mode: TravelMode) async {
        let requestId = nextRequestId()
        phase = .planning
        lastFailure = nil
        routes = []
        selectedRouteId = nil
        Log.info("[Engine] plan 开始 req=\(requestId) mode=\(mode)（高德导航 SDK）")

        let outcome = await navi.plan(from: origin, to: destination, mode: mode, requestId: requestId)

        guard requestId == currentRequestId else {
            Log.info("[Engine] 丢弃过期算路结果 req=\(requestId)")
            return
        }
        if let failure = outcome.failure {
            Log.warn("[Engine] 算路失败 → failed: \(failure)")
            phase = .failed(failure)
            lastFailure = failure
            return
        }
        // 从官方 manager 的 naviRoutes 取回方案（多策略驾车可达 3 条）
        let options = navi.currentRoutes(mode: mode, requestId: requestId)
        guard !options.isEmpty else {
            phase = .failed(.noRoute)
            lastFailure = .noRoute
            return
        }
        routes = options
        selectedRouteId = options.first?.id
        phase = .ready
        Log.info("[Engine] 算路成功 \(options.count) 条方案（高德导航 SDK）")
    }

    private func nextRequestId() -> String {
        requestCounter += 1
        let id = "req-\(requestCounter)-\(Int(Date().timeIntervalSince1970))"
        currentRequestId = id
        return id
    }

    public func selectRoute(_ id: String) {
        guard routes.contains(where: { $0.id == id }) else { return }
        selectedRouteId = id
        // 官方：切方案后重新选择路线（导航 SDK 内部路线组，routeID 从 1 递增）
        if let routeIndex = routes.firstIndex(where: { $0.id == id }),
           navi.viewKind == .drive {
            _ = AMapNaviDriveManager.sharedInstance().selectNaviRoute(withRouteID: routeIndex + 1)
        }
    }

    /// 规划前置条件不满足时直接进入失败态
    public func fail(_ failure: NavFailure) {
        routes = []
        selectedRouteId = nil
        lastFailure = failure
        phase = .failed(failure)
    }

    public var selectedRoute: RouteOption? {
        routes.first { $0.id == selectedRouteId }
    }

    // MARK: - 开始导航（官方 startGPSNavi / 模拟器 startEmulatorNavi）

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
        // 【Bug 行37】启动代次令牌：用户在"规划中"退出页面/取消后，晚到的定位与
        // 会话建立必须作废——否则在其他页面突然切进导航模式
        startGeneration += 1
        let generation = startGeneration
        defer { startInFlight = false }
        // 实时导航必须从设备真实位置起步；位置不可用直接失败分流。
        // 【Bug 行29】单次定位偶发超时/弱信号（室内边缘常见）会让用户"提示不成功、
        // 多试几次才能进"——改为失败后自动补一炮（800ms 间隔），两次都失败才报错。
        // 【Bug 行37】首炮超时 8→5s：规划刚完成时快照新鲜（秒开），只有快照过期后才
        // 走真定位；5s 内拿不到就补炮（10s），总最坏耗时从 ~19s 收敛到 ~16s 且更早失败提示。
        var fix = await location.requestSingleFix(timeout: 5)
        if !(fix?.isUsable ?? false) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            fix = await location.requestSingleFix(timeout: 10)
        }
        // 【Bug 行37】代次已过期（用户已离开/再次点击）→ 丢弃本次启动
        guard generation == startGeneration else {
            if phase == .starting { phase = .ready }
            return
        }
        guard let f = fix, f.isUsable else {
            if !location.authState.isUsable {
                phase = .ready
                throw StartFailure.location(location.authState == .servicesOff ? .locationServicesOff : .locationDenied)
            }
            phase = .ready
            throw StartFailure.location(.locationUnavailable)
        }
        beginSession(route: route, origin: f.place, destination: destination)
    }

    /// 【Bug 行37】用户取消/离开规划页时作废在途的启动流程（诱导面板显示规划中，
    /// 后台不再继续调度 → 不会在其他页面突然进入导航模式）
    public func cancelPendingStart() {
        guard phase == .starting else { return }
        startGeneration += 1   // 作废所有在途 start()
        phase = .ready
        Log.info("[Engine] 取消在途导航启动（用户离开规划页）")
    }

    private func beginSession(route: RouteOption, origin: Place, destination: Place) {
        let id = "sess-\(Int(Date().timeIntervalSince1970))-\(requestCounter)"
        session = NavSession(id: id, mode: route.mode, destination: destination,
                             origin: origin, route: route, startedAt: Date(),
                             terminalReason: nil)
        voice.resetSessionKeys()
        traveledDistance = 0
        isFollowing = true

        // 模拟器无真实位移 → 模拟导航（官方明确模拟导航勿作实际导航展示；
        // 这里仅用于开发验证 UI 链路，真机自动走 GPS 导航）
        #if targetEnvironment(simulator)
        emulatorSession = true
        #else
        emulatorSession = false
        #endif

        let ok = navi.startNavi(emulator: emulatorSession)
        guard ok else {
            phase = .failed(.engineStartFailed)
            lastFailure = .engineStartFailed
            session = nil
            return
        }
        phase = .active
        let summary = "开始导航，全程\(route.distanceText)，预计\(route.timeText)"
        voice.speak(summary, priority: .normal)
        Log.info("[Engine] 导航会话开始 id=\(id) emulator=\(emulatorSession)")
    }

    // MARK: - 终态

    public func arrive() {
        guard phase.isActiveSession, var current = session else { return }
        current.terminalReason = .arrived
        session = current
        phase = .arrived
        voice.speak("已到达目的地，导航结束", priority: .terminal)
        navi.stopNavi()
    }

    /// 主动退出：回路线规划（NAV-34）
    public func exit() {
        guard phase.isActiveSession, var current = session else { return }
        current.terminalReason = .exited
        session = current
        phase = .ended
        voice.speak("导航已结束", priority: .terminal)
        navi.stopNavi()
    }

    /// 回到规划态：保留目标/方式/路线选择意图（NAV-34）
    public func returnToPlanning() {
        if phase == .arrived || phase == .ended {
            phase = .ready
        }
    }

    /// 页面销毁不等于结束会话；只标记 UI 可见性（NAV-39）
    public func setFollowing(_ following: Bool) {
        isFollowing = following
        if following {
            navi.lockCamera()
        } else {
            navi.displayOverview()
        }
    }

    // MARK: - 前后台（NAV-31）

    public func handleScenePhase(_ isBackground: Bool) {
        guard phase.isActiveSession else { return }
        if isBackground {
            isBackgroundNavigating = true
        } else {
            isBackgroundNavigating = false
        }
    }

    /// 冷启动恢复：不假装一直在导航（NAV-32）
    public func resetForColdStart() {
        if phase.isActiveSession || phase == .arrived {
            phase = .idle
            session = nil
            routes = []
            selectedRouteId = nil
            navi.stopNavi()
        }
    }

    public var nextStep: NavStep? {
        // 官方导航中转向提示从 liveInfo 走；保留 API 兼容（非导航场景用 steps）
        session?.route.steps[safe: currentStepIndex]
    }

    public var nextRoadName: String? {
        guard let name = liveInfo?.nextRoadName, !name.isEmpty else { return nil }
        return name
    }

    public var etaDate: Date {
        Date().addingTimeInterval(remainingTime)
    }

    /// 诱导图标类型（官方 AMapNaviIconType 原始值 → SF Symbol）
    /// 【Bug 行30/40/45】按官方枚举精确映射（此前整体错位一格，面板方向与语音/实际相反）：
    /// 0无 1车标 2左转 3右转 4左前 5右前 6左后 7右后 8左转掉头 9直行 10途经点
    /// 11进环岛 12出环岛 13服务区 14收费站 15目的地 16隧道 19右转掉头 20顺行
    public var maneuverIconName: String {
        let t = liveInfo?.iconType ?? -1
        switch t {
        case 2: return "arrow.turn.up.left"          // 左转
        case 3: return "arrow.turn.up.right"         // 右转
        case 4: return "arrow.up.left"               // 左前方
        case 5: return "arrow.up.right"              // 右前方
        case 6: return "arrow.down.left"             // 左后方
        case 7: return "arrow.down.right"            // 右后方
        case 8: return "arrow.uturn.left"            // 左转掉头
        case 9: return "arrow.up"                    // 直行
        case 10: return "mappin.and.ellipse"         // 到达途经点
        case 11, 17, 21, 22, 23, 25, 26, 27: return "arrow.triangle.merge"   // 进环岛系
        case 12, 18: return "arrow.triangle.branch.exit"                      // 出环岛系
        case 13: return "house.fill"                 // 服务区
        case 14: return "building.columns.fill"      // 收费站
        case 15: return "flag.checkered"             // 到达目的地
        case 16: return "triangle.lefthalf.filled"   // 隧道
        case 19: return "arrow.uturn.right"          // 右转掉头
        case 20: return "arrow.up.to.line"           // 顺行
        case 29: return "figure.walk"                // 人行横道
        case 30: return "figure.walk"                // 过街天桥
        default: return "arrow.up"
        }
    }

    /// 诱导文字（官方 iconType → 中文动作 + 下一道路名）
    public var maneuverText: String {
        guard let info = liveInfo else { return "沿当前道路继续前行" }
        let action = Self.iconActionText(info.iconType)
        if !info.nextRoadName.isEmpty {
            return "\(action)进入\(info.nextRoadName)"
        }
        return action
    }

    static func iconActionText(_ type: Int) -> String {
        switch type {
        case 2: return "左转"
        case 3: return "右转"
        case 4: return "向左前方行驶"
        case 5: return "向右前方行驶"
        case 6: return "向左后方行驶"
        case 7: return "向右后方行驶"
        case 8: return "左转掉头"
        case 9: return "直行"
        case 10: return "到达途经点"
        case 11, 17, 21, 22, 23, 24: return "进入环岛"
        case 12, 18: return "驶出环岛"
        case 25, 26: return "绕环岛左转"
        case 27, 28: return "绕环岛右转"   // 25-28 标准小环岛细分，文案归并
        case 13: return "到达服务区"
        case 14: return "通过收费站"
        case 15: return "到达目的地"
        case 16: return "进入隧道"
        case 19: return "右转掉头"
        case 20: return "顺行"
        case 29: return "通过人行横道"
        case 30: return "通过过街天桥"
        case 31: return "通过地下通道"
        default: return "继续前行"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
