import Capabilities
import Combine
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
    /// 【Bug 行32】返回首页时统一收口清理：地图规划线、起终点标注、起终点输入
    /// （此前 back() 只切 flow 不清理 → 地图残留路线、输入框保留旧值）
    @Published public var flow: NavFlow = .home {
        didSet {
            if oldValue != .home, flow == .home {
                clearPlanState()
            }
        }
    }
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
        // 【Bug：页面刷新失效】engine/location 等子服务是 ObservableObject，但视图只
        // ObservedObject model —— 子服务的 @Published 变化（engine.phase planning→failed、
        // location.snapshot 等）不会触发 model 的 objectWillChange，规划页永远显示
        // 「正在规划…」。把子服务的变更转发到 model 的 objectWillChange（AVL 树顺序无关）。
        // 【Bug 行39】stores 也纳入转发：海拔记录改 @Published 后由 objectWillChange
        // 驱动视图刷新，替代脆弱的手动刷新令牌
        for publisher in [engine.objectWillChange, location.objectWillChange, stores.objectWillChange] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &childCancellables)
        }
        // 【Bug 行31】授权变可用 → 自动定位一次（覆盖两个场景）：
        // ① 权限弹窗用户点「允许」后立即定位，无需再手动点；② 启动时已有权限、
        // 但首页 .task 在 splash/订阅墙期间已空跑（authState 尚未刷新）的情况——
        // 授权状态晚到时由这里补一次自动定位。每会话只补一次，不覆盖用户手动挪图。
        location.$authState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, state.isUsable, !self.autoLocatedAfterAuth else { return }
                self.autoLocatedAfterAuth = true
                Task { await self.locate() }
            }
            .store(in: &childCancellables)
        // 【Bug 行34】定位快照**首次获得**时 → 地图落位（若首页地图已挂载）。
        // 授权后自动定位可能发生在规划/周边等页面（地图未挂载时 fit 静默跳过），
        // snapshot 先落库；等首页地图出现时由这里补 fit，解决"授权完首页仍不落位"。
        // 只在 nil → 有值的一次性跳变触发：导航中连续定位会频繁更新 snapshot，
        // 不能每次都拉镜头（导航镜头由官方导航视图接管）。
        location.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                guard let self, let snap, self.didFitOnFirstFix else { return }
                self.didFitOnFirstFix = false
                self.mapController.fit(MKCoordinateRegion(
                    center: snap.place.gcj02Coordinate,
                    latitudinalMeters: 2500, longitudinalMeters: 2500))
            }
            .store(in: &childCancellables)
    }

    /// 【Bug 行34】首次定位落位标记：首个快照 fit 一次，之后的快照更新不再拉镜头
    private var didFitOnFirstFix = true

    /// 【Bug 行31】授权后自动定位只执行一次的标记
    private var autoLocatedAfterAuth = false

    private var childCancellables: Set<AnyCancellable> = []

    // MARK: - 会员

    public var isUnlocked: Bool {
        #if DEBUG
        // 联调开关：SIMCTL_CHILD_NAV_DEBUG_UNLOCK=1 时视作已解锁，便于截图验证。
        // UserDefaults(debug.navUnlock=1) 等效兜底——沙盒 shell 下 env 注入不稳定。
        if ProcessInfo.processInfo.environment["NAV_DEBUG_UNLOCK"] == "1" { return true }
        if UserDefaults.standard.bool(forKey: "debug.navUnlock") { return true }
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
        // 【Bug 行31】notDetermined 时等待用户对权限弹窗做出选择（此前只发非阻塞
        // requestAuthorization 就立刻去 requestSingleFix——权限未决恒 nil，
        // 用户点「允许」后也没了下文，表现为"授权完不自动定位"）。
        if location.authState == .notDetermined {
            let granted = await location.waitForAuthorization()
            guard granted else { return }
        }
        if let fix = await location.requestSingleFix() {
            // 首页定位：落到设备附近（近距跟随只在活动导航里用）
            mapController.fit(MKCoordinateRegion(center: fix.place.gcj02Coordinate,
                                                 latitudinalMeters: 2500,
                                                 longitudinalMeters: 2500))
        }
    }

    /// 失败页「重试定位」统一入口：真实重定位，成功后按当前流程自动续作
    /// （周边 → 重载列表；规划 → 重规划；导航 ready → 重启导航）。
    /// 返回nil 表示定位成功已续作；返回 failure 时由调用方展示。
    @discardableResult
    public func retryLocationAndReload() async -> NavFailure? {
        // 权限未决时先等授权结果（与 plan() 同一链路，弹窗期间不误判失败）
        if location.authState == .notDetermined {
            let granted = await location.waitForAuthorization()
            guard granted else { return .locationDenied }
        }
        guard let fix = await location.requestSingleFix(), fix.isUsable else {
            return location.authState.isUsable ? .locationUnavailable : .locationDenied
        }
        // 定位成功：地图落到新位置
        mapController.fit(MKCoordinateRegion(center: fix.place.gcj02Coordinate,
                                             latitudinalMeters: 2500,
                                             longitudinalMeters: 2500))
        // 按当前流程续作
        switch flow {
        case .nearby:
            nearbyFailure = nil
            await loadNearbyPage(reset: true)
        case .plan:
            if engine.phase == .ready {
                // 已有路线仅起点定位失败：直接重启导航
                if let failure = await startNavigation() { return failure }
            } else {
                await plan()
            }
        default:
            break
        }
        return nil
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
        // plan() 由 RoutePlanView.task 在页面挂载时触发（此处不再并发触发，
        // 避免同一目的地瞬间打出两个高德规划请求互相覆盖）
    }

    /// 【Bug 行32】返回首页的统一清理：地图线/标注、起终点输入、搜索词
    public func clearPlanState() {
        mapController.clearRoute()
        origin = nil
        destination = nil
        searchText = ""
        searchResults = []
        suggestions = []
    }

    /// 规划在途标记：并发调用 plan()（openPlan/页面 task/重试）时只放行第一个
    private var planInFlight = false
    /// 【Bug 行27】在途期间有新模式切换进来 → 置位，本轮结束后自动补一轮最新模式的规划
    private var planPendingRerun = false

    public func plan() async {
        guard let destination else { return }
        // 【Bug 行27】在途不重入，但**记录补跑请求**：切换出行方式时 UI 模式已变，
        // 若直接 return 用户会看到「模式换了、路线没换」。在途结束后补一轮最新模式。
        if planInFlight {
            planPendingRerun = true
            return
        }
        planInFlight = true
        defer { planInFlight = false }
        // 起点优先用户手选；否则用当前有效位置（无新鲜缓存时取一次真实定位，不拿 0,0 算路）
        var originPlace = origin
        // 【Bug 行15】规划时若定位权限仍未决定，先请求并等待授权结果（不再固定 sleep
        // 400ms——那是在和用户点击速度赛跑）。未授权时 requestSingleFix 恒 nil →
        // engine.fail(locationUnavailable)，用户看到「无法获取位置」且无法拉起导航。
        if location.authState == .notDetermined {
            let granted = await location.waitForAuthorization()
            guard granted else {
                engine.fail(.locationDenied)
                return
            }
        }
        if originPlace == nil {
            // 【Bug 行38·规划慢的根因】起点定位门槛过严导致双重超时黑洞：
            // ① 快照复用门槛 isUsable（≤100m 且 ≤20s）——30~60 秒前的可用快照被当过期
    //    丢弃重新定位，白等一轮；② 弱信号下第一炮精度 >100m 判无效 → 补炮再等
    //    10s → 两炮都"不可用"直接失败。而高德算路对起点只有坐标要求（道路级），
            // 精度 200m 内完全可用，事后还有偏航重规划兜底。
            // 修复：优先复用 60s 内、精度 ≤200m 的缓存快照（零等待）；新定位拿到坐标即用。
            if let snap = location.snapshot, snap.age <= 60, snap.horizontalAccuracy > 0,
               snap.horizontalAccuracy <= 200 {
                originPlace = snap.place
            } else {
                var got = await location.requestSingleFix(timeout: 6)
                if got == nil {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    got = await location.requestSingleFix(timeout: 8)
                }
                if let got {
                    // 有坐标即用：弱精度不再丢弃（规划起点道路级容忍 + 偏航重规划兜底）
                    originPlace = got.place
                }
            }
        }
        guard let originPlace, originPlace.hasValidCoordinate else {
            Log.warn("[Plan] 起点不可用 auth=\(location.authState)")
            engine.fail(location.authState.isUsable ? .locationUnavailable : .locationDenied)
            return
        }
        Log.info("[Plan] 开始算路 origin=\(originPlace.name) dest=\(destination.name) mode=\(mode)")
        // 【Bug 行16】起终点一致（名称相同且坐标几乎重合）不发起算路，直接给失败态提示。
        // MKDirections 对重合起终点会返回 directionsNotFound（笼统"无路线"），这里提前拦截
        // 并给出可理解的提示文案。
        if originPlace.hasValidCoordinate, destination.hasValidCoordinate,
           originPlace.name == destination.name,
           Geo.distance(originPlace.gcj02Coordinate, destination.gcj02Coordinate) < 5 {
            engine.fail(.sameOriginDestination)
            return
        }
        await engine.plan(origin: originPlace, destination: destination, mode: mode)
        if let route = engine.selectedRoute {
            mapController.showRoute(route.polyline, origin: originPlace, destination: destination)
            mapController.fitRoute()
        }
        // 【Bug 行27】在途期间有模式切换请求 → 用最新模式补跑一轮
        if planPendingRerun {
            planPendingRerun = false
            await plan()
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
            // 官方导航视图接管地图；无需手动画线/跟随
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
        // 【Bug 行36】立即回到规划态：此前停在 .ended，开始导航按钮要等下一次
        // plan() 才恢复可点（表现为"停止导航后按钮灰很久"）
        engine.returnToPlanning()
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
            // 【钓点空列表】周边搜索的「附近没有」也常伴随 serviceError（Apple 地图
            // 对无结果请求抛错）；这类应展示空态（可换类别）而非失败页。
            // 只有硬错误（断网/未授权定位）才进失败分流。
            switch failure {
            case .offline, .locationUnavailable, .locationDenied,
                 .locationServicesOff, .authRequired:
                nearbyFailure = failure
                return
            default:
                break
            }
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
    /// nearby 可配 NAV_DEBUG_NEARBY_CATEGORY=<charger|fishingSpot|tackleShop|hospital|gym|park>
    /// 指定分类（默认 charger；验证分类条自动滚动用超出屏幕的 gym/park）
    /// UserDefaults(debug.navScreen=xxx) 为等效兜底（env 注入不稳定的自动化场景）
    /// 仅 DEBUG 编译，正式包不包含该分支
    public func applyDebugLaunchScreenIfNeeded() {
        let screen = ProcessInfo.processInfo.environment["NAV_DEBUG_SCREEN"]
            ?? UserDefaults.standard.string(forKey: "debug.navScreen")
        guard let screen else { return }
        switch screen {
        case "search":
            openSearch(target: .destination)
        case "nearby":
            let category = ProcessInfo.processInfo.environment["NAV_DEBUG_NEARBY_CATEGORY"]
                .flatMap(NearbyCategory.init(rawValue:)) ?? .charger
            openNearby(category)
        case "plan":
            destination = Place(id: "debug", name: "广州塔", address: "海珠区阅江西路222号",
                                city: "广州市", district: "海珠区",
                                latitude: 23.1066, longitude: 113.3245)
            openPlan()
        case "plan-walk":
            destination = Place(id: "debug", name: "广州塔", address: "海珠区阅江西路222号",
                                city: "广州市", district: "海珠区",
                                latitude: 23.1066, longitude: 113.3245)
            mode = .walking
            openPlan()
        case "plan-ride":
            destination = Place(id: "debug", name: "广州塔", address: "海珠区阅江西路222号",
                                city: "广州市", district: "海珠区",
                                latitude: 23.1066, longitude: 113.3245)
            mode = .cycling
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
        case "profile":
            showProfile = true
        default:
            break
        }
    }
    #endif
}
