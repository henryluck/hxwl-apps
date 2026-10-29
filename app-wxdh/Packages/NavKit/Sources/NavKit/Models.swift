import CoreLocation
import Foundation

// MARK: - 坐标系（NAV-38：每个地点带坐标系与来源，传 SDK 前一次转换）

public enum CoordinateSystem: String, Codable, Sendable {
    case wgs84      // 设备 GPS / CoreLocation 原始
    case gcj02      // 国测局（高德/苹果中国地图展示与算路）

    public var label: String { self == .wgs84 ? "WGS-84" : "GCJ-02" }
}

/// 地点来源：用于「历史/常用地点/工具带入」的追溯与重新核验（NAV-10/15/38）
public enum PlaceSource: String, Codable, Sendable {
    case mapSearch      // 真实检索结果
    case suggestion     // 输入联想候选
    case history        // 搜索历史
    case savedPlace     // 常用地点
    case textTool       // 地址整理
    case device         // 设备当前位置
    case manual         // 手动填写（未确认坐标）
}

/// 统一地点对象：文字/卡片/标点/算路/导航必须引用同一对象（NAV-09/38）
public struct Place: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var city: String
    public var district: String
    public var category: String
    public var latitude: Double
    public var longitude: Double
    public var coordinateSystem: CoordinateSystem
    public var source: PlaceSource
    /// 入口/出入口/站台方向等子对象（有真实数据才填）
    public var entry: String?

    public init(id: String, name: String, address: String,
                city: String = "", district: String = "", category: String = "",
                latitude: Double, longitude: Double,
                coordinateSystem: CoordinateSystem = .gcj02,
                source: PlaceSource = .mapSearch, entry: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.city = city
        self.district = district
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.coordinateSystem = coordinateSystem
        self.source = source
        self.entry = entry
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    /// 坐标是否有效（0/0、越界不当有效位置，NAV-38）
    public var hasValidCoordinate: Bool {
        guard latitude != 0 || longitude != 0 else { return false }
        return latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }

    /// 异地/同名可辨认：城市+区县
    public var regionLabel: String {
        [city, district].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var subtitle: String {
        if !address.isEmpty { return address }
        return regionLabel
    }

    public static func device(lat: Double, lon: Double, accuracy: Double) -> Place {
        Place(id: "device", name: "我的位置", address: "设备当前位置",
              latitude: lat, longitude: lon,
              coordinateSystem: .wgs84, source: .device)
    }

    public func distance(to other: Place) -> CLLocationDistance {
        location.distance(from: other.location)
    }

    /// 同一有效地点判定：ID 优先，其次坐标近似（同名异地不误判，NAV-11）
    public func isSamePlace(as other: Place) -> Bool {
        if id == other.id && !id.isEmpty { return true }
        return distance(to: other) < 8
    }
}

// MARK: - 出行方式（NAV-17）

public enum TravelMode: String, CaseIterable, Codable, Sendable {
    case driving, walking, cycling

    public var title: String {
        switch self {
        case .driving: return "驾车"
        case .walking: return "步行"
        case .cycling: return "骑行"
        }
    }

    public var icon: String {
        switch self {
        case .driving: return "car.fill"
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        }
    }

    /// 偏航判定阈值（米）：不同方式对路径贴合要求不同（D02 待产品确认，此处为引擎基线）
    public var offRouteThreshold: Double {
        switch self {
        case .driving: return 55
        case .walking: return 35
        case .cycling: return 45
        }
    }

    /// 语音播报距离档（米），由远及近，每档只播一次（NAV-28）
    public var announceDistances: [Double] {
        switch self {
        case .driving: return [800, 300, 100, 30]
        case .walking: return [200, 80, 20]
        case .cycling: return [400, 150, 40]
        }
    }

    /// 到达判定半径（米）
    public var arrivalRadius: Double {
        switch self {
        case .driving: return 40
        case .walking: return 25
        case .cycling: return 35
        }
    }
}

// MARK: - 路线与步骤

public struct NavStep: Identifiable, Sendable {
    public var id: String
    public var index: Int
    public var instruction: String
    /// 本步骤距离（米）
    public var distance: Double
    /// 本步骤结束（机动点）坐标
    public var coordinate: CLLocationCoordinate2D
    public var roadName: String
    public var isArrivalStep: Bool

    public init(id: String, index: Int, instruction: String, distance: Double,
                coordinate: CLLocationCoordinate2D, roadName: String,
                isArrivalStep: Bool = false) {
        self.id = id
        self.index = index
        self.instruction = instruction
        self.distance = distance
        self.coordinate = coordinate
        self.roadName = roadName
        self.isArrivalStep = isArrivalStep
    }
}

/// 一条真实算路结果（对应引擎 routeId，旧回调不得复活，NAV-37）
public struct RouteOption: Identifiable, Sendable {
    public var id: String
    public var mode: TravelMode
    public var distance: Double
    public var expectedTravelTime: Double
    public var steps: [NavStep]
    public var polyline: [CLLocationCoordinate2D]
    /// 引擎推荐的方案标签（不编「最快/最短」）
    public var engineLabel: String
    public var requestId: String

    public init(id: String, mode: TravelMode, distance: Double,
                expectedTravelTime: Double, steps: [NavStep],
                polyline: [CLLocationCoordinate2D], engineLabel: String,
                requestId: String) {
        self.id = id
        self.mode = mode
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.steps = steps
        self.polyline = polyline
        self.engineLabel = engineLabel
        self.requestId = requestId
    }

    public var distanceText: String { NavFormat.distance(distance) }
    public var timeText: String { NavFormat.duration(expectedTravelTime) }
    public var arrivalText: String {
        NavFormat.clock(Date().addingTimeInterval(expectedTravelTime))
    }
}

// MARK: - 会话状态机（NAV-37：单一会话状态，不各存布尔）

public enum NavPhase: Equatable, Sendable {
    case idle
    case planning
    case ready
    case starting
    case active
    case rerouting
    case arrived
    case ended
    case failed(NavFailure)

    public var isActiveSession: Bool {
        switch self {
        case .starting, .active, .rerouting: return true
        default: return false
        }
    }
}

/// 失败分流：无结果、能力不支持、权益不足、权限拒绝、网络失败不得共用文案（补充要求·失败分流表）
public enum NavFailure: Equatable, Sendable {
    case locationUnavailable
    case locationDenied
    case locationServicesOff
    case weakLocation
    case offline
    case serviceError
    case noRoute
    case outOfServiceArea
    case invalidPlace
    case authRequired
    case draftUnconfirmed
    case engineStartFailed
    case unknown

    public var title: String {
        switch self {
        case .locationUnavailable: return "暂时无法获取位置"
        case .locationDenied: return "请在设置中允许使用位置"
        case .locationServicesOff: return "请开启系统定位服务"
        case .weakLocation: return "定位信号较弱，正在重新获取"
        case .offline: return "网络暂不可用"
        case .serviceError: return "暂时无法获取路线"
        case .noRoute: return "暂未找到适合此方式的路线"
        case .outOfServiceArea: return "目的地超出当前服务范围"
        case .invalidPlace: return "地点信息不完整，请重新选择"
        case .authRequired: return "需要会员权益才能使用"
        case .draftUnconfirmed: return "请先选择新的目的地"
        case .engineStartFailed: return "导航启动失败，请重试"
        case .unknown: return "操作未完成，请重试"
        }
    }

    /// 可执行动作
    public var actions: [NavFailureAction] {
        switch self {
        case .locationUnavailable, .weakLocation: return [.retryLocation]
        case .locationDenied, .locationServicesOff: return [.openSettings]
        case .offline, .serviceError, .noRoute, .outOfServiceArea, .engineStartFailed, .unknown:
            return [.retry]
        case .invalidPlace, .draftUnconfirmed: return [.pickPlace]
        case .authRequired: return [.unlock]
        }
    }
}

public enum NavFailureAction: String, Sendable {
    case retry, retryLocation, openSettings, pickPlace, unlock

    public var title: String {
        switch self {
        case .retry: return "重试"
        case .retryLocation: return "重试定位"
        case .openSettings: return "去设置"
        case .pickPlace: return "重新选择"
        case .unlock: return "解锁会员"
        }
    }
}

// MARK: - 定位快照（NAV-38：时间/精度/来源）

public struct LocationSnapshot: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double
    public var timestamp: Date
    public var course: Double
    public var speed: Double
    /// 海拔与垂直精度（NAV-38：来源与精度如实展示，不承诺气压/氧气精度）
    public var altitude: Double
    public var verticalAccuracy: Double

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double,
                timestamp: Date, course: Double, speed: Double,
                altitude: Double = 0, verticalAccuracy: Double = -1) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.course = course
        self.speed = speed
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
    }

    public init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  horizontalAccuracy: location.horizontalAccuracy,
                  timestamp: location.timestamp,
                  course: location.course,
                  speed: location.speed,
                  altitude: location.altitude,
                  verticalAccuracy: location.verticalAccuracy)
    }

    public var age: TimeInterval { Date().timeIntervalSince(timestamp) }

    /// 有效定位判据（D02：定位年龄 15s、水平精度 50m 为引擎基线，产品待确认）
    public var isUsable: Bool {
        horizontalAccuracy > 0 && horizontalAccuracy <= 50 && age <= 15
    }

    public var isStale: Bool { age > 15 }

    public var isWeak: Bool { horizontalAccuracy > 50 }

    public var place: Place {
        Place.device(lat: latitude, lon: longitude, accuracy: horizontalAccuracy)
    }
}

// MARK: - 搜索任务（NAV-37：queryId 覆盖旧代次）

public enum SearchScope: Equatable, Sendable {
    case device          // 当前位置周边
    case city(String)    // 明确城市
    case manual          // 用户明确指定（异地）

    public var label: String {
        switch self {
        case .device: return "当前位置"
        case .city(let c): return c
        case .manual: return "指定范围"
        }
    }
}

public enum SearchKind: Equatable, Sendable {
    case keyword          // 普通关键词
    case category(String) // 纯类别（公交站/地铁站/六类周边）
}

// MARK: - 格式化

public enum NavFormat {
    public static func distance(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        if meters < 1000 { return "\(Int(meters.rounded()))米" }
        let km = meters / 1000
        if km < 10 { return String(format: "%.1f公里", km) }
        return "\(Int(km.rounded()))公里"
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(max(m, 1))分钟" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h)小时" : "\(h)小时\(mm)分"
    }

    public static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: date)
    }

    public static func coordinate(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.6f, %.6f", lat, lon)
    }
}
