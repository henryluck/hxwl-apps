import AMapFoundationKit
import AMapNaviKit
import Combine
import CoreKit
import CoreLocation
import Foundation
import UIKit

// MARK: - 数据模型（与现有 UI 兼容的轻量映射）

/// 官方导航视图种类：驾车/步行/骑行（AMapNaviDriveView 等）
public enum NaviViewKind {
    case drive, walk, ride

    var title: String {
        switch self {
        case .drive: return "驾车"
        case .walk: return "步行"
        case .ride: return "骑行"
        }
    }
}

/// 导航实时信息（从 AMapNaviInfo 映射，供 UI 横幅显示）
public struct LiveNaviInfo: Equatable {
    public var currentRoadName: String
    public var nextRoadName: String
    public var remainDistance: Int          // 米
    public var remainTime: Int              // 秒
    public var segmentRemainDistance: Int   // 距下一 maneuvers 米
    public var segmentRemainTime: Int
    public var iconType: Int                // AMapNaviIconType 原始值

    public var remainDistanceText: String {
        remainDistance >= 1000
            ? String(format: "%.1f公里", Double(remainDistance) / 1000)
            : "\(remainDistance)米"
    }

    public var remainTimeText: String {
        let minutes = max(1, Int(ceil(Double(remainTime) / 60)))
        if minutes < 60 { return "\(minutes)分钟" }
        return "\(minutes / 60)小时\(minutes % 60)分钟"
    }

    public var etaText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date().addingTimeInterval(TimeInterval(remainTime)))
    }
}

// MARK: - 高德导航 SDK 统一服务

/// 官方标准实现（高德 iOS 导航 SDK 文档 gps-navi / drive-route-plan）：
/// - 算路：AMapNaviDriveManager.calculateDriveRouteWithStartPoints（策略 10 多路径）/
///   AMapNaviWalkManager.calculateWalkRouteWithStartPoints /
///   AMapNaviRideManager.calculateRideRouteWithStartPoint
/// - 导航：startGPSNavi()（真实）/ startEmulatorNavi()（模拟，便于室内验证）
/// - 展示：AMapNaviDriveView / WalkView / RideView 通过 addDataRepresentative 接收数据
/// - 语音：playNaviSoundString 回调 → AVSpeechSynthesizer
///
/// 三种 Manager 是互斥单例（取 Drive 单例前需销毁 Walk/Ride），本服务负责按模式切换。
@MainActor
public final class NaviService: NSObject, ObservableObject {

    public static let shared = NaviService()

    // MARK: - 对外状态（UI 观察）

    @Published public private(set) var viewKind: NaviViewKind = .drive
    /// 最近一次实时诱导信息（nil = 未在导航）
    @Published public private(set) var liveInfo: LiveNaviInfo?
    /// GPS 信号强度（-1 未知）
    @Published public private(set) var gpsSignal: Int = -1
    /// 是否正在导航（startNavi 之后 stopNavi 之前）
    @Published public private(set) var isNavigating = false
    /// 偏航重算中（官方 SDK 自动触发）
    @Published public private(set) var isRecalculating = false

    // MARK: - 算路结果（completion 异步回传，保持 RouteService 兼容形状）

    public struct PlanOutcome {
        public var routes: [RouteOption]
        public var failure: NavFailure?
    }

    /// 语音输出（复用现有 VoiceService 的队列/优先级/静音逻辑）
    private var voice: VoiceService?
    /// 算路回调桥（一次只有一个在途算路请求）
    private var planContinuation: CheckedContinuation<PlanOutcome, Never>?
    private var emulatorMode = false   // 模拟器/DEBUG 用模拟导航

    private override init() {
        super.init()
    }

    public func attachVoice(_ voice: VoiceService) {
        self.voice = voice
    }

    // MARK: - Manager 生命周期（三种单例互斥，按模式取用）
    // 注意：此版本 SDK sharedInstance() 返回非 Optional 且未创建时自动创建。
    // walk/ride 与 drive 单例互斥：切走时直接 destroy（未创建时 destroy 也安全）。

    private func prepareManager(for kind: NaviViewKind) {
        switch kind {
        case .drive:
            _ = AMapNaviDriveManager.sharedInstance()
        case .walk:
            AMapNaviDriveManager.destroyInstance()
            _ = AMapNaviWalkManager.sharedInstance()
        case .ride:
            AMapNaviDriveManager.destroyInstance()
            _ = AMapNaviRideManager.sharedInstance()
        }
    }

