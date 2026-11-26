import AMapFoundationKit
import AMapNaviKit
import MAMapKit
import SwiftUI

/// 高德官方导航视图容器（AMapNaviDriveView / WalkView / RideView）
/// 通过 NaviService.addDataRepresentative(view) 注册后自动渲染导航过程。
///
/// 【Bug 行28/36】方向一致性修复（对比高德官方 App）：
/// ① 初始 trackingMode 显式 .carNorth（车头朝上，地图随行进方向旋转）——
///    三个视图 SDK 默认都是 .mapNorth（正北朝上），不跟随行进方向；
/// ② Ride/Walk 视图没有 canChangeTrackingMode 开关（仅 DriveView 有），
///    SDK 内部在普通态会自行切回正北朝上 → 用 view delegate 的
///    didChangeTrackingMode 回调检测到非 carNorth 立即改回；
/// ③ showMode 锁 .carPositionLocked（锁车态）——锁车态下 SDK 才按
///    车头朝上驱动地图旋转；用户拖图后回跟随也回到锁车态。
public struct AMapNaviViewContainer: UIViewRepresentable {
    let kind: NaviViewKind
    let onAttached: (UIView) -> Void

    public init(kind: NaviViewKind, onAttached: @escaping (UIView) -> Void) {
        self.kind = kind
        self.onAttached = onAttached
    }

    public func makeUIView(context: Context) -> UIView {
        let view: UIView
        switch kind {
        case .drive:
            let v = AMapNaviDriveView(frame: .zero)
            v.showUIElements = false   // 用自研 UI 横幅，隐藏官方 UI（保留地图渲染）
            v.trackingMode = .carNorth
            v.showMode = .carPositionLocked
            v.canChangeTrackingMode = false   // DriveView 专属开关：禁止 SDK 内部改回正北
            v.delegate = context.coordinator
            view = v
        case .walk:
            let v = AMapNaviWalkView(frame: .zero)
            v.showUIElements = false
            v.trackingMode = .carNorth
            v.showMode = .carPositionLocked
            v.delegate = context.coordinator
            view = v
        case .ride:
            let v = AMapNaviRideView(frame: .zero)
            v.showUIElements = false
            v.trackingMode = .carNorth
            v.showMode = .carPositionLocked
            v.delegate = context.coordinator
            view = v
        }
        onAttached(view)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    /// 强制「车头朝上」的守护者：SDK 改掉跟随模式就立即改回来
    public final class Coordinator: NSObject,
                                    AMapNaviDriveViewDelegate,
                                    AMapNaviWalkViewDelegate,
                                    AMapNaviRideViewDelegate {

        /// 防抖：SDK 设置 trackingMode 会再触发一次 didChange 回调，
        /// 用时间窗避免无限循环
        private var lastCorrection = Date.distantPast

        private func enforceCarNorth() {
            guard Date().timeIntervalSince(lastCorrection) > 0.1 else { return }
            lastCorrection = Date()
            Task { @MainActor in
                guard let view = NaviService.shared.activeNaviView else { return }
                switch view {
                case let drive as AMapNaviDriveView:
                    if drive.trackingMode != .carNorth { drive.trackingMode = .carNorth }
                    if drive.showMode != .carPositionLocked { drive.showMode = .carPositionLocked }
                case let walk as AMapNaviWalkView:
                    if walk.trackingMode != .carNorth { walk.trackingMode = .carNorth }
                    if walk.showMode != .carPositionLocked { walk.showMode = .carPositionLocked }
                case let ride as AMapNaviRideView:
                    if ride.trackingMode != .carNorth { ride.trackingMode = .carNorth }
                    if ride.showMode != .carPositionLocked { ride.showMode = .carPositionLocked }
                default:
                    break
                }
            }
        }

        // MARK: - AMapNaviDriveViewDelegate

        public func driveView(_ driveView: AMapNaviDriveView, didChange trackingMode: AMapNaviViewTrackingMode) {
            if trackingMode != .carNorth { enforceCarNorth() }
        }

        public func driveView(_ driveView: AMapNaviDriveView, didChange showMode: AMapNaviDriveViewShowMode) {
            // 全览态是我们自己的「回到跟随」按钮路径，普通态可能是 SDK 内部切换 → 都拉回锁车
            if showMode == .normal { enforceCarNorth() }
        }

        // MARK: - AMapNaviWalkViewDelegate

        public func walkView(_ walkView: AMapNaviWalkView, didChange trackingMode: AMapNaviViewTrackingMode) {
            if trackingMode != .carNorth { enforceCarNorth() }
        }

        public func walkView(_ walkView: AMapNaviWalkView, didChange showMode: AMapNaviWalkViewShowMode) {
            if showMode == .normal { enforceCarNorth() }
        }

        // MARK: - AMapNaviRideViewDelegate

        public func rideView(_ rideView: AMapNaviRideView, didChange trackingMode: AMapNaviViewTrackingMode) {
            if trackingMode != .carNorth { enforceCarNorth() }
        }

        public func rideView(_ rideView: AMapNaviRideView, didChange showMode: AMapNaviRideViewShowMode) {
            if showMode == .normal { enforceCarNorth() }
        }
    }
}

/// 非导航场景的高德普通地图（规划页：显示多方案路线）
/// 保留原 MapKit NavMapView 的外部接口形状，内部换 MAMapView。
public struct AMapPlanMapView: UIViewRepresentable {
    public final class Coordinator: NSObject, MAMapViewDelegate {
        var onUserInteraction: (() -> Void)?
        /// 【Bug 行35】地图初始化完成回调：规划页 .task 可能先于 makeUIView 执行，
        /// 路线画到了旧/空地图上。地图就绪后通知视图层重画一次。
        var onMapReady: (() -> Void)?
        private var firedReady = false

