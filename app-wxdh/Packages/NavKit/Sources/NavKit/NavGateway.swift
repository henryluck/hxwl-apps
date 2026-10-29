import Capabilities
import CoreKit
import Foundation
import UIKit

// MARK: - NavKit 网关传输层（ios-server 的 /api/v1/*）
//
// 天气与反馈不再直连上游：统一走 ios-server 的「AES 信封 + 统一包络」。
// 线格式与壳侧 ZhongtaiClient 完全一致（同一条链路，不另立一套）：
//   · Authorization 头 = AES(adhead) 后 base64
//   · body            = AES({"data": <payload>}) 后 base64 的 UTF8 字节
//   · POST application/json，不带任何上游凭证（代理自管）
//   · 响应 HTTP 200 + `{ok, code, message, result}`；失败以 ok:false 表达
//
// 配置从主包 spec.json 的 `integrations.edge` 读取（与壳装配同一段配置，
// 避免两处各写一份地址/密钥）。配置缺失时各功能进入「暂不可用」，
// 不制造成功状态（天气回落 Open-Meteo 的旧行为已移除——服务端契约优先）。

/// 网关配置（spec.json → integrations.edge）。
public struct NavGatewayConfig: Sendable {
    public let baseURL: URL
    public let aesKey: String
    public let aesIv: String
    public let prdId: String
    public let channel: Int
    public let appVersion: String
    public let appVersionCode: Int