    /// 按模式配置 manager：delegate + 后台定位 + 导航视图数据通道
    public func configure(kind: NaviViewKind, naviView: UIView?) {
        viewKind = kind
        switch kind {
        case .drive:
            let m = AMapNaviDriveManager.sharedInstance()
            m.delegate = self
            m.allowsBackgroundLocationUpdates = true
            m.pausesLocationUpdatesAutomatically = false
            // 【Bug 行30】self 注册为 dataRepresentative：updateNaviInfo 属 DataRepresentable
            // 协议（Manager delegate 不回调它），不注册就收不到实时诱导数据
            m.addDataRepresentative(self)
            if let view = naviView as? AMapNaviDriveView {
                m.addDataRepresentative(view)
            }
        case .walk:
            let m = AMapNaviWalkManager.sharedInstance()
            m.delegate = self
            m.allowsBackgroundLocationUpdates = true
            m.pausesLocationUpdatesAutomatically = false
            m.addDataRepresentative(self)
            if let view = naviView as? AMapNaviWalkView {
                m.addDataRepresentative(view)
            }
        case .ride:
            let m = AMapNaviRideManager.sharedInstance()
            m.delegate = self
            m.allowsBackgroundLocationUpdates = true
            m.pausesLocationUpdatesAutomatically = false
            m.addDataRepresentative(self)
            if let view = naviView as? AMapNaviRideView {
                m.addDataRepresentative(view)
            }
        }
        activeNaviView = naviView
    }

    /// 换模式/退出页面：解除数据通道、销毁单例（官方 dealloc 规范）
    /// 注：sharedInstance 非 Optional；单例可能尚未创建（teardown 幂等）
    public func teardown() {
        stopNavi()
        if let view = activeNaviView {
            switch viewKind {
            case .drive:
                if let view = view as? AMapNaviDriveView {
                    AMapNaviDriveManager.sharedInstance().removeDataRepresentative(view)
                }
            case .walk:
                if let view = view as? AMapNaviWalkView {
                    AMapNaviWalkManager.sharedInstance().removeDataRepresentative(view)
                }
            case .ride:
                if let view = view as? AMapNaviRideView {
                    AMapNaviRideManager.sharedInstance().removeDataRepresentative(view)
                }
            }
        }
        switch viewKind {
        case .drive:
            let m = AMapNaviDriveManager.sharedInstance()
            m.delegate = nil
            AMapNaviDriveManager.destroyInstance()
        case .walk:
            let m = AMapNaviWalkManager.sharedInstance()
            m.delegate = nil
            AMapNaviWalkManager.destroyInstance()
        case .ride:
            let m = AMapNaviRideManager.sharedInstance()
            m.delegate = nil
            AMapNaviRideManager.destroyInstance()
        }
        liveInfo = nil
        isNavigating = false
        isRecalculating = false
        activeNaviView = nil
    }

    // MARK: - 算路（官方 calculate 系列接口，异步等待回调）

    /// 规划路线并返回方案列表（walk/ride 单方案，drive 策略 10 可多方案）
    public func plan(from origin: Place,
                     to destination: Place,
                     mode: TravelMode,
                     requestId: String) async -> PlanOutcome {
        guard origin.hasValidCoordinate, destination.hasValidCoordinate else {
            return PlanOutcome(routes: [], failure: .invalidPlace)
        }

        // AMapNaviPoint 构造返回 Optional（坐标非法时 nil）
        guard let start = AMapNaviPoint.location(withLatitude: CGFloat(origin.gcj02Coordinate.latitude),
                                                 longitude: CGFloat(origin.gcj02Coordinate.longitude)),
              let end = AMapNaviPoint.location(withLatitude: CGFloat(destination.gcj02Coordinate.latitude),
                                               longitude: CGFloat(destination.gcj02Coordinate.longitude)) else {
            return PlanOutcome(routes: [], failure: .invalidPlace)
        }

        // 模式切换（walk/ride 与 drive 单例互斥）
        viewKind = mode.naviKind
        prepareManager(for: mode.naviKind)

        // ⚠️ continuation 必须在发起算路前登记好，回调可能极快（本地缓存路线）
        return await withCheckedContinuation { (cont: CheckedContinuation<PlanOutcome, Never>) in
            self.planContinuation = cont
            let accepted: Bool
            switch mode {
            case .driving:
                let m = AMapNaviDriveManager.sharedInstance()
                m.delegate = self
                accepted = m.calculateDriveRoute(withStart: [start],
                                                  end: [end],
                                                  wayPoints: nil,
                                                  drivingStrategy: AMapNaviDrivingStrategy(rawValue: 10) ?? AMapNaviDrivingStrategy(rawValue: 0)!)
            case .walking:
                let m = AMapNaviWalkManager.sharedInstance()
                m.delegate = self
                accepted = m.calculateWalkRoute(withStart: [start], end: [end])
            case .cycling:
                let m = AMapNaviRideManager.sharedInstance()
                m.delegate = self
                accepted = m.calculateRideRoute(withStart: start, end: end)
            }
            if !accepted {
                // 参数校验失败（如起终点相同）：立即结束，不等待回调
                self.planContinuation = nil
                cont.resume(returning: PlanOutcome(routes: [], failure: .invalidPlace))
            }
        }
    }

