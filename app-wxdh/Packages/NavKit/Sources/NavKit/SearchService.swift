import CoreKit
import CoreLocation
import Foundation
import MapKit

/// 检索结果包：成功/空/失败必须分开（NAV-07，失败分流表）
public struct SearchOutcome: Sendable {
    public var results: [Place]
    public var isEmpty: Bool { results.isEmpty }
    public var failure: NavFailure?

    public static func success(_ places: [Place]) -> SearchOutcome {
        SearchOutcome(results: places, failure: nil)
    }

    public static func failed(_ failure: NavFailure) -> SearchOutcome {
        SearchOutcome(results: [], failure: failure)
    }
}

/// 输入联想候选（未带坐标，选中后需正式解析）
public struct Suggestion: Identifiable, Equatable, Sendable {
    public var id: String { "\(title)|\(subtitle)" }
    public var title: String
    public var subtitle: String
}

/// 六类周边服务（NAV-12）
public enum NearbyCategory: String, CaseIterable, Identifiable, Sendable {
    case charger, fishingSpot, tackleShop, hospital, gym, park

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .charger: return "充电桩"
        case .fishingSpot: return "钓点"
        case .tackleShop: return "渔具店"
        case .hospital: return "医院"
        case .gym: return "健身房"
        case .park: return "公园"
        }
    }

    public var icon: String {
        switch self {
        case .charger: return "bolt.car.fill"
        case .fishingSpot: return "fish.fill"
        case .tackleShop: return "figure.fishing"
        case .hospital: return "cross.case.fill"
        case .gym: return "dumbbell.fill"
        case .park: return "tree.fill"
        }
    }

    /// 真实 POI 类别映射（无对应类别的品类回落到关键词，不造数据）
    var poiCategories: [MKPointOfInterestCategory] {
        switch self {
        case .charger: return [.evCharger]
        case .hospital: return [.hospital]
        case .gym: return [.fitnessCenter]
        case .park: return [.park]
        case .fishingSpot, .tackleShop: return []
        }
    }

    var queryTerms: [String] {
        switch self {
        case .charger: return ["充电桩", "充电站"]
        case .fishingSpot: return ["钓点", "钓鱼"]
        case .tackleShop: return ["渔具店", "渔具"]
        case .hospital: return ["医院"]
        case .gym: return ["健身房"]
        case .park: return ["公园"]
        }
    }
}

/// 检索服务：联想、正式检索、周边分页，全部基于系统地图真实数据（NAV-06～14）
@MainActor
public final class SearchService: NSObject, ObservableObject {
    /// 输入联想
    @Published public private(set) var suggestions: [Suggestion] = []
    @Published public private(set) var isSuggesting = false

    private var completer: MKLocalSearchCompleter?
    private var completerDelegate: CompleterDelegate?
    private var suggestTask: Task<Void, Never>?
    private var currentQueryId = UUID()
    private var suggestRegion: MKCoordinateRegion?

    public override init() {
        super.init()
    }

    // MARK: - 输入联想（300ms 防抖，取消旧代次；NAV-07 / D03 建议值）

