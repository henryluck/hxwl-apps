import Capabilities
import CoreLocation
import CoreKit
import Foundation
import MapKit
import SwiftUI

/// 一级 Tab（四 Tab：导航 / 罗盘 / 海拔 / 天气；「我的」不占 Tab）
public enum NavTab: String, CaseIterable, Identifiable {
    case navigate, compass, altitude, weather

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .navigate: return "导航"
        case .compass: return "罗盘"
        case .altitude: return "海拔"
        case .weather: return "天气"
        }
    }

    public var icon: String {
        switch self {
        case .navigate: return "location.north.line.fill"
        case .compass: return "safari.fill"
        case .altitude: return "mountain.2.fill"
        case .weather: return "cloud.sun.fill"
        }
    }
}

/// 全屏子流程（子流程不显示 Tab，NAV-01）
public enum NavFlow: Equatable {
    case home
    case search
    case nearby
    case plan
    case navigating
    case arrived
}

public enum SearchTarget: Equatable {
    case origin
    case destination
}

public enum PlanSource: Equatable {
    case normal          // 普通检索进入
    case nearby          // 周边列表进入
}

/// 周边列表返回上下文（NAV-14：返回恢复提交词/类别/加载数量/滚动）
public struct NearbyContext: Equatable {
    public var category: NearbyCategory
    public var query: String
    public var loadedCount: Int
}

/// 导航 App 状态中枢：单一会话状态，UI 不各存布尔（NAV-37）
@MainActor
public final class NavAppModel: ObservableObject {
    // 能力
    public let pay: any PayService
    public let theme: any ThemeService
    public let location = LocationService()
    public let voice: VoiceService
    public let engine: NavEngine
    public let search = SearchService()
    public let weather = WeatherService()
    public let stores = NavStores.shared
    public let mapController = NavMapController()
    private let router = RouteService()

    // 一级导航
    @Published public var tab: NavTab = .navigate
    @Published public var flow: NavFlow = .home
    @Published public var showProfile = false

    // 地图
    @Published public var satellite = true
    @Published public var locating = false

    // 搜索
    @Published public var searchTarget: SearchTarget = .destination
    @Published public var searchText = ""
    @Published public var searchResults: [Place] = []
    @Published public var searchFailure: NavFailure?
    @Published public var isSearching = false
    @Published public var hasSubmitted = false
    @Published public var searchScope: SearchScope = .device
    @Published public var suggestions: [Suggestion] = []
    @Published public var isSuggesting = false

    // 规划
    @Published public var origin: Place?
    @Published public var destination: Place?
    @Published public var mode: TravelMode = .driving
    @Published public var planSource: PlanSource = .normal
    @Published public var nearbyCategory: NearbyCategory?

    // 周边
    @Published public var nearbyQuery = ""
    @Published public var nearbyPlaces: [Place] = []
    @Published public var nearbyPage = 0
    @Published public var nearbyHasMore = true
    @Published public var nearbyLoading = false
    @Published public var nearbyFailure: NavFailure?
    @Published public var nearbyContext: NearbyContext?

    // 完成页
    @Published public var arrivalSummary: ArrivalSummary?

    public struct ArrivalSummary: Equatable {
        public var destination: Place
        public var mode: TravelMode
        public var distance: Double
        public var duration: TimeInterval
        public var sessionId: String
    }

    public init(pay: any PayService, theme: any ThemeService) {
        self.pay = pay
        self.theme = theme
        let voice = VoiceService()
        self.voice = voice
        self.engine = NavEngine(location: location, voice: voice)
    }

    // MARK: - 会员

    public var isUnlocked: Bool {
        #if DEBUG
        // 联调开关：SIMCTL_CHILD_NAV_DEBUG_UNLOCK=1 时视作已解锁，便于截图验证
        if ProcessInfo.processInfo.environment["NAV_DEBUG_UNLOCK"] == "1" { return true }
        #endif
        return pay.isPro
    }

    /// 需要会员的动作统一走这里：未解锁时请求宿主弹订阅页（不自行改价/不假开通）
    @discardableResult
    public func requireMembership() -> Bool {
        if isUnlocked { return true }
        NotificationCenter.default.post(name: .presentPaywall, object: nil)
        return false
    }

    // MARK: - 定位

    public var devicePlace: Place? {
        location.snapshot?.place
    }

    public var locationChip: (text: String, ok: Bool) {
        if locating { return ("定位中…", false) }
        switch location.authState {
        case .authorized:
            if let snap = location.snapshot {
                return snap.isWeak ? ("定位信号较弱", false) : ("已定位", true)
            }
            return ("未定位", false)
        case .approximate:
            return ("近似位置", false)
        case .denied, .restricted:
            return ("未授权定位", false)
        case .servicesOff:
            return ("系统定位关闭", false)
        case .notDetermined:
            return ("点击定位", false)
        }
    }