        public func mapViewInitComplete(_ mapView: MAMapView) {
            guard !firedReady else { return }
            firedReady = true
            onMapReady?()
        }

        public func mapView(_ mapView: MAMapView!, mapWillMoveByUser wasUserAction: Bool) {
            if wasUserAction { onUserInteraction?() }
        }

        public func mapView(_ mapView: MAMapView!, rendererFor overlay: MAOverlay!) -> MAOverlayRenderer! {
            if let renderer = planMapRendererSync(for: overlay) { return renderer }
            return MAOverlayRenderer(overlay: overlay)
        }

        public func mapView(_ mapView: MAMapView!, viewFor annotation: MAAnnotation!) -> MAAnnotationView! {
            guard annotation is MAPointAnnotation else { return nil }
            let identifier = "plan-pin"
            if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) {
                reused.annotation = annotation
                return reused
            }
            guard let view = MAPinAnnotationView(annotation: annotation, reuseIdentifier: identifier) else {
                return nil
            }
            view.canShowCallout = true
            view.pinColor = (annotation.title == "起点") ? .green : .red
            return view
        }
    }

    let onUserInteraction: () -> Void
    let onMapReady: () -> Void
    weak var coordinator: Coordinator?

    public init(onUserInteraction: @escaping () -> Void = {},
                onMapReady: @escaping () -> Void = {}) {
        self.onUserInteraction = onUserInteraction
        self.onMapReady = onMapReady
    }

    public func makeUIView(context: Context) -> MAMapView {
        let map = MAMapView(frame: .zero)
        map.showsUserLocation = true
        map.isRotateEnabled = true
        map.userTrackingMode = .follow
        map.showsCompass = false
        map.showsScale = false
        map.delegate = context.coordinator
        context.coordinator.onUserInteraction = onUserInteraction
        context.coordinator.onMapReady = onMapReady
        PlanMapHolder.shared.mapView = map
        return map
    }

    public func updateUIView(_ map: MAMapView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }
}

/// 规划页地图共享持有（SwiftUI 重建视图时不丢状态）
@MainActor
public final class PlanMapHolder: ObservableObject {
    public static let shared = PlanMapHolder()
    /// 【Bug 行44·行48】mapView 挂载即发 objectWillChange：规划页首帧算路完成早于
    /// 地图初始化完成时（或 mapInitComplete 回调缺失的机型），refreshPlanMap 首次
    /// 执行时 mapView 为 nil 直接 return，路线丢失、直到切换出行模式才出现。
    /// 视图层订阅此信号在地图就绪时补画一次。
    @Published public var mapView: MAMapView?

    /// 画多方案路线（不同颜色，选中加粗）
    public func showRoutes(_ routes: [RouteOption], selectedId: String?) {
        guard let map = mapView else { return }
        map.removeOverlays(map.overlays)
        PlanRenderStore.removeAll()
        for route in routes where route.id != selectedId {
            addLine(route, color: UIColor(red: 0.55, green: 0.62, blue: 0.66, alpha: 1),
                    width: 5, dashed: false)
        }
        if let selected = routes.first(where: { $0.id == selectedId }) {
            addLine(selected, color: UIColor(red: 0.05, green: 0.42, blue: 0.85, alpha: 1),
                    width: 8, dashed: false)
        }
        fit(routes: routes)
    }

