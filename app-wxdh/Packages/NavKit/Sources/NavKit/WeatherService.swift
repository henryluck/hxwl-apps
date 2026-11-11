import CoreLocation
import CoreKit
import Foundation

/// 天气实况与预报（经 ios-server 网关代理 /api/v1/forecast/*，上游为和风 v1）
public struct WeatherSnapshot: Sendable, Equatable {
    public struct Current: Sendable, Equatable {
        public var temperature: Double
        public var feelsLike: Double
        public var humidity: Double
        public var windSpeed: Double
        public var code: Int
        public var time: Date
    }

    public struct Hour: Sendable, Equatable, Identifiable {
        public var id: Date { time }
        public var time: Date
        public var temperature: Double
        public var code: Int
    }

    public struct Day: Sendable, Equatable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var min: Double
        public var max: Double
        public var code: Int
    }

    public var current: Current
    public var hours: [Hour]
    public var days: [Day]
    public var sunrise: Date?
    public var sunset: Date?
    public var fetchedAt: Date
}

/// 服务不可用的具体原因（供界面给出可行动提示；网关未配置时说明配置缺失）。
public enum WeatherUnavailable: Sendable {
    case gatewayNotConfigured
    case request(Error)

    public var message: String {
        switch self {
        case .gatewayNotConfigured:
            return "天气服务未配置：缺少网关代理地址（spec.json integrations.edge.baseURL）。"
        case .request(let error):
            if let gatewayError = error as? NavGatewayError {
                return gatewayError.userMessage
            }
            let urlError = error as? URLError
            if urlError?.code == .notConnectedToInternet
                || urlError?.code == .networkConnectionLost
                || urlError?.code == .dataNotAllowed {
                return "网络连接不可用，请检查网络后重试。"
            }
            return "天气服务暂时不可用，请稍后重试。"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .gatewayNotConfigured: return false
        case .request(let error):
            if let gatewayError = error as? NavGatewayError { return gatewayError.isRetryable }
            return true
        }
    }
}

@MainActor
public final class WeatherService: ObservableObject {
    @Published public private(set) var snapshot: WeatherSnapshot?
    @Published public private(set) var isLoading = false
    @Published public private(set) var failure: NavFailure?
    /// 网关不可用的具体原因（配置缺失 / 服务端错误码），供界面「暂不可用」态展示。
    @Published public private(set) var unavailable: WeatherUnavailable?

    private let gateway: NavGatewayClient?

    public init() {
        // 配置从主包 spec.json integrations.edge 读取；缺失时进入不可用态（不回落第三方直连）
        if let config = NavGatewayConfig.load() {
            gateway = NavGatewayClient(config: config)
        } else {
            gateway = nil
        }
    }

    public func load(latitude: Double, longitude: Double) async {
        guard let gateway else {
            unavailable = .gatewayNotConfigured
            failure = .serviceError
            return
        }
        isLoading = true
        failure = nil
        unavailable = nil
        defer { isLoading = false }

        // 坐标最多保留两位小数（上游要求），格式「lng,lat」
        let location = String(format: "%.2f,%.2f", longitude, latitude)
        do {
            // 实况是必需的；逐小时/逐日失败不阻断整体（逐档降级）
            async let nowResult = gateway.post("/api/v1/forecast/now",
                                               data: ["location": location])
            async let hourlyResult = try? gateway.post("/api/v1/forecast/24h",
                                                       data: ["location": location])
            async let dailyResult = try? gateway.post("/api/v1/forecast/7d",
                                                      data: ["location": location])
            guard let parsed = NavWeatherParser.snapshot(now: try await nowResult,
                                                         hourly: try await hourlyResult,
                                                         daily: try await dailyResult) else {
                failure = .serviceError
                return
            }
            snapshot = WeatherSnapshot(
                current: .init(temperature: parsed.current.temperature,
                               feelsLike: parsed.current.feelsLike,
                               humidity: parsed.current.humidity,
                               windSpeed: parsed.current.windSpeed,
                               code: parsed.current.code,
                               time: parsed.current.time),
                hours: parsed.hours.map { .init(time: $0.time, temperature: $0.temperature, code: $0.code) },
                days: parsed.days.map { .init(date: $0.date, min: $0.min, max: $0.max, code: $0.code) },
                sunrise: parsed.sunrise,
                sunset: parsed.sunset,
                fetchedAt: parsed.fetchedAt)
        } catch let error as URLError {
            unavailable = .request(error)
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                failure = .offline
            default:
                failure = .serviceError
            }
        } catch {
            unavailable = .request(error)
            failure = .serviceError
        }
    }
}

/// 和风 v1 天气图标码（icon 字段即天气现象码）→ 文案与图标
public enum WeatherCode {
    public static func text(_ code: Int) -> String {
        switch code {
        case 100, 150:                      return "晴"
        case 101, 102, 103, 151, 152, 153:  return "多云"
        case 104:                           return "阴"
        case 300, 301, 350, 351:            return "阵雨"
        case 302, 303, 304:                 return "雷阵雨"
        case 305, 309:                      return "小雨"
        case 306:                           return "中雨"
        case 307, 308, 310...312, 399:      return "大雨"
        case 313, 314, 315...318:           return "雨"
        case 400, 409, 410, 456, 457:       return "小雪"
        case 401, 499:                      return "中雪"
        case 402, 403, 408:                 return "大雪"
        case 404...407:                     return "雨夹雪"
        case 500, 509, 510, 514, 515:       return "雾"
        case 502, 511, 512, 513:            return "霾"
        case 503, 504, 507, 508:            return "沙尘"
        default:                            return "未知"
        }
    }

    public static func icon(_ code: Int) -> String {
        switch code {
        case 100, 150:                      return "sun.max.fill"
        case 101, 102, 103, 151, 152, 153:  return "cloud.sun.fill"
        case 104:                           return "cloud.fill"
        case 300...318, 350, 351, 399:      return "cloud.rain.fill"
        case 302, 303, 304:                 return "cloud.bolt.rain.fill"
        case 400...410, 456, 457, 499:      return "cloud.snow.fill"
        case 500, 509, 510, 514, 515:       return "cloud.fog.fill"
        case 502, 511, 512, 513:            return "cloud.fog.fill"
        case 503, 504, 507, 508:            return "wind"
        default:                            return "cloud.fill"
        }
    }
}