    public func locate() async {
        locating = true
        defer { locating = false }
        if location.authState == .notDetermined {
            location.requestAuthorization()
        }
        if let fix = await location.requestSingleFix() {
            // 首页定位：落到设备附近（近距跟随只在活动导航里用）
            mapController.fit(MKCoordinateRegion(center: fix.place.gcj02Coordinate,
                                                 latitudinalMeters: 2500,
                                                 longitudinalMeters: 2500))
        }
    }

    // MARK: - 搜索

    public func openSearch(target: SearchTarget, preset: String = "") {
        searchTarget = target
        searchText = preset
        searchResults = []
        searchFailure = nil
        hasSubmitted = false
        isSearching = false
        flow = .search
        refreshScope()
    }

    private func refreshScope() {
        // 默认使用有效设备位置所属城市；无定位时按用户明确范围（NAV-06）
        searchScope = location.authState.isUsable ? .device : .manual
    }

    /// 输入联想：中文输入法组词期间不把中间字母当最终关键词（由 TextField 的 markedText 处理）
    public func updateSuggestions(_ text: String) {
        suggestions = []
        isSuggesting = !text.trimmingCharacters(in: .whitespaces).isEmpty
        let region: MKCoordinateRegion? = location.snapshot.map {
            MKCoordinateRegion(center: $0.place.gcj02Coordinate,
                               latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        search.updateSuggestions(query: text, region: region) { [weak self] items in
            guard let self else { return }
            self.suggestions = items
            self.isSuggesting = false
        }
    }

    public func clearSearchDraft() {
        searchText = ""
        suggestions = []
        searchResults = []
        searchFailure = nil
        hasSubmitted = false
        isSearching = false
        search.clearSuggestions()
    }

    /// 提交正式检索：联想 0 条也允许提交（NAV-07）
    public func submitSearch(_ raw: String? = nil) async {
        let query = (raw ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard requireMembership() else { return }
        searchText = query
        hasSubmitted = true
        isSearching = true
        searchFailure = nil
        searchResults = []
        search.clearSuggestions()

        let outcome = await search.search(query: query,
                                          scope: searchScope,
                                          center: centerCoordinate())
        isSearching = false
        if let failure = outcome.failure {
            searchFailure = failure
        } else {
            searchResults = outcome.results
        }
    }

    private func centerCoordinate() -> CLLocationCoordinate2D? {
        if let snap = location.snapshot { return snap.place.gcj02Coordinate }
        if let place = destination { return place.gcj02Coordinate }
        return nil
    }

    public func selectSuggestion(_ suggestion: Suggestion) async {
        guard requireMembership() else { return }
        isSearching = true
        let place = await search.resolve(suggestion, scope: searchScope)
        isSearching = false
        if let place {
            confirm(place)
        } else {
            // 候选解析不到坐标：退回正式检索，不虚构地点（NAV-09）
            searchText = suggestion.title
            await submitSearch(suggestion.title)
        }
    }

    /// 选中地点：写入完整对象并进入规划（NAV-11：原子替换，不残留旧坐标）
    public func confirm(_ place: Place) {
        guard place.hasValidCoordinate else { return }
        stores.addHistory(place)
        switch searchTarget {
        case .destination:
            destination = place
        case .origin:
            origin = place
        }
        searchText = place.name
        openPlan()
    }

    public func setOriginToDevice() {
        origin = nil
    }

    public var originDisplay: Place? {
        origin ?? devicePlace
    }

    // MARK: - 规划

    public func openPlan() {
        flow = .plan
        Task { await plan() }
    }

    public func plan() async {
        guard let destination else { return }
        // 起点优先用户手选；否则用当前有效位置（无缓存时取一次真实定位，不拿 0,0 算路）
        var originPlace = originDisplay
        if originPlace == nil, let fix = await location.requestSingleFix() {
            originPlace = fix.place
        }
        guard let originPlace, originPlace.hasValidCoordinate else {
            engine.fail(location.authState.isUsable ? .locationUnavailable : .locationDenied)
            return
        }
        await engine.plan(origin: originPlace, destination: destination, mode: mode)
        if let route = engine.selectedRoute {
            mapController.showRoute(route.polyline, origin: originPlace, destination: destination)
            mapController.fitRoute()
        }
    }

    public func changeMode(_ newMode: TravelMode) async {
        guard newMode != mode else { return }
        mode = newMode
        // 切方式清旧可启动 routeId（NAV-17）
        mapController.clearRoute()
        await plan()
    }

    public func selectRoute(_ id: String) {
        engine.selectRoute(id)
        guard let route = engine.selectedRoute, let destination else { return }
        mapController.showRoute(route.polyline, origin: originDisplay, destination: destination)
    }

    // MARK: - 开始 / 退出 / 到达

    public func startNavigation() async -> NavFailure? {
        guard requireMembership() else { return .authRequired }
        guard let destination else { return .invalidPlace }
        guard engine.selectedRoute != nil else { return .noRoute }
        do {
            try await engine.start(origin: originDisplay ?? Place(id: "device", name: "我的位置",
                                                                  address: "",
                                                                  latitude: 0, longitude: 0),
                                   destination: destination)
            flow = .navigating
            if let route = engine.selectedRoute {
                mapController.showRoute(route.polyline, origin: originDisplay, destination: destination)
            }
            if let snap = location.snapshot {
                mapController.follow(snap.place.gcj02Coordinate, heading: snap.course >= 0 ? snap.course : nil)
            }
            return nil
        } catch NavEngine.StartFailure.location(let failure) {
            return failure
        } catch {
            return .engineStartFailed
        }
    }

    /// 主动退出 → 回路线规划，保留目标与方式（NAV-34）
    public func exitNavigation() {
        engine.exit()
        flow = .plan
        if let route = engine.selectedRoute {
            mapController.showRoute(route.polyline, origin: originDisplay, destination: destination)
            mapController.fitRoute()
        }
    }

    public func handleArrival() {
        guard let session = engine.session, session.terminalReason == .arrived else { return }
        arrivalSummary = ArrivalSummary(destination: session.destination,
                                        mode: session.mode,
                                        distance: engine.traveledDistance,
                                        duration: Date().timeIntervalSince(session.startedAt),
                                        sessionId: session.id)
        stores.lastHandledArrivalId = session.id
        flow = .arrived
    }

    public func finishArrival() {
        engine.returnToPlanning()
        flow = .home
        destination = nil
        origin = nil
        arrivalSummary = nil
        engine.resetForColdStart()
    }

    /// 完成页「再去此处」
    public func planAgain() {
        guard let summary = arrivalSummary else { return }
        destination = summary.destination
        origin = nil
        arrivalSummary = nil
        openPlan()
    }

    // MARK: - 周边

    public func openNearby(_ category: NearbyCategory) {
        nearbyCategory = category
        nearbyQuery = ""
        nearbyPlaces = []
        nearbyPage = 0
        nearbyHasMore = true
        nearbyFailure = nil
        nearbyContext = NearbyContext(category: category, query: "", loadedCount: 0)
        flow = .nearby
        Task { await loadNearbyPage(reset: true) }
    }

    public func loadNearbyPage(reset: Bool = false) async {
        guard let category = nearbyCategory, !nearbyLoading else { return }
        guard requireMembership() else { return }
        // 无缓存位置时先取一次真实定位，取不到才进失败态（不默认全国/北京）
        var center = location.snapshot?.place.gcj02Coordinate ?? destination?.gcj02Coordinate
        if center == nil {
            center = await location.requestSingleFix()?.place.gcj02Coordinate
        }
        guard let center else {
            nearbyFailure = location.authState.isUsable ? .locationUnavailable : .locationDenied
            return
        }
        nearbyLoading = true
        if reset { nearbyPage = 0; nearbyPlaces = [] }
        let result = await search.searchNearby(category: category, center: center, page: nearbyPage)
        nearbyLoading = false
        if let failure = result.failure, result.places.isEmpty {
            nearbyFailure = failure
            return
        }
        nearbyFailure = nil
        if reset {
            nearbyPlaces = result.places
        } else {
            // 稳定 ID 去重，跨页顺序连续（NAV-13）
            let existing = Set(nearbyPlaces.map(\.id))
            nearbyPlaces += result.places.filter { !existing.contains($0.id) }
        }
        nearbyHasMore = result.hasMore
        if !result.places.isEmpty { nearbyPage += 1 }
        nearbyContext = NearbyContext(category: category, query: nearbyQuery,
                                      loadedCount: nearbyPlaces.count)
    }

    /// 周边列表点一行：直接到带目标地址框的路线地图（NAV-12/15）
    public func openNearbyRoute(_ place: Place) {
        destination = place
        origin = nil
        planSource = .nearby
        openPlan()
    }

    public func backToNearbyList() {
        // 返回原类别列表：恢复提交词、类别、已加载数量（NAV-14）
        flow = .nearby
        if let context = nearbyContext {
            nearbyCategory = context.category
        }
    }

    #if DEBUG
    /// 本地联调落点：SIMCTL_CHILD_NAV_DEBUG_SCREEN=search|nearby|plan|compass|altitude|weather
    /// 仅 DEBUG 编译，正式包不包含该分支
    public func applyDebugLaunchScreenIfNeeded() {
        guard let screen = ProcessInfo.processInfo.environment["NAV_DEBUG_SCREEN"] else { return }
        switch screen {
        case "search":
            openSearch(target: .destination)
        case "nearby":
            openNearby(.charger)
        case "plan":
            destination = Place(id: "debug", name: "广州塔", address: "海珠区阅江西路222号",
                                city: "广州市", district: "海珠区",
                                latitude: 23.1066, longitude: 113.3245)
            openPlan()
        case "navigating":
            destination = Place(id: "debug", name: "广州塔", address: "海珠区阅江西路222号",
                                city: "广州市", district: "海珠区",
                                latitude: 23.1066, longitude: 113.3245)
            Task {
                await plan()
                _ = await startNavigation()
            }
        case "compass":
            tab = .compass
        case "altitude":
            tab = .altitude
        case "weather":
            tab = .weather
        default:
            break
        }
    }
    #endif
}