    /// 从主包 spec.json 读取；缺失或字段不完整返回 nil（调用方进入不可用态）。
    public static func load(bundle: Bundle = .main) -> NavGatewayConfig? {
        guard let url = bundle.url(forResource: "spec", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let integrations = root["integrations"] as? [String: Any],
              let edge = integrations["edge"] as? [String: Any] else {
            Log.warn("[NavGateway] spec.json 缺少 integrations.edge，天气/反馈走不可用态")
            return nil
        }
        func text(_ key: String) -> String? {
            guard let v = edge[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        guard let baseText = text("baseURL"), let baseURL = URL(string: baseText),
              baseURL.scheme != nil, baseURL.host != nil else {
            Log.warn("[NavGateway] edge.baseURL 不是合法地址")
            return nil
        }
        guard let aesKey = text("aesKey") else {
            Log.warn("[NavGateway] edge.aesKey 未配置")
            return nil
        }
        let identity = root["identity"] as? [String: Any]
        return NavGatewayConfig(baseURL: baseURL,
                                aesKey: aesKey,
                                aesIv: text("aesIv") ?? aesKey,
                                prdId: text("prdId") ?? "",
                                channel: (edge["channel"] as? NSNumber)?.intValue ?? 61,
                                appVersion: (identity?["version"] as? String) ?? "",
                                appVersionCode: (identity?["build"] as? NSNumber)?.intValue ?? 0)
    }
}

/// 网关返回的业务错误（HTTP 200 + `ok:false`），携带服务端错误码与说明。
public struct NavGatewayError: Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public var errorDescription: String? { message }

    /// 服务端错误码 → 用户可读文案（见 ios-server README「错误码」）。
    public var userMessage: String {
        switch code {
        case 9001:          return "请求无法被服务端识别，请更新 App 后重试。"
        case 9004:          return "请求参数有误，请更新 App 后重试。"
        case 9005, 9006:    return "服务暂时不可用，请稍后重试。"
        case 9007:          return "操作太频繁了，请稍后再试。"
        case 9011:          return "天气服务暂时不可用，请稍后重试。"
        case 9002, 9003, 9010: return "服务暂时不可用，请稍后重试。"
        default:
            return message.isEmpty ? "服务暂时不可用，请稍后重试。" : message
        }
    }

    /// 参数类错误（9001/9004）重试不会变，界面应提示更新而非反复重试。
    public var isRetryable: Bool {
        switch code {
        case 9001, 9004: return false
        default: return true
        }
    }
}

/// 网关客户端：一次性请求 + SSE 流式请求（AI 对话）。
public struct NavGatewayClient: Sendable {

    private let config: NavGatewayConfig
    private let deviceId: String

    public init(config: NavGatewayConfig, deviceId: String = DeviceID.current) {
        self.config = config
        self.deviceId = deviceId
    }

    /// 网关是否已配置（未配置时功能进入不可用态）。
    public static var isConfigured: Bool { NavGatewayConfig.load() != nil }

    // MARK: - 一次性请求

    /// 发起一次信封请求，返回包络里的 `result`（失败抛 NavGatewayError）。
    public func post(_ path: String, data: [String: Any], timeout: TimeInterval = 20) async throws -> Any? {
        let request = try await makeRequest(path: path, data: data,
                                            timeout: timeout, accept: "application/json")
        do {
            let (raw, response) = try await URLSession.shared.data(for: request)
            try Self.ensureHTTPOK(response, url: request.url)
            return try Self.result(from: raw)
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - 流式请求（SSE，AI 对话）

    /// 发起一次信封请求并把上游 SSE 增量逐块吐出（只吐正文文本，不含思考过程）。
    ///
    /// 流在以下情况结束：收到 `data: [DONE]`、连接关闭，或抛错。
    /// 服务端在**流开始前**失败时返回 HTTP 200 + JSON 错误信封（非 SSE），
    /// 必须按信封解析出 ok:false 抛错 —— 否则真实错误（限流/余额不足）被吞掉。
    public func stream(_ path: String, data: [String: Any],
                       timeout: TimeInterval = 120) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await makeRequest(path: path, data: data,
                                                        timeout: timeout, accept: "text/event-stream")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try Self.ensureHTTPOK(response, url: request.url)
                    if Self.isJSONEnvelope(response) {
                        // 流开始前的业务失败：读完整 body 按统一信封解析（ok:false → 抛错）
                        var lines: [String] = []
                        for try await line in bytes.lines { lines.append(line) }
                        let body = Data(lines.joined(separator: "\n").utf8)
                        _ = try Self.result(from: body)
                        throw URLError(.badServerResponse)   // ok:true 却没走 SSE：形状异常
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        switch Self.event(fromSSE: payload) {
                        case .delta(let text):
                            if !text.isEmpty { continuation.yield(text) }
                        case .failure(let error):
                            throw error
                        case .ignore:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.translate(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 响应是否为 JSON 信封（服务端流开始前失败时返回 application/json，而非 SSE）。
    private static func isJSONEnvelope(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?
                  .lowercased() else { return false }
        return contentType.contains("application/json")
    }

    // MARK: - 请求构造

    private func makeRequest(path: String, data: [String: Any],
                             timeout: TimeInterval, accept: String) async throws -> URLRequest {
        guard let url = Self.url(base: config.baseURL, path: path) else {
            throw URLError(.badURL)
        }
        let adhead = await makeAdhead()
        let auth: String
        let body: String
        do {
            auth = try TianxAES.encryptToBase64(adhead, key: config.aesKey, iv: config.aesIv)
            body = try TianxAES.encryptToBase64(["data": data], key: config.aesKey, iv: config.aesIv)
        } catch {
            Log.error("[NavGateway] 信封加密失败: \(error)")
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = Data(body.utf8)
        return request
    }

    private static func url(base: URL, path: String) -> URL? {
        let root = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast())
            : base.absoluteString
        return URL(string: root + path)
    }

    /// adhead：与壳侧 ZhongtaiClient 同字段。天气/反馈不转发上游时也保持同一份
    /// 设备形状（服务端日志按 deviceId 定位；对话限流按 deviceId 维度）。
    private func makeAdhead() async -> [String: Any] {
        let device = await MainActor.run {
            (model: UIDevice.current.model, sys: UIDevice.current.systemVersion)
        }
        var machine = "unknown"
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        machine = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return [
            "phone": machine,
            "model": machine,
            "sys": device.sys,
            "sysVersion": device.sys,
            "platform": "iOS",
            "phoneType": "iOS",
            "manufacturer": "Apple",
            "deviceId": deviceId,
            "prdId": config.prdId,
            "currentChannel": config.channel,
            "appVersion": config.appVersion,
            "appVersionCode": config.appVersionCode,
            "packageName": Bundle.main.bundleIdentifier ?? "",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
    }

    // MARK: - 响应解析

    private static func ensureHTTPOK(_ response: URLResponse, url: URL?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            Log.warn("[NavGateway] 网关 HTTP \(http.statusCode) \(url?.absoluteString ?? "")")
            throw URLError(.badServerResponse)
        }
    }

    /// 解出统一包络里的 `result`；`ok:false` 时抛 NavGatewayError。
    private static func result(from data: Data) throws -> Any? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = root["ok"] as? Bool else {
            throw URLError(.badServerResponse)
        }
        guard ok else {
            throw NavGatewayError(code: root["code"] as? Int ?? -1,
                                  message: (root["message"] as? String) ?? "")
        }
        return root["result"]
    }

    // MARK: - SSE 事件

    private enum SSEEvent {
        case delta(String)      // 正文增量
        case failure(NavGatewayError)
        case ignore             // 首块 role 帧、心跳、思考过程等
    }

    /// 解析一行 OpenAI 兼容 SSE。服务端原样透传上游事件（choices[0].delta.content），
    /// 流中途失败时追加 `{"error":{...}}` 后以 [DONE] 收尾。
    private static func event(fromSSE payload: String) -> SSEEvent {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .ignore
        }
        if let error = root["error"] as? [String: Any] {
            return .failure(NavGatewayError(code: error["code"] as? Int ?? -1,
                                            message: (error["message"] as? String) ?? ""))
        }
        guard let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return .ignore }
        // 只取 content：reasoning_content 是模型的思考过程，不属于回答
        return .delta((delta["content"] as? String) ?? "")
    }

    // MARK: - 错误归一

    private static func translate(_ error: Error) -> Error {
        if error is NavGatewayError { return error }
        guard let urlError = error as? URLError else {
            Log.warn("[NavGateway] 请求失败: \(error.localizedDescription)")
            return URLError(.badServerResponse)
        }
        return urlError
    }
}

// MARK: - 天气数据模型与解析（和风 v1，经网关 /api/v1/forecast/*）

public struct NavWeatherSnapshot: Sendable, Equatable {
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

public enum NavWeatherParser {
    /// 从 result（上游原样 JSON）解析三档合一的快照。
    /// `now` 必需；`hourly`/`daily` 缺失不阻断整体（逐档降级）。
    public static func snapshot(now: Any?, hourly: Any?, daily: Any?) -> NavWeatherSnapshot? {
        guard let nowRoot = dict(now), let current = parseCurrent(nowRoot) else { return nil }

        var hours: [NavWeatherSnapshot.Hour] = []
        if let hourlyRoot = dict(hourly) {
            hours = parseHours(hourlyRoot)
        }
        var days: [NavWeatherSnapshot.Day] = []
        var sunrise: Date?
        var sunset: Date?
        if let dailyRoot = dict(daily) {
            (days, sunrise, sunset) = parseDays(dailyRoot)
        }
        return NavWeatherSnapshot(current: current, hours: hours, days: days,
                                  sunrise: sunrise, sunset: sunset, fetchedAt: Date())
    }

    // MARK: 解析工具

    private static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private static func array(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]]) ?? []
    }
    private static func str(_ value: Any?) -> String? { value as? String }
    private static func num(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// 实况：`now` 对象。code 取 icon 字段（和风图标码即天气现象码）。
    private static func parseCurrent(_ root: [String: Any]) -> NavWeatherSnapshot.Current? {
        let now: [String: Any]
        if let inner = root["now"] as? [String: Any] {
            now = inner
        } else {
            now = root
        }
        guard let temp = num(now["temp"]) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = .current
        // obsTime 形如 2024-05-31T14:00+08:00；缺省用当前时间
        let time = now["obsTime"].flatMap { str($0) }.flatMap { Self.parseISO($0) } ?? Date()
        return NavWeatherSnapshot.Current(
            temperature: temp,
            feelsLike: num(now["feelsLike"]) ?? temp,
            humidity: num(now["humidity"]) ?? 0,
            windSpeed: num(now["windSpeed"]) ?? 0,
            code: int(now["icon"]) ?? 999,
            time: time)
    }

    /// 逐小时：`hourly` 数组，time 为 ISO 串。
    private static func parseHours(_ root: [String: Any]) -> [NavWeatherSnapshot.Hour] {
        array(root["hourly"]).prefix(24).compactMap { hour in
            guard let timeStr = str(hour["fxTime"]),
                  let time = Self.parseISO(timeStr),
                  let temp = num(hour["temp"]) else { return nil }
            return NavWeatherSnapshot.Hour(time: time,
                                           temperature: temp,
                                           code: int(hour["icon"]) ?? 999)
        }
    }

    /// 逐日：`daily` 数组 + 首日日出日落。
    private static func parseDays(_ root: [String: Any])
        -> (days: [NavWeatherSnapshot.Day], sunrise: Date?, sunset: Date?) {
        var sunrise: Date?
        var sunset: Date?
        let days = array(root["daily"]).prefix(7).enumerated().compactMap { index, day -> NavWeatherSnapshot.Day? in
            guard let dateStr = str(day["fxDate"]),
                  let date = Self.parseDateOnly(dateStr),
                  let max = num(day["tempMax"]),
                  let min = num(day["tempMin"]) else { return nil }
            if index == 0 {
                sunrise = str(day["sunrise"]).flatMap(Self.parseTimeOnly)
                sunset = str(day["sunset"]).flatMap(Self.parseTimeOnly)
            }
            return NavWeatherSnapshot.Day(date: date, min: min, max: max,
                                          code: int(day["iconDay"]) ?? int(day["icon"]) ?? 999)
        }
        return (days, sunrise, sunset)
    }

    /// ISO8601（带/不带秒与偏移）解析，失败兜底常见格式。
    static func parseISO(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// 纯日期（yyyy-MM-dd，当日零点）。
    static func parseDateOnly(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: text)
    }

    /// 纯时间（HH:mm，拼当日日期）。
    static func parseTimeOnly(_ text: String) -> Date? {
        let today = DateFormatter()
        today.locale = Locale(identifier: "en_US_POSIX")
        today.dateFormat = "yyyy-MM-dd"
        today.timeZone = .current
        let day = today.string(from: Date())
        return parseISO("\(day) \(text)")
    }
}
