import AMapFoundationKit
import AMapSearchKit
import CoreKit
import Foundation
import MapKit

/// 地址标准化服务（地址整理 v0.32 增强：提取候选 → 高德标准化 → 便于导航）。
///
/// 主通道：**高德 iOS SDK 地理编码**（`AMapGeocodeSearch`），复用宿主已配置的
/// `AMapServices.shared().apiKey`（spec.integrations.amap.key），无需额外申请
/// Web 服务 key；输出 `formattedAddress`（含省/市/区/街道门牌）+ adcode/level。
/// 兜底：**MapKit `MKLocalSearch`**——高德请求失败/无结果时产出可导航地址，
/// 与工程现有检索同源；两者都失败时调用方保留原文（不阻塞导航）。
public enum AddressStandardizer {

    public struct StandardAddress: Equatable {
        public let formatted: String      // 标准地址（用于导航检索框）
        public let source: Source
        public enum Source: String { case amap = "高德", mapkit = "地图检索" }
    }

    /// 标准化单个地址文本（主线程回调，异步）
    public static func standardize(_ address: String) async -> StandardAddress? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let r = await amapGeocode(trimmed) { return r }
        return await mapkitSearch(trimmed)
    }

    // MARK: - 高德 iOS SDK 地理编码（复用现有 SDK key）

    /// 搜索请求需强引用 delegate（AMapSearchAPI.delegate 为 weak）+ continuation，
    /// 用 UUID 表持有直到回调或超时，避免更早的请求回调错配。
    private struct Pending {
        let search: AMapSearchAPI
        let delegate: GeocodeDelegate
        let continuation: CheckedContinuation<StandardAddress?, Never>
    }
    private static var pending: [UUID: Pending] = [:]

    private final class GeocodeDelegate: NSObject, AMapSearchDelegate {
        private let id: UUID
        private let completion: (AMapGeocodeSearchResponse?) -> Void
        init(id: UUID, completion: @escaping (AMapGeocodeSearchResponse?) -> Void) {
            self.id = id
            self.completion = completion
        }
        func onGeocodeSearchDone(_ request: AMapGeocodeSearchRequest!,
                                 response: AMapGeocodeSearchResponse!) {
            finish(response, error: nil)
        }
        func aMapSearchRequest(_ request: Any!, didFailWithError error: Error) {
            finish(nil, error: error)
        }
        private func finish(_ response: AMapGeocodeSearchResponse?, error: Error?) {
            let entry = pending.removeValue(forKey: id)
            if let error {
                Log.warn("[AddrStd] 高德地理编码失败: \(error.localizedDescription)")
            }
            completion(response)
            _ = entry
        }
    }

    private static func amapGeocode(_ address: String) async -> StandardAddress? {
        guard !(AMapServices.shared().apiKey ?? "").isEmpty else {
            Log.warn("[AddrStd] 高德 SDK key 未配置，跳过高德标准化")
            return nil
        }
        let id = UUID()
        let request = AMapGeocodeSearchRequest()
        request.address = address
        // 城市约束：原文含「XX市」时显式指定，避免跨省同名区县误匹配
        //（如「杭州市西湖区…」被匹配到「南昌市西湖区」）
        request.city = cityHint(from: address)
        guard let search = AMapSearchAPI() else {
            Log.warn("[AddrStd] 高德搜索对象创建失败")
            return nil
        }
        search.timeout = 6

        return await withCheckedContinuation { continuation in
            let delegate = GeocodeDelegate(id: id) { response in
                guard let geo = response?.geocodes?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let formatted = geo.formattedAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !formatted.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                // 只匹配到行政区县（level=区县/城市/省）时，补回原文里的街道门牌细节，
                // 避免标准化反而把「湖滨路26号」这类可导航信息丢掉
                let level = geo.level ?? ""
                var result = formatted
                if ["省", "城市", "区县", "乡镇", "街道"].contains(level),
                   let suffix = detailSuffix(from: address), !suffix.isEmpty {
                    result = formatted + suffix
                }
                Log.info("[AddrStd] 高德标准化: \(result) level=\(level) adcode=\(geo.adcode ?? "-")")
                continuation.resume(returning: StandardAddress(formatted: result, source: .amap))
            }
            pending[id] = Pending(search: search, delegate: delegate, continuation: continuation)
            search.delegate = delegate
            search.aMapGeocodeSearch(request)
            // 双保险：SDK 个别异常场景不回调 delegate → 6 秒后兜底返回 nil（不阻塞导航）
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                guard let entry = pending.removeValue(forKey: id) else { return }
                Log.warn("[AddrStd] 高德地理编码超时: \(address)")
                entry.continuation.resume(returning: nil)
            }
        }
    }

    /// 取行政区（省/市/区/县）之后的街道门牌尾巴，如「湖滨路26号」。
    private static func detailSuffix(from address: String) -> String? {
        let compact = address.filter { !$0.isWhitespace }
        guard let regex = try? NSRegularExpression(pattern: "^.*?(?:省|市).*?(?:区|县)(.+)$"),
              let match = regex.firstMatch(in: compact, range: NSRange(location: 0, length: compact.utf16.count)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: compact)
        else { return nil }
        let tail = String(compact[range])
        return tail.isEmpty ? nil : tail
    }

    /// 从地址文字中提取城市名（优先「XX市」，其次「XX省」不传——省名不是合法 city 参数）。
    private static func cityHint(from address: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "([\\u4e00-\\u9fa5]{2,8}?)(市|省)") else { return nil }
        let ns = address as NSString
        let matches = regex.matches(in: address, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let token = ns.substring(with: match.range)
            if token.hasSuffix("市"), token.count > 1 {
                return String(token.dropLast())
            }
        }
        return nil
    }

    // MARK: - MapKit 兜底（与工程检索同源）

    private static func mapkitSearch(_ address: String) async -> StandardAddress? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        // 中国境内检索区域限制，避免海外结果干扰
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 32.0, longitude: 110.0),
            span: MKCoordinateSpan(latitudeDelta: 18, longitudeDelta: 18))
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start(),
              let first = response.mapItems.first
        else { return nil }
        let placemark = first.placemark
        var parts: [String] = []
        if let province = placemark.administrativeArea, !province.isEmpty { parts.append(province) }
        if let city = placemark.locality, !city.isEmpty, city != placemark.administrativeArea { parts.append(city) }
        if let district = placemark.subLocality, !district.isEmpty { parts.append(district) }
        if let thoroughfare = placemark.thoroughfare, !thoroughfare.isEmpty { parts.append(thoroughfare) }
        if let num = placemark.subThoroughfare, !num.isEmpty { parts.append(num) }
        let formatted = parts.isEmpty
            ? (placemark.name ?? address)
            : parts.joined(separator: "")
        Log.info("[AddrStd] MapKit 标准化: \(formatted)")
        return StandardAddress(formatted: formatted, source: .mapkit)
    }
}