    /// 当前算路模式下的全部路线（naviRoutes 字典 → 数组，drive 多方案 / walk-ride 单方案）
    public func currentRoutes(mode: TravelMode, requestId: String) -> [RouteOption] {
        let routesDict: [NSNumber: AMapNaviRoute]
        switch mode {
        case .driving:
            routesDict = AMapNaviDriveManager.sharedInstance().naviRoutes ?? [:]
        case .walking:
            routesDict = AMapNaviWalkManager.sharedInstance().naviRoutes()
        case .cycling:
            routesDict = AMapNaviRideManager.sharedInstance().naviRoutes()
        }
        let sorted = routesDict.sorted { $0.key.intValue < $1.key.intValue }
        var options: [RouteOption] = []
        var seen = Set<String>()
        for (index, (_, route)) in sorted.enumerated() {
            let coords = route.routeCoordinates.map {
                CLLocationCoordinate2D(latitude: CLLocationDegrees($0.latitude),
                                       longitude: CLLocationDegrees($0.longitude))
            }
            guard coords.count >= 2 else { continue }
            let signature = String(format: "%.4f%.4f%.4f%.4f%d",
                                   coords.first?.latitude ?? 0, coords.first?.longitude ?? 0,
                                   coords.last?.latitude ?? 0, coords.last?.longitude ?? 0,
                                   route.routeLength)
            if seen.contains(signature) { continue }
            seen.insert(signature)

            // 步骤：routeSegments → NavStep（segment 无诱导文案，诱导在导航时由 NaviInfo 提供）
            let steps = Self.steps(from: route, routeId: requestId)
            options.append(RouteOption(
                id: "\(requestId)#\(index)",
                mode: mode,
                distance: Double(route.routeLength),
                expectedTravelTime: Double(route.routeTime),
                steps: steps,
                polyline: coords,
                engineLabel: index == 0 ? "推荐" : "备选\(index)",
                requestId: requestId))
            if options.count >= 3 { break }
        }
        return options
    }

    static func steps(from route: AMapNaviRoute, routeId: String) -> [NavStep] {
        let segments = route.routeSegments
        guard !segments.isEmpty else { return [] }
        var result: [NavStep] = []
        let total = segments.count
        for (index, seg) in segments.enumerated() {
            let isArrival = index == total - 1
            // segment 无诱导文案字段：道路名取首条 link；文案占位（真实诱导在导航中由 liveInfo 提供）
            let roadName = seg.links.first?.roadName ?? ""
            let instruction = isArrival ? "到达目的地" : (roadName.isEmpty ? "继续前行" : "沿\(roadName)行驶")
            let endCoord = seg.coordinates.last.map {
                CLLocationCoordinate2D(latitude: CLLocationDegrees($0.latitude),
                                       longitude: CLLocationDegrees($0.longitude))
            }
            result.append(NavStep(id: "\(routeId)#\(index)",
                                  index: index,
                                  instruction: instruction,
                                  distance: Double(seg.length),
                                  coordinate: endCoord ?? CLLocationCoordinate2D(),
                                  roadName: roadName,
                                  isArrivalStep: isArrival))
        }
        return result
    }

    // MARK: - 导航控制（官方 startGPSNavi / startEmulatorNavi / stopNavi）

