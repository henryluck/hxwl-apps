import AMapFoundationKit
import AMapNaviKit
import MAMapKit
import SwiftUI

/// 高德官方导航视图容器（AMapNaviDriveView / WalkView / RideView）
/// 通过 NaviService.addDataRepresentative(view) 注册后自动渲染导航过程。
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
            // 【Bug 行28】显式锁车头朝上：地图随行进方向旋转，与手机朝向一致。
            // 默认虽为 CarNorth，但用户手动拖图后官方会自动切回正北朝上导致"方向不一致"
            v.trackingMode = .carNorth
            v.canChangeTrackingMode = false
            view = v
        case .walk:
            let v = AMapNaviWalkView(frame: .zero)
            v.showUIElements = false
            v.trackingMode = .carNorth
            view = v
        case .ride:
            let v = AMapNaviRideView(frame: .zero)
            v.showUIElements = false
            v.trackingMode = .carNorth
            view = v
        }
        onAttached(view)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 非导航场景的高德普通地图（规划页：显示多方案路线）
/// 保留原 MapKit NavMapView 的外部接口形状，内部换 MAMapView。
public struct AMapPlanMapView: UIViewRepresentable {
    public final class Coordinator: NSObject, MAMapViewDelegate {
        var onUserInteraction: (() -> Void)?

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
    weak var coordinator: Coordinator?

    public init(onUserInteraction: @escaping () -> Void) {
        self.onUserInteraction = onUserInteraction
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
    public var mapView: MAMapView?

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

    public func fit(routes: [RouteOption]) {
        guard let map = mapView, let first = routes.first else { return }
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for route in routes {
            for c in route.polyline {
                minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
                minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
            }
        }
        guard minLat <= maxLat else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MACoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.5),
                                    longitudeDelta: max(0.02, (maxLon - minLon) * 1.5))
        map.setRegion(MACoordinateRegion(center: center, span: span), animated: true)
        _ = first
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
