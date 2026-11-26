import CoreKit
import Foundation

/// 本机存储：搜索历史、常用地点、海拔记录、停车便签、天气地区
/// 统一 JSON 落 UserDefaults，失败不假报成功（R-030/R-033/R-038）
@MainActor
public final class NavStores: ObservableObject {
    /// 存储层所有被 UI 读取的可变状态统一 @Published：
    /// 曾因 parking 为普通 var——「在首页显示」开关成功持久化后不发信号，
    /// 首页停车卡要切 tab 重建才出现（海拔记录亦曾有同类「记 1 显示 0」问题）。
    @Published public private(set) var altitudeRecords: [AltitudeRecord] = []
    public static let shared = NavStores()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - 搜索历史（NAV-10 / D05：建议最近 20 项，仅本机）

    public struct HistoryEntry: Codable, Identifiable, Equatable {
        public var id: String { place.id }
        public var place: Place
        public var usedAt: Date
    }

    @Published public private(set) var history: [HistoryEntry] = []
    private let historyKey = "nav.history.v1"
    private let historyLimit = 20

    /// 仅成功取得有效结果的提交才写历史
    public func addHistory(_ place: Place) {
        guard place.hasValidCoordinate else { return }
        var items = history.filter { !$0.place.isSamePlace(as: place) }
        items.insert(HistoryEntry(place: place, usedAt: Date()), at: 0)
        history = Array(items.prefix(historyLimit))
        persist(history, key: historyKey)
    }

    public func removeHistory(_ place: Place) {
        history.removeAll { $0.place.isSamePlace(as: place) }
        persist(history, key: historyKey)
    }

    public func clearHistory() {
        history = []
        persist(history, key: historyKey)
    }

    // MARK: - 常用地点（R-033/034 + 规则 v0.31.1 §3：名称≤30、地址≤120；
    // R-072 取消「家/公司/其他」类别——旧记录的 category 字段读取时忽略，仅兼容解码）

    public struct SavedPlace: Codable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var address: String
        /// 已废弃（R-072）：仅为旧数据解码兼容保留，UI 不再展示/编辑
        public var category: String?
        public var place: Place?
        public var createdAt: Date

