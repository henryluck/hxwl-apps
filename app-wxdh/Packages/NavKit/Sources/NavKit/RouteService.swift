import CoreKit
import CoreLocation
import Foundation
import MapKit

public struct RouteResult: Sendable {
    public var routes: [RouteOption]
    public var failure: NavFailure?
}

/// 算路服务：三种方式真实算路，多方案按引擎返回，不复制凑数（NAV-17/18/21）
@MainActor
public final class RouteService {

    public init() {}

    public func routes(from origin: Place,
                       to destination: Place,
                       mode: TravelMode,
                       requestId: String) async -> RouteResult {
        guard origin.hasValidCoordinate, destination.hasValidCoordinate else {
            return RouteResult(routes: [], failure: .invalidPlace)
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.gcj02Coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.gcj02Coordinate))
        request.transportType = Self.transportType(mode)
        request.requestsAlternateRoutes = true

        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            var options: [RouteOption] = []
            var seenSignatures = Set<String>()
            for (index, route) in response.routes.enumerated() {
                let polyline = Self.coordinates(from: route.polyline)
                // 重复线过滤：几何签名一致视为同一条（NAV-17）
                let signature = Self.signature(polyline)
                if seenSignatures.contains(signature) { continue }
                seenSignatures.insert(signature)

                let steps = Self.steps(from: route)
                let option = RouteOption(
                    id: "\(requestId)#\(index)",
                    mode: mode,
                    distance: route.distance,
                    expectedTravelTime: route.expectedTravelTime,
                    steps: steps,
                    polyline: polyline,
                    engineLabel: index == 0 ? "推荐" : "备选\(index)",
                    requestId: requestId)
                options.append(option)
                if options.count >= 3 { break }
            }
            guard !options.isEmpty else {
                return RouteResult(routes: [], failure: .noRoute)
            }
            return RouteResult(routes: options, failure: nil)
        } catch {
            return RouteResult(routes: [], failure: Self.classify(error, mode: mode))
        }
    }

    // MARK: - 映射

    static func transportType(_ mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .driving: return .automobile
        case .walking: return .walking
        case .cycling: return .cycling
        }
    }

    static func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                              count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    static func steps(from route: MKRoute) -> [NavStep] {
        var result: [NavStep] = []
        for (index, step) in route.steps.enumerated() {
            let coords = coordinates(from: step.polyline)
            guard let end = coords.last else { continue }
            let instruction = step.instructions.isEmpty
                ? (index == route.steps.count - 1 ? "到达目的地" : "继续前行")
                : step.instructions
            let isArrival = index == route.steps.count - 1
            result.append(NavStep(id: "\(route.name)#\(index)",
                                  index: index,
                                  instruction: instruction,
                                  distance: step.distance,
                                  coordinate: end,
                                  roadName: step.instructions.isEmpty ? "" : route.name,
                                  isArrivalStep: isArrival))
        }
        return result
    }

    static func signature(_ polyline: [CLLocationCoordinate2D]) -> String {
        guard let first = polyline.first, let last = polyline.last else { return "empty" }
        let length = Int(Geo.length(of: polyline).rounded())
        return String(format: "%.4f,%.4f-%.4f,%.4f-%d",
                      first.latitude, first.longitude, last.latitude, last.longitude, length)
    }

    static func classify(_ error: Error, mode: TravelMode) -> NavFailure {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .offline
            case .timedOut, .cannotConnectToHost, .cannotFindHost:
                return .serviceError
            default:
                break
            }
        }
        if let mkError = error as? MKError.Code {
            switch mkError {
            case .directionsNotFound, .placemarkNotFound:
                return .noRoute
            case .loadingThrottled:
                return .serviceError
            default:
                return .serviceError
            }
        }
        return .noRoute
    }
}
