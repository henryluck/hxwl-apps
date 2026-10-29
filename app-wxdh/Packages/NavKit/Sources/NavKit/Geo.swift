import CoreLocation
import Foundation
import MapKit

/// 坐标与几何工具。
/// NAV-38：每个地点带坐标系，传 SDK 前按真实规范一次转换，防漏转/重复转换。
public enum Geo {

    // MARK: - WGS-84 ⇄ GCJ-02

    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    /// 是否在中国境外（境外不做偏移）
    public static func isOutOfChina(lat: Double, lon: Double) -> Bool {
        !(lon > 73.66 && lon < 135.05 && lat > 3.86 && lat < 53.55)
    }

    public static func wgs84ToGcj02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = coordinate.latitude, lon = coordinate.longitude
        if isOutOfChina(lat: lat, lon: lon) { return coordinate }
        var dLat = transformLat(lon - 105.0, lat - 35.0)
        var dLon = transformLon(lon - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon)
    }

    public static func gcj02ToWgs84(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = coordinate.latitude, lon = coordinate.longitude
        if isOutOfChina(lat: lat, lon: lon) { return coordinate }
        var dLat = transformLat(lon - 105.0, lat - 35.0)
        var dLon = transformLon(lon - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: lat - dLat, longitude: lon - dLon)
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }

    /// 把任意坐标系坐标转到指定坐标系（只转一次）
    public static func convert(_ coordinate: CLLocationCoordinate2D,
                               from: CoordinateSystem,
                               to: CoordinateSystem) -> CLLocationCoordinate2D {
        if from == to { return coordinate }
        if from == .wgs84 && to == .gcj02 { return wgs84ToGcj02(coordinate) }
        if from == .gcj02 && to == .wgs84 { return gcj02ToWgs84(coordinate) }
        return coordinate
    }

    // MARK: - 折线几何

    public static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// 点到线段的最短距离（米）与垂足
    public static func project(_ p: CLLocationCoordinate2D,
                               onto a: CLLocationCoordinate2D,
                               _ b: CLLocationCoordinate2D) -> (distance: Double, point: CLLocationCoordinate2D) {
        // 以 a 为原点的局部平面近似（短距离足够精确，避免逐点大地测量开销）
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(a.latitude * .pi / 180)
        let ax = 0.0, ay = 0.0
        let bx = (b.longitude - a.longitude) * lonScale
        let by = (b.latitude - a.latitude) * latScale
        let px = (p.longitude - a.longitude) * lonScale
        let py = (p.latitude - a.latitude) * latScale

        let dx = bx - ax, dy = by - ay
        let lengthSq = dx * dx + dy * dy
        var t = 0.0
        if lengthSq > 0 {
            t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSq))
        }
        let cx = ax + t * dx, cy = ay + t * dy
        let dist = sqrt(pow(px - cx, 2) + pow(py - cy, 2))
        let point = CLLocationCoordinate2D(latitude: a.latitude + cy / latScale,
                                           longitude: a.longitude + cx / lonScale)
        return (dist, point)
    }

    /// 定位点匹配到折线：返回离路距离、沿线里程、垂足与所在段索引
    public static func match(_ p: CLLocationCoordinate2D,
                             on polyline: [CLLocationCoordinate2D])
        -> (offRouteDistance: Double, progress: Double, point: CLLocationCoordinate2D, segment: Int) {
        guard polyline.count >= 2 else {
            let d = polyline.first.map { distance(p, $0) } ?? .greatestFiniteMagnitude
            return (d, 0, polyline.first ?? p, 0)
        }
        var bestDistance = Double.greatestFiniteMagnitude
        var bestPoint = polyline[0]
        var bestSegment = 0
        var bestProgress = 0.0
        var accumulated = 0.0

        for i in 0..<(polyline.count - 1) {
            let a = polyline[i], b = polyline[i + 1]
            let segLength = distance(a, b)
            let result = project(p, onto: a, b)
            if result.distance < bestDistance {
                bestDistance = result.distance
                bestPoint = result.point
                bestSegment = i
                let alongSeg = distance(a, result.point)
                bestProgress = accumulated + alongSeg
            }
            accumulated += segLength
        }
        return (bestDistance, bestProgress, bestPoint, bestSegment)
    }

    /// 折线总长（米）
    public static func length(of polyline: [CLLocationCoordinate2D]) -> Double {
        guard polyline.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(polyline.count - 1) {
            total += distance(polyline[i], polyline[i + 1])
        }
        return total
    }

    /// 折线剩余里程（从 progress 到终点）
    public static func remaining(_ polyline: [CLLocationCoordinate2D], from progress: Double) -> Double {
        max(0, length(of: polyline) - progress)
    }

    public static func region(for polyline: [CLLocationCoordinate2D],
                              padding: Double = 1.35) -> MKCoordinateRegion? {
        guard !polyline.isEmpty else { return nil }
        var minLat = polyline[0].latitude, maxLat = polyline[0].latitude
        var minLon = polyline[0].longitude, maxLon = polyline[0].longitude
        for c in polyline {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * padding, 0.004),
                                    longitudeDelta: max((maxLon - minLon) * padding, 0.004))
        return MKCoordinateRegion(center: center, span: span)
    }

    /// 两点连线的中点（用于起点/终点重叠时取景）
    public static func midRegion(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let center = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2,
                                            longitude: (a.longitude + b.longitude) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(abs(a.latitude - b.latitude) * 1.6, 0.005),
                                    longitudeDelta: max(abs(a.longitude - b.longitude) * 1.6, 0.005))
        return MKCoordinateRegion(center: center, span: span)
    }

    /// 方位角（0-360，正北 0）
    public static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension Place {
    /// 转为 GCJ-02（地图展示与算路统一坐标系）
    public var gcj02Coordinate: CLLocationCoordinate2D {
        Geo.convert(coordinate, from: coordinateSystem, to: .gcj02)
    }
}
