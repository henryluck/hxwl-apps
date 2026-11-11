import CoreKit
import Foundation

/// 本机存储：搜索历史、常用地点、海拔记录、停车便签、天气地区
/// 统一 JSON 落 UserDefaults，失败不假报成功（R-030/R-033/R-038）
@MainActor
public final class NavStores {
    public static let shared = NavStores()

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - 搜索历史（NAV-10 / D05：建议最近 20 项，仅本机）

    public struct HistoryEntry: Codable, Identifiable, Equatable {
        public var id: String { place.id }
        public var place: Place
        public var usedAt: Date
    }

    public private(set) var history: [HistoryEntry] = []
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

    // MARK: - 常用地点（R-033/034：名称≤30、地址≤120）

    public struct SavedPlace: Codable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var address: String
        public var category: String     // 家 / 公司 / 其他
        public var place: Place?
        public var createdAt: Date
    }

    public private(set) var savedPlaces: [SavedPlace] = []
    private let savedKey = "nav.savedPlaces.v1"

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

    public func deleteSaved(id: String) {
        savedPlaces.removeAll { $0.id == id }
        _ = persist(savedPlaces, key: savedKey)
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

    public private(set) var altitudeRecords: [AltitudeRecord] = []
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

    // MARK: - 停车便签（R-037/038：本机仅一条，照片不上传）

    public struct ParkingNote: Codable, Equatable {
        public var note: String
        public var imageData: Data?
        public var createdAt: Date
    }

    public private(set) var parking: ParkingNote?
    private let parkingKey = "nav.parking.v1"

    public func saveParking(_ note: ParkingNote) -> Bool {
        guard !note.note.trimmingCharacters(in: .whitespaces).isEmpty || note.imageData != nil else {
            return false
        }
        parking = note
        return persist(note, key: parkingKey)
    }

    public func clearParking() {
        parking = nil
        defaults.removeObject(forKey: parkingKey)
    }

    // MARK: - 天气地区（独立状态，不影响导航位置，R-021 / NAV-38）

    public private(set) var weatherRegion: WeatherRegion?
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
        district.isEmpty ? name : "\(name) \(district)"
    }
}