    /// 开始导航：模拟器无真实位移，自动用模拟导航（startEmulatorNavi）；真机 GPS 导航
    public func startNavi(emulator: Bool = false) -> Bool {
        emulatorMode = emulator
        let ok: Bool
        switch viewKind {
        case .drive: ok = emulator
            ? AMapNaviDriveManager.sharedInstance().startEmulatorNavi()
            : AMapNaviDriveManager.sharedInstance().startGPSNavi()
        case .walk: ok = emulator
            ? AMapNaviWalkManager.sharedInstance().startEmulatorNavi()
            : AMapNaviWalkManager.sharedInstance().startGPSNavi()
        case .ride: ok = emulator
            ? AMapNaviRideManager.sharedInstance().startEmulatorNavi()
            : AMapNaviRideManager.sharedInstance().startGPSNavi()
        }
        if ok { isNavigating = true }
        Log.info("[NaviSDK] startNavi(\(emulator ? "emulator" : "gps")) kind=\(viewKind) ok=\(ok)")
        return ok
    }

    public func stopNavi() {
        // 幂等停（三个都发，未导航的直接调用是安全的）
        AMapNaviDriveManager.sharedInstance().stopNavi()
        AMapNaviWalkManager.sharedInstance().stopNavi()
        AMapNaviRideManager.sharedInstance().stopNavi()
        isNavigating = false
        liveInfo = nil
    }

    /// 当前导航视图弱引用（NaviMapView 挂载时注册）
    weak var activeNaviView: UIView?
    /// 到达回调（外部 NavEngine 接管终态处理）
    var onArrived: (() -> Void)?

    /// 全览当前路线（官方导航视图 showMode = .overview）
    public func displayOverview() {
        switch viewKind {
        case .drive: (activeNaviView as? AMapNaviDriveView)?.showMode = .overview
        case .walk: (activeNaviView as? AMapNaviWalkView)?.showMode = .overview
        case .ride: (activeNaviView as? AMapNaviRideView)?.showMode = .overview
        }
    }

    /// 退出全览回跟随（锁车）
    public func lockCamera() {
        switch viewKind {
        case .drive: (activeNaviView as? AMapNaviDriveView)?.showMode = .carPositionLocked
        case .walk: (activeNaviView as? AMapNaviWalkView)?.showMode = .carPositionLocked
        case .ride: (activeNaviView as? AMapNaviRideView)?.showMode = .carPositionLocked
        }
    }
}

// MARK: - TravelMode → NaviViewKind

extension TravelMode {
    var naviKind: NaviViewKind {
        switch self {
        case .driving: return .drive
        case .walking: return .walk
        case .cycling: return .ride
        }
    }
}

// MARK: - 三种 Manager 的 Delegate（官方回调 → 状态/语音/UI）

extension NaviService {

    /// 算路成功（三种 manager 共用处理）
    private func handlePlanSuccess() {
        guard let continuation = planContinuation else { return }
        planContinuation = nil
        continuation.resume(returning: PlanOutcome(routes: [], failure: nil))
    }

    private func handlePlanFailure(_ error: Error?) {
        guard let continuation = planContinuation else { return }
        planContinuation = nil
        let failure = Self.mapPlanError(error)
        continuation.resume(returning: PlanOutcome(routes: [], failure: failure))
    }

    static func mapPlanError(_ error: Error?) -> NavFailure {
        guard let nsError = error as NSError? else { return .serviceError }
        // AMapNaviCalcRouteState：1 参数错误 2 网络错误 3 无路线 ...
        switch nsError.code {
        case 1: return .invalidPlace
        case 2: return .offline
        case 3: return .noRoute
        default: return .serviceError
        }
    }

    private func handleTTS(_ text: String) {
        guard !text.isEmpty else { return }
        voice?.speak(text, priority: .turn)
    }
}

// MARK: - AMapNaviDriveManagerDelegate + 实时诱导数据通道
// 【Bug 行30·根因】updateNaviInfo 定义在 **DataRepresentable 协议**（AMapNaviDriveDataRepresentable），
// 不在 ManagerDelegate 协议里——此前 NaviService 只实现了 Manager delegate，
// updateNaviInfo 从未被回调 → liveInfo 恒 nil → 诱导面板无距离、底部无剩余时距。
// 修复：NaviService 同时 conform DataRepresentable 协议，configure 时把 self 也注册为
// dataRepresentative，与官方导航视图并行接收实时数据。

