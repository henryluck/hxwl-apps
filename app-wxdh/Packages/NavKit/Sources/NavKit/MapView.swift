import CoreLocation
import MapKit
import SwiftUI

/// 地图控制器：把 MKMapView 的命令式操作（跟随、全览、图层）暴露给 SwiftUI
@MainActor
public final class NavMapController: ObservableObject {
    weak var mapView: MKMapView?
    private var routeOverlay: MKPolyline?
    private var routeCasing: MKPolyline?
    private var originAnnotation: MKPointAnnotation?
    private var destinationAnnotation: MKPointAnnotation?
    private var poiAnnotations: [MKPointAnnotation] = []
    public private(set) var isFollowing = false

    /// 视图重建前的最后状态：新 MKMapView 挂上后重放，避免切换页面丢线/丢跟随
    private var lastRouteCoords: [CLLocationCoordinate2D] = []
    private var lastOrigin: Place?
    private var lastDestination: Place?
    private var lastPOIs: [Place] = []
    private var pendingFollow: (coordinate: CLLocationCoordinate2D, heading: Double?)?

    public init() {}

    /// 新地图视图挂载后调用：重放路线/标注/跟随
    func attach(map: MKMapView) {
        mapView = map
        if !lastRouteCoords.isEmpty {
            showRoute(lastRouteCoords, origin: lastOrigin, destination: lastDestination)
        }
        if !lastPOIs.isEmpty {
            showMarkers(lastPOIs)
        }
        if let pendingFollow {
            follow(pendingFollow.coordinate, heading: pendingFollow.heading, animated: false)
        }
    }

    public func setMapType(satellite: Bool) {
        mapView?.mapType = satellite ? .hybrid : .mutedStandard
        mapView?.pointOfInterestFilter = satellite ? .excludingAll : .includingAll
    }

    /// 绘制真实路线 geometry（NAV-18：不用两点直线）
    public func showRoute(_ coordinates: [CLLocationCoordinate2D],
                          origin: Place?,
                          destination: Place?) {
        lastRouteCoords = coordinates
        lastOrigin = origin
        lastDestination = destination
        guard let mapView else { return }
        clearRoute()
        guard coordinates.count >= 2 else { return }
        var coords = coordinates
        let casing = MKPolyline(coordinates: &coords, count: coords.count)
        mapView.addOverlay(casing, level: .aboveRoads)
        routeCasing = casing

        let line = MKPolyline(coordinates: &coords, count: coords.count)
        mapView.addOverlay(line, level: .aboveRoads)
        routeOverlay = line

        if let origin {
            let a = MKPointAnnotation()
            a.coordinate = origin.gcj02Coordinate
            a.title = origin.name
            a.subtitle = "起点"
            mapView.addAnnotation(a)
            originAnnotation = a
        }
        if let destination {
            let b = MKPointAnnotation()
            b.coordinate = destination.gcj02Coordinate
            b.title = destination.name
            b.subtitle = destination.address
            mapView.addAnnotation(b)
            destinationAnnotation = b
        }
    }

    public func showMarkers(_ places: [Place]) {
        lastPOIs = places
        guard let mapView else { return }
        mapView.removeAnnotations(poiAnnotations)
        poiAnnotations = places.map { place in
            let a = MKPointAnnotation()
            a.coordinate = place.gcj02Coordinate
            a.title = place.name
            a.subtitle = place.address
            return a
        }
        mapView.addAnnotations(poiAnnotations)
    }

    public func clearRoute() {
        guard let mapView else { return }
        if let routeOverlay { mapView.removeOverlay(routeOverlay) }
        if let routeCasing { mapView.removeOverlay(routeCasing) }
        if let originAnnotation { mapView.removeAnnotation(originAnnotation) }
        if let destinationAnnotation { mapView.removeAnnotation(destinationAnnotation) }
        routeOverlay = nil
        routeCasing = nil
        originAnnotation = nil
        destinationAnnotation = nil
    }

    /// 全览：涵盖真实两端与折线，留出卡片遮挡区域（NAV-18）
    public func fitRoute(edgePadding: UIEdgeInsets = UIEdgeInsets(top: 140, left: 40, bottom: 360, right: 40)) {
        guard let mapView, let overlay = routeOverlay else { return }
        isFollowing = false
        mapView.setVisibleMapRect(overlay.boundingMapRect,
                                  edgePadding: edgePadding, animated: true)
    }

    public func fit(_ region: MKCoordinateRegion) {
        guard let mapView else { return }
        isFollowing = false
        mapView.setRegion(region, animated: true)
    }

    /// 近距行进跟随：镜头随有效行进方向，不从开始就停在全览（NAV-22）
    public func follow(_ coordinate: CLLocationCoordinate2D, heading: Double?, animated: Bool = true) {
        pendingFollow = (coordinate, heading)
        guard let mapView else { return }
        isFollowing = true
        let camera = MKMapCamera(lookingAtCenter: coordinate,
                                 fromDistance: 420,
                                 pitch: 45,
                                 heading: heading ?? mapView.camera.heading)
        mapView.setCamera(camera, animated: animated)
    }

    public func stopFollowing() {
        isFollowing = false
        pendingFollow = nil
    }
}

/// SwiftUI 地图容器（iOS 16 用 UIViewRepresentable，叠加真实路线与标注）
public struct NavMapView: UIViewRepresentable {
    let controller: NavMapController
    let satellite: Bool
    let showsUserLocation: Bool
    let onUserInteraction: () -> Void

    public init(controller: NavMapController, satellite: Bool,
                showsUserLocation: Bool = true,
                onUserInteraction: @escaping () -> Void = {}) {
        self.controller = controller
        self.satellite = satellite
        self.showsUserLocation = showsUserLocation
        self.onUserInteraction = onUserInteraction
    }

    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = showsUserLocation
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        map.pointOfInterestFilter = .excludingAll
        map.mapType = satellite ? .hybrid : .mutedStandard
        controller.attach(map: map)
        return map
    }

    public func updateUIView(_ map: MKMapView, context: Context) {
        if (map.mapType == .hybrid) != satellite {
            controller.setMapType(satellite: satellite)
        }
        if map.showsUserLocation != showsUserLocation {
            map.showsUserLocation = showsUserLocation
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, MKMapViewDelegate {
        private let parent: NavMapView
        init(_ parent: NavMapView) { self.parent = parent }

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            // 普通路线清晰蓝色；只有真实路况才分段着色（NAV-18）
            let isCasing = mapView.overlays.firstIndex(where: { $0 === polyline }) == 0
            renderer.strokeColor = isCasing
                ? UIColor(white: 1, alpha: 0.9)
                : UIColor(red: 0.05, green: 0.42, blue: 0.85, alpha: 1)
            renderer.lineWidth = isCasing ? 10 : 6
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let identifier = "nav-pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation,
                                                                    reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = true
            // 起点绿、终点红，另有文字补充，不只靠颜色（NAV-18）
            if annotation.subtitle == "起点" {
                view.markerTintColor = UIColor(red: 0.18, green: 0.55, blue: 0.34, alpha: 1)
                view.glyphText = "起"
            } else {
                view.markerTintColor = UIColor(red: 0.81, green: 0.27, blue: 0.24, alpha: 1)
                view.glyphText = "终"
            }
            view.displayPriority = .required
            return view
        }

        public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // 用户拖动地图不停止导航，只退出跟随（NAV-22）
            guard let gesture = mapView.subviews.first?.gestureRecognizers, !gesture.isEmpty else { return }
            if gesture.contains(where: { $0.state == .began || $0.state == .changed }) {
                parent.onUserInteraction()
            }
        }
    }
}