    public func updateSuggestions(query: String,
                                  region: MKCoordinateRegion?,
                                  onUpdate: (([Suggestion]) -> Void)? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestTask?.cancel()
        guard !trimmed.isEmpty else {
            suggestions = []
            isSuggesting = false
            onUpdate?([])
            return
        }
        isSuggesting = true
        suggestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runCompleter(query: trimmed, region: region, onUpdate: onUpdate)
        }
    }

    private func runCompleter(query: String,
                              region: MKCoordinateRegion?,
                              onUpdate: (([Suggestion]) -> Void)?) async {
        let delegate = CompleterDelegate()
        let completer = MKLocalSearchCompleter()
        completer.delegate = delegate
        completer.resultTypes = [.pointOfInterest, .address]
        if let region {
            completer.region = region
            // 附近优先：缩小偏好区域，不替代正式检索的距离排序
            if #available(iOS 18.0, *) {
                completer.regionPriority = .required
            }
        }
        completer.queryFragment = query
        self.completer = completer
        self.completerDelegate = delegate

        // 等待结果（completer 无完成回调，按 1.2s 收敛或首个回调返回）
        let results: [MKLocalSearchCompletion] = await withCheckedContinuation { cont in
            delegate.onUpdate = { completions in
                cont.resume(returning: completions)
            }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                delegate.fire(completer.results)
            }
        }
        guard !Task.isCancelled else { return }
        suggestions = results.prefix(12).map { Suggestion(title: $0.title, subtitle: $0.subtitle) }
        isSuggesting = false
        onUpdate?(suggestions)
    }

    public func clearSuggestions() {
        suggestTask?.cancel()
        suggestions = []
        isSuggesting = false
    }

    // MARK: - 正式检索（即使联想 0 条也允许提交；NAV-07）

    public func search(query: String,
                       scope: SearchScope,
                       center: CLLocationCoordinate2D?,
                       kind: SearchKind = .keyword) async -> SearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(.invalidPlace) }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.pointOfInterest, .address]
        if let region = region(for: scope, center: center) {
            request.region = region
        }

        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            var places = response.mapItems.map { Self.place(from: $0, source: .mapSearch) }
            // 坐标有效性与去重（NAV-09：不同站台/出口不按名称去重，按 ID + 坐标）
            places = Self.dedupe(places)
            if let center {
                places = places.sorted { a, b in
                    let da = Geo.distance(center, a.gcj02Coordinate)
                    let db = Geo.distance(center, b.gcj02Coordinate)
                    if abs(da - db) < 1 { return a.name < b.name }
                    return da < db
                }
            }
            return .success(Array(places.prefix(30)))
        } catch {
            return .failed(Self.classify(error))
        }
    }

    /// 用联想候选解析出完整地点对象（点击候选 → 明确状态，不停留在联想列表）
    public func resolve(_ suggestion: Suggestion, scope: SearchScope) async -> Place? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [suggestion.title, suggestion.subtitle]
            .filter { !$0.isEmpty }.joined(separator: " ")
        request.resultTypes = [.pointOfInterest, .address]
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start(),
              let item = response.mapItems.first else { return nil }
        var place = Self.place(from: item, source: .suggestion)
        if place.name.isEmpty { place.name = suggestion.title }
        return place
    }

    // MARK: - 周边分页（NAV-13：首批 20、追加 20，距离排序跨页连续，末页停止）

    public func searchNearby(category: NearbyCategory,
                             center: CLLocationCoordinate2D,
                             page: Int,
                             pageSize: Int = 20) async -> (places: [Place], failure: NavFailure?, hasMore: Bool) {
        // 半径按页扩大（D04 待确认：初始 3km、档位 6/10/20km）
        let radiusByPage: [Double] = [3000, 6000, 10000, 20000]
        let radius = radiusByPage[min(page, radiusByPage.count - 1)]

        var collected: [Place] = []
        var failure: NavFailure?
        for term in category.queryTerms {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = term
            request.resultTypes = [.pointOfInterest]
            if !category.poiCategories.isEmpty {
                request.pointOfInterestFilter = MKPointOfInterestFilter(including: category.poiCategories)
            }
            request.region = MKCoordinateRegion(center: center,
                                                latitudinalMeters: radius * 2,
                                                longitudinalMeters: radius * 2)
            let search = MKLocalSearch(request: request)
            do {
                let response = try await search.start()
                collected += response.mapItems
                    .filter { Geo.distance(center, $0.placemark.coordinate) <= radius }
                    .map { Self.place(from: $0, source: .mapSearch, category: category.title) }
            } catch {
                failure = Self.classify(error)
            }
        }

        var unique = Self.dedupe(collected)
        unique.sort { a, b in
            let da = Geo.distance(center, a.gcj02Coordinate)
            let db = Geo.distance(center, b.gcj02Coordinate)
            if abs(da - db) < 1 { return a.name < b.name }
            return da < db
        }
        // 分页切片：页 0 返回前 20，后续页在更大半径集合上继续切片，保证跨页顺序连续
        let start = page * pageSize
        let end = min(unique.count, start + pageSize)
        guard start < end else {
            return ([], failure, false)
        }
        return (Array(unique[start..<end]), failure, end < unique.count)
    }

    // MARK: - 辅助

    private func region(for scope: SearchScope, center: CLLocationCoordinate2D?) -> MKCoordinateRegion? {
        switch scope {
        case .device:
            if let center {
                return MKCoordinateRegion(center: center, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
            }
            return nil
        case .city:
            // 明确城市：由调用方把该城市中心解析后作为 center 传入（不默认北京）
            if let center {
                return MKCoordinateRegion(center: center, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
            }
            return nil
        case .manual:
            if let center {
                return MKCoordinateRegion(center: center, latitudinalMeters: 120_000, longitudinalMeters: 120_000)
            }
            return nil
        }
    }

    public static func dedupe(_ places: [Place]) -> [Place] {
        var seen = Set<String>()
        var result: [Place] = []
        for place in places {
            let key = place.id
            if seen.contains(key) { continue }
            // 坐标几乎重合且同名视为同一对象；不同站台/出口坐标不同，不会被误并
            if result.contains(where: { $0.name == place.name && $0.distance(to: place) < 5 }) { continue }
            seen.insert(key)
            result.append(place)
        }
        return result
    }

    public static func classify(_ error: Error) -> NavFailure {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .offline
            case .timedOut, .cannotConnectToHost, .cannotFindHost:
                return .serviceError
            default:
                return .serviceError
            }
        }
        let nsError = error as NSError
        if nsError.domain == MKErrorDomain, nsError.code == MKError.placemarkNotFound.rawValue {
            return .noRoute
        }
        return .serviceError
    }

    public static func place(from item: MKMapItem,
                             source: PlaceSource,
                             category: String = "") -> Place {
        let mark = item.placemark
        let name = item.name ?? mark.name ?? ""
        let rawAddress = mark.title ?? [mark.thoroughfare, mark.subThoroughfare]
            .compactMap { $0 }.joined()
        let city = mark.locality ?? ""
        let district = mark.subLocality ?? ""
        let address = cleanAddress(rawAddress, city: city, district: district)
        let label = category.isEmpty ? categoryLabel(item.pointOfInterestCategory) : category
        return Place(id: "\(mark.coordinate.latitude),\(mark.coordinate.longitude)|\(name)",
                     name: name,
                     address: address,
                     city: city,
                     district: district,
                     category: label,
                     latitude: mark.coordinate.latitude,
                     longitude: mark.coordinate.longitude,
                     coordinateSystem: .gcj02,
                     source: source)
    }

    /// 地址去掉「中国 + 省 + 市 + 区」前缀，保留可辨认的街道门牌（NAV-09）
    static func cleanAddress(_ raw: String, city: String, district: String) -> String {
        var text = raw
        for prefix in ["中华人民共和国", "中国"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        for part in [city, district] where !part.isEmpty {
            if text.hasPrefix(part) { text.removeFirst(part.count) }
        }
        // 处理「广东省广州市越秀区」这类未按字段返回的整串前缀
        if let range = text.range(of: "省") {
            let head = String(text[text.startIndex...range.upperBound])
            if head.count <= 8 { text.removeFirst(head.count) }
        }
        if let range = text.range(of: "市") {
            let head = String(text[text.startIndex...range.upperBound])
            if head.count <= 8 { text.removeFirst(head.count) }
        }
        if let range = text.range(of: "区") {
            let head = String(text[text.startIndex...range.upperBound])
            if head.count <= 8 { text.removeFirst(head.count) }
        }
        return text.isEmpty ? raw : text
    }

    /// 真实 POI 类别 → 中文标签（不显示 MKPOICategory 原始枚举名）
    static func categoryLabel(_ category: MKPointOfInterestCategory?) -> String {
        guard let category else { return "" }
        switch category {
        case .evCharger: return "充电桩"
        case .hospital: return "医院"
        case .fitnessCenter: return "健身房"
        case .park: return "公园"
        case .restaurant: return "餐饮"
        case .cafe: return "咖啡"
        case .gasStation: return "加油站"
        case .parking: return "停车场"
        case .pharmacy: return "药店"
        case .school: return "学校"
        case .university: return "大学"
        case .store: return "商店"
        case .hotel: return "酒店"
        case .bank: return "银行"
        case .atm: return "ATM"
        case .publicTransport: return "交通"
        default: return ""
        }
    }
}

private final class CompleterDelegate: NSObject, MKLocalSearchCompleterDelegate {
    var onUpdate: (([MKLocalSearchCompletion]) -> Void)?
    private var fired = false

    func fire(_ results: [MKLocalSearchCompletion]) {
        guard !fired else { return }
        fired = true
        onUpdate?(results)
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        fire(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        fire([])
    }
}