extension NaviService: AMapNaviDriveDataRepresentable {
    // SDK Swift interface 将 ObjC updateNaviInfo: 映射为 update:（参数 naviInfo）
    public func driveManager(_ driveManager: AMapNaviDriveManager, update naviInfo: AMapNaviInfo?) {
        Task { @MainActor in
            guard let info = naviInfo else { return }
            self.liveInfo = LiveNaviInfo(currentRoadName: info.currentRoadName ?? "",
                                         nextRoadName: info.nextRoadName ?? "",
                                         remainDistance: Int(info.routeRemainDistance),
                                         remainTime: Int(info.routeRemainTime),
                                         segmentRemainDistance: Int(info.segmentRemainDistance),
                                         segmentRemainTime: Int(info.segmentRemainTime),
                                         iconType: Int(info.iconType.rawValue))
        }
    }
}

extension NaviService: AMapNaviDriveManagerDelegate {
    public func driveManager(_ driveManager: AMapNaviDriveManager, onCalculateRouteSuccessWith type: AMapNaviRoutePlanType, calculateRouteResult: AMapNaviCalculateRouteResult) {
        Task { @MainActor in
            Log.info("[NaviSDK] 驾车算路成功")
            self.isRecalculating = false
            self.handlePlanSuccess()
        }
    }

    public func driveManager(_ driveManager: AMapNaviDriveManager, onCalculateRouteFailure error: Error, routePlanType type: AMapNaviRoutePlanType, calculateRouteResult: AMapNaviCalculateRouteResult) {
        Task { @MainActor in
            Log.warn("[NaviSDK] 驾车算路失败: \(error.localizedDescription)")
            self.isRecalculating = false
            self.handlePlanFailure(error)
        }
    }

    public func driveManager(_ driveManager: AMapNaviDriveManager, playNaviSound soundString: String, soundStringType type: AMapNaviSoundType) {
        Task { @MainActor in
            self.handleTTS(soundString)
        }
    }

    // 【Bug 行30】updateNaviInfo 已迁到 AMapNaviDriveDataRepresentable extension（415 行附近）：
    // 它属于 DataRepresentable 协议而非 ManagerDelegate，原来写在这里从未被回调。

    public func driveManager(_ driveManager: AMapNaviDriveManager, update gpsSignalStrength: AMapNaviGPSSignalStrength) {
        Task { @MainActor in
            self.gpsSignal = Int(gpsSignalStrength.rawValue)
        }
    }

    public func driveManagerNeedRecalculateRoute(forYaw driveManager: AMapNaviDriveManager) {
        Task { @MainActor in
            self.isRecalculating = true
        }
    }

    public func driveManager(onArrivedDestination driveManager: AMapNaviDriveManager) {
        Task { @MainActor in
            Log.info("[NaviSDK] 驾车到达目的地")
            self.isNavigating = false
            self.liveInfo = nil
            self.onArrived?()
        }
    }

    public func driveManagerDidEndEmulatorNavi(_ driveManager: AMapNaviDriveManager) {
        Task { @MainActor in
            // 模拟导航播完不算「到达」，只结束导航态
            Log.info("[NaviSDK] 驾车模拟导航结束")
        }
    }

}

// MARK: - AMapNaviWalkManagerDelegate

extension NaviService: AMapNaviWalkManagerDelegate {

    public func walkManager(onCalculateRouteSuccess walkManager: AMapNaviWalkManager, calculateRouteResult: AMapNaviCalculateRouteResult) {
        Task { @MainActor in
            Log.info("[NaviSDK] 步行算路成功")
            self.isRecalculating = false
            self.handlePlanSuccess()
        }
    }

    public func walkManager(_ walkManager: AMapNaviWalkManager, onCalculateRouteFailure error: Error, calculateRouteResult: AMapNaviCalculateRouteResult) {
        Task { @MainActor in
            Log.warn("[NaviSDK] 步行算路失败: \(error.localizedDescription)")
            self.isRecalculating = false
            self.handlePlanFailure(error)
        }
    }

    public func walkManager(_ walkManager: AMapNaviWalkManager, playNaviSound soundString: String, soundStringType type: AMapNaviSoundType) {
        Task { @MainActor in self.handleTTS(soundString) }
    }