    private func addLine(_ route: RouteOption, color: UIColor, width: CGFloat, dashed: Bool) {
        guard let map = mapView else { return }
        var coords = route.polyline
        guard coords.count >= 2 else { return }
        if let line = MAPolyline(coordinates: &coords, count: UInt(coords.count)) {
            PlanRenderStore.append((line, color, width))
            map.add(line)
        }
    }

    /// 起终点标注
    public func showEndpoints(origin: Place?, destination: Place?) {
        guard let map = mapView else { return }
        map.removeAnnotations(map.annotations)
        if let origin {
            let a = MAPointAnnotation()
            a.coordinate = CLLocationCoordinate2D(latitude: origin.gcj02Coordinate.latitude,
                                                  longitude: origin.gcj02Coordinate.longitude)
            a.title = "起点"
            map.addAnnotation(a)
        }
        if let destination {
            let b = MAPointAnnotation()
            b.coordinate = CLLocationCoordinate2D(latitude: destination.gcj02Coordinate.latitude,
                                                  longitude: destination.gcj02Coordinate.longitude)
            b.title = destination.name
            map.addAnnotation(b)
        }
    }

    /// 全览路线【Bug 行35/34/39/44】
    /// 此前用 center+span 手算，两个问题：
    /// ① 竖屏下经度跨度 ×1.5 被过分放大，整条路线缩成一小段（比例太小看不清）；
    /// ② 首次进页无路线数据时直接 return，地图停在默认「全国视野」（中国地图）。
    /// 改用 MAMapSetRect 按路线边界矩形 + 像素内边距适配（任何屏幕比例都撑满可视区）。
    public func fit(routes: [RouteOption]) {
        guard let map = mapView else { return }
        guard !routes.isEmpty else {
            // 无路线兜底：视野回到用户当前位置（而不是全国地图）
            if let loc = map.userLocation.location {
                map.setCenter(loc.coordinate, animated: true)
                map.setZoomLevel(15, animated: true)
            }
            return
        }
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for route in routes {
            for c in route.polyline {
                minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }
        }
        guard minLat <= maxLat else { return }

        // 路线边界 → MAMapRect（Mercator）→ 可视区域（按像素内边距适配任意屏幕比例）
        let southWest = MAMapPointForCoordinate(CLLocationCoordinate2D(latitude: minLat, longitude: minLon))
        let northEast = MAMapPointForCoordinate(CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
        let rect = MAMapRect(origin: MAMapPoint(x: min(southWest.x, northEast.x),
                                                y: min(southWest.y, northEast.y)),
                             size: MAMapSize(width: abs(northEast.x - southWest.x),
                                             height: abs(northEast.y - southWest.y)))
        // 像素边距：上 120（起终点栏）、左 40、下 = 屏高 42%（底部卡片遮挡区）、右 40
        let bottomPadding: CGFloat = map.frame.height * 0.42 + 40
        map.setVisibleMapRect(rect,
                              edgePadding: UIEdgeInsets(top: 120, left: 40,
                                                        bottom: bottomPadding, right: 40),
                              animated: true)
    }

    /// 地图就绪/重进规划页时的默认视野：回到用户位置（【Bug 行33/44】导航结束回来
    /// 显示偏离/全国地图——每次规划页出现且无路线时重置到当前位置）
    public func resetToUserLocation() {
        guard let map = mapView else { return }
        if let loc = map.userLocation.location {
            map.setCenter(loc.coordinate, animated: false)
            map.setZoomLevel(15, animated: false)
        }
    }

    private init() {}
}

/// 渲染参数存储（脱离 MainActor 类，delegate 回调可直接读）
enum PlanRenderStore {
    nonisolated(unsafe) static var items: [(overlay: MAPolyline, color: UIColor, width: CGFloat)] = []
    nonisolated(unsafe) static let lock = NSLock()

    static func append(_ item: (overlay: MAPolyline, color: UIColor, width: CGFloat)) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }

    static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }

    static func find(_ overlay: MAPolyline) -> (color: UIColor, width: CGFloat)? {
        lock.lock(); defer { lock.unlock() }
        return items.first(where: { $0.overlay === overlay }).map { ($0.color, $0.width) }
    }
}

/// MAPolyline 渲染参数查找（delegate 回调上下文使用，非隔离）
nonisolated func planMapRendererSync(for overlay: MAOverlay) -> MAOverlayRenderer? {
    guard let polyline = overlay as? MAPolyline,
          let renderer = MAPolylineRenderer(polyline: polyline) else { return nil }
    if let item = PlanRenderStore.find(polyline) {
        renderer.strokeColor = item.color
        renderer.lineWidth = item.width
    } else {
        renderer.strokeColor = UIColor.systemBlue
        renderer.lineWidth = 6
    }
    return renderer
}