        public init(id: String, name: String, address: String,
                    category: String? = nil, place: Place? = nil, createdAt: Date) {
            self.id = id
            self.name = name
            self.address = address
            self.category = category
            self.place = place
            self.createdAt = createdAt
        }
    }

    @Published public private(set) var savedPlaces: [SavedPlace] = []
    private let savedKey = "nav.savedPlaces.v1"

    public enum SavePlaceResult: Equatable {
        case success
        case invalid          // 必填/长度不合格
        case duplicate        // 完全重复组合（归一后名称+地址均相同）
    }

    /// 归一比较键：全半角归一 + 首尾空白去除 + 连续空格折叠（AddressExtractor.normalize）
    static func placeIdentityKey(name: String, address: String) -> String {
        "\(AddressExtractor.normalize(name))|\(AddressExtractor.normalize(address))"
    }

    public func upsertSaved(_ item: SavedPlace) -> Bool {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty,
              item.name.count <= 30, item.address.count <= 120 else { return false }
        if let index = savedPlaces.firstIndex(where: { $0.id == item.id }) {
            savedPlaces[index] = item
        } else {
            savedPlaces.append(item)
        }
        return persist(savedPlaces, key: savedKey)
    }

    /// 【U-028/029】完全重复组合拦截：同名异址、异名同址可分别保存；
    /// 名称+地址归一后均相同 → duplicate（新增不建重复项；编辑成另一条的相同组合不覆盖）
    public func upsertSavedChecked(_ item: SavedPlace) -> SavePlaceResult {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !item.address.trimmingCharacters(in: .whitespaces).isEmpty,
              item.name.count <= 30, item.address.count <= 120 else { return .invalid }
        let key = Self.placeIdentityKey(name: item.name, address: item.address)
        if let other = savedPlaces.first(where: { $0.id != item.id && Self.placeIdentityKey(name: $0.name, address: $0.address) == key }) {
            return .duplicate
        }
        return upsertSaved(item) ? .success : .invalid
    }

    public func deleteSaved(id: String) -> Bool {
        savedPlaces.removeAll { $0.id == id }
        return persist(savedPlaces, key: savedKey)
    }

    // MARK: - 海拔记录（R-030/031：最多 20 条，快照不回写）

    public struct AltitudeRecord: Codable, Identifiable, Equatable {
        public var id: String
        public var altitude: Double
        public var latitude: Double
        public var longitude: Double
        public var note: String
        public var createdAt: Date
    }

    private let altitudeKey = "nav.altitude.v1"

    public func addAltitudeRecord(_ record: AltitudeRecord) -> Bool {
        var items = altitudeRecords
        items.insert(record, at: 0)
        altitudeRecords = Array(items.prefix(20))
        return persist(altitudeRecords, key: altitudeKey)
    }

    public func deleteAltitudeRecord(id: String) {
        altitudeRecords.removeAll { $0.id == id }
        _ = persist(altitudeRecords, key: altitudeKey)
    }

    // MARK: - 停车便签（R-037/038 + R-073：本机仅一条，照片不上传，首页展示可手动控制）

    public struct ParkingNote: Codable, Equatable {
        public var note: String
        public var imageData: Data?
        public var createdAt: Date?
        /// 【R-073】「在首页显示」开关：新建默认开、编辑继承旧值、删除后新建重置。
        /// 旧记录缺字段（v0.31 及以前）→ 解码为 true 迁移（T-259：备注/照片保持，首页默认显示）。
        public var homeVisible: Bool

        enum CodingKeys: String, CodingKey {
            case note, imageData, createdAt, homeVisible
        }

        /// 【U-023】旧版纯文字记录迁移：无法核实的旧时间显示「时间未记录」。
        /// 旧格式缺 createdAt 时解码为 nil（decodeIfPresent），不伪造停车时间。
        public init(note: String, imageData: Data?, createdAt: Date?, homeVisible: Bool = true) {
            self.note = note
            self.imageData = imageData
            self.createdAt = createdAt
            self.homeVisible = homeVisible
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            note = try c.decode(String.self, forKey: .note)
            imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
            // 【R-073/T-259】旧记录缺 homeVisible → 迁移为开启
            homeVisible = try c.decodeIfPresent(Bool.self, forKey: .homeVisible) ?? true
        }
    }

    @Published public private(set) var parking: ParkingNote?
    private let parkingKey = "nav.parking.v1"

    @discardableResult
    public func saveParking(_ note: ParkingNote) -> Bool {
        guard !note.note.trimmingCharacters(in: .whitespaces).isEmpty || note.imageData != nil else {
            return false
        }
        parking = note
        return persist(note, key: parkingKey)
    }

    /// 【R-073-03】切换「在首页显示」：仅改展示字段，不动备注/照片/时间。
    /// 返回持久化结果（失败时调用方回退 UI 开关——T-254）。
    @discardableResult
    public func setParkingHomeVisible(_ visible: Bool) -> Bool {
        guard var note = parking else { return false }
        note.homeVisible = visible
        guard persist(note, key: parkingKey) else { return false }
        parking = note
        return true
    }

    /// 【R-073-05】删除便签：不再前置「已找到车」，任何状态可删（含照片一并清除）。
    public func deleteParking() -> Bool {
        parking = nil
        defaults.removeObject(forKey: parkingKey)
        return defaults.data(forKey: parkingKey) == nil
    }

    /// 兼容旧调用名（U-022 文案已按 R-073-05 改为「删除便签」，语义同 deleteParking）
    public func clearParking() -> Bool { deleteParking() }

    // MARK: - 天气地区（独立状态，不影响导航位置，R-021 / NAV-38）

    @Published public private(set) var weatherRegion: WeatherRegion?
    private let weatherKey = "nav.weatherRegion.v1"

    public func setWeatherRegion(_ region: WeatherRegion) {
        weatherRegion = region
        persist(region, key: weatherKey)
    }

    // MARK: - 完成页已处理标记（NAV-36：冷启不反复弹）

    public var lastHandledArrivalId: String? {
        get { defaults.string(forKey: "nav.arrival.handled") }
        set { defaults.set(newValue, forKey: "nav.arrival.handled") }
    }

    // MARK: - 加载与持久化

    public init() {
        self.defaults = .standard
        history = load([HistoryEntry].self, key: historyKey) ?? []
        savedPlaces = load([SavedPlace].self, key: savedKey) ?? []
        altitudeRecords = load([AltitudeRecord].self, key: altitudeKey) ?? []
        parking = load(ParkingNote.self, key: parkingKey)
        weatherRegion = load(WeatherRegion.self, key: weatherKey)
    }

    /// 测试注入：隔离的 UserDefaults suite（R-073 数据层用例）
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        history = load([HistoryEntry].self, key: historyKey) ?? []
        savedPlaces = load([SavedPlace].self, key: savedKey) ?? []
        altitudeRecords = load([AltitudeRecord].self, key: altitudeKey) ?? []
        parking = load(ParkingNote.self, key: parkingKey)
        weatherRegion = load(WeatherRegion.self, key: weatherKey)
    }

    @discardableResult
    private func persist<T: Encodable>(_ value: T, key: String) -> Bool {
        do {
            let data = try encoder.encode(value)
            defaults.set(data, forKey: key)
            return true
        } catch {
            Log.warn("[NavStores] 保存失败 \(key): \(error.localizedDescription)")
            return false
        }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

/// 天气地区（独立于导航位置）
public struct WeatherRegion: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var district: String
    public var province: String
    public var latitude: Double
    public var longitude: Double

    public init(id: String, name: String, district: String, province: String,
                latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.district = district
        self.province = province
        self.latitude = latitude
        self.longitude = longitude
    }

    public var display: String {
        guard !district.isEmpty, district != name else { return name }
        return "\(name) \(district)"
    }
}