    // 【Bug 行30】walkManager:updateNaviInfo: 属 DataRepresentable 协议，迁移见文件底部

    public func walkManager(_ walkManager: AMapNaviWalkManager, update gpsSignalStrength: AMapNaviGPSSignalStrength) {
        Task { @MainActor in self.gpsSignal = Int(gpsSignalStrength.rawValue) }
    }

    public func walkManagerNeedRecalculateRoute(forYaw walkManager: AMapNaviWalkManager) {
        Task { @MainActor in self.isRecalculating = true }
    }

    public func walkManager(onArrivedDestination walkManager: AMapNaviWalkManager) {
        Task { @MainActor in
            Log.info("[NaviSDK] 步行到达目的地")
            self.isNavigating = false
            self.liveInfo = nil
            self.onArrived?()
        }
    }
}

// MARK: - AMapNaviRideManagerDelegate

extension NaviService: AMapNaviRideManagerDelegate {

    public func rideManager(onCalculateRouteSuccess rideManager: AMapNaviRideManager, calculateRouteResult: AMapNaviCalculateRouteResult) {
        Task { @MainActor in
            Log.info("[NaviSDK] 骑行算路成功")
            self.isRecalculating = false
            self.handlePlanSuccess()
        }
    }

    public func rideManager(_ rideManager: AMapNaviRideManager, onCalculateRouteFailure error: Error, calculateRouteResult: AMapNaviCalculateRouteResult) {
        Task { @MainActor in
            Log.warn("[NaviSDK] 骑行算路失败: \(error.localizedDescription)")
            self.isRecalculating = false
            self.handlePlanFailure(error)
        }
    }

    public func rideManager(_ rideManager: AMapNaviRideManager, playNaviSound soundString: String, soundStringType type: AMapNaviSoundType) {
        Task { @MainActor in self.handleTTS(soundString) }
    }

    // 【Bug 行30】rideManager:updateNaviInfo: 属 DataRepresentable 协议，迁移见文件底部

    public func rideManager(_ rideManager: AMapNaviRideManager, update gpsSignalStrength: AMapNaviGPSSignalStrength) {
        Task { @MainActor in self.gpsSignal = Int(gpsSignalStrength.rawValue) }
    }

    public func rideManagerNeedRecalculateRoute(forYaw rideManager: AMapNaviRideManager) {
        Task { @MainActor in self.isRecalculating = true }
    }

    public func rideManager(onArrivedDestination rideManager: AMapNaviRideManager) {
        Task { @MainActor in
            Log.info("[NaviSDK] 骑行到达目的地")
            self.isNavigating = false
            self.liveInfo = nil
            self.onArrived?()
        }
    }
}

// MARK: - 步行/骑行实时诱导数据通道（DataRepresentable 协议，【Bug 行30】）

extension NaviService: AMapNaviWalkDataRepresentable {
    public func walkManager(_ walkManager: AMapNaviWalkManager, update naviInfo: AMapNaviInfo?) {
        Task { @MainActor in
            guard let info = naviInfo else { return }
            self.liveInfo = LiveNaviInfo(currentRoadName: info.currentRoadName ?? "",
                                         nextRoadName: info.nextRoadName ?? "",
                                         remainDistance: Int(info.routeRemainDistance),
                                         remainTime: Int(info.routeRemainTime),
                                         segmentRemainDistance: Int(info.segmentRemainDistance),
                                         segmentRemainTime: Int(info.segmentRemainTime),
                                         iconType: Int(info.iconType.rawValue))
        }
    }
}

extension NaviService: AMapNaviRideDataRepresentable {
    public func rideManager(_ rideManager: AMapNaviRideManager, update naviInfo: AMapNaviInfo?) {
        Task { @MainActor in
            guard let info = naviInfo else { return }
            self.liveInfo = LiveNaviInfo(currentRoadName: info.currentRoadName ?? "",
                                         nextRoadName: info.nextRoadName ?? "",
                                         remainDistance: Int(info.routeRemainDistance),
                                         remainTime: Int(info.routeRemainTime),
                                         segmentRemainDistance: Int(info.segmentRemainDistance),
                                         segmentRemainTime: Int(info.segmentRemainTime),
                                         iconType: Int(info.iconType.rawValue))
        }
    }
}
