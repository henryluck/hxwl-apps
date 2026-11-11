import CoreKit
import Foundation
import UIKit

// MARK: - 中台网关接入：经 ios-server AES 代理调用天枢
//
// 设计：配置驱动（spec.integrations.edge）→ 走 ios-server AES 加密代理（非直连天枢）。
// 线格式（对齐 ios-server app/crypto.py，与参考工程 jzzndh-app 完全一致）：
//   - Authorization 头 = AES(adhead) 后 base64
//   - body            = AES({"data": <payload>}) 后 base64 的 UTF8 字节
//   - POST application/json，不带 Access-Token（代理自管天枢 token）
//   - 响应明文 JSON：{ ok, code, message, result }；错误也返回 HTTP 200，按 ok 判断
// prdId 是**唯一权威来源**（服务端只透传、不覆盖），全部接口见 ios-server 路由（19 个）。

/// 反馈提交载荷：设备/版本元信息 + 动态字段键值（按 spec.support.feedback.fields）。
public struct FeedbackPayload: Encodable {
    public let fields: [String: String]      // 字段 key → 用户填写值
    public let appVersion: String
    public let deviceModel: String
    public let systemVersion: String
    public init(fields: [String: String], appVersion: String, deviceModel: String, systemVersion: String) {
        self.fields = fields
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
    }
}

/// 中台网关代理配置（说明书 integrations.edge 段注入）。
/// baseURL 为 ios-server 代理地址（如 https://znwxdh.gzhuanxiwl.com）；aesKey/aesIv 各 16 字节。
public struct ZhongtaiConfig: Codable {
    public let prdId: String
    public let baseURL: String
    public let aesKey: String
    public let aesIv: String
    public let channel: Int

    public init(prdId: String, baseURL: String, aesKey: String, aesIv: String, channel: Int = 61) {
        self.prdId = prdId
        self.baseURL = baseURL
        self.aesKey = aesKey
        self.aesIv = aesIv
        self.channel = channel
    }
}

/// 稳定设备 ID（Keychain 持久化，卸载重装不变）。
public enum DeviceID {
    private static let key = "zhongtai.deviceId"

    public static var current: String {
        if let existing = KeychainStore.get(key) { return existing }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        KeychainStore.set(fresh, for: key)
        return fresh
    }
}

/// 中台服务协议（对接 ios-server 全部业务接口）。插件/壳只面向此协议编程。
public protocol ZhongtaiService {
    var isConfigured: Bool { get }
    var userId: Int64? { get }

    // 1. 账号
    /// 登录（启动流程：隐私同意后调用）。成功后 userId 写入 adhead，供后续接口使用。
    func login() async throws
    /// 归因上报（启动后调用；返回 activityChannel 写入 adhead）。
    func reportAttribution() async throws
    /// 数盟风险 ID 上报（工厂无数盟 SDK，占位）。
    func reportDigitalUnion() async throws

    // 2. 统计
    /// 关键行为回传。
    func reportBehavior(code: Int, value: Int) async throws
    /// 神策事件上报。
    func reportEvent(name: String, params: [String: Any]) async throws
    /// 神策批量事件上报。`sensorList` 每项：
    /// `["eventName": String, "offset": Int, "params": [String: Any]]`。
    func reportEventBatch(_ sensorList: [[String: Any]]) async throws
    /// 神策用户属性设置。
    func setProfile(params: [String: Any], create: Bool) async throws

    // 3. IAP
    /// 查询商品列表。
    func iapProducts(type: TianxuCommodityProperty?) async throws -> [TianxuProduct]
    /// 服务端下单，返回 orderId。
    func iapCreateOrder(commodityId: String, userId: Int64?) async throws -> String?
    /// 恢复购买。
    func iapRestore(orderInfoList: [[String: Any]]) async throws
    /// 服务端验单（票据校验）。isSandbox：沙盒交易 true（决定 simulatesAskToBuyInSandbox）。
    func iapVerify(receiptData: String, transactionId: String, orderId: String?, isSandbox: Bool) async throws
    /// 上报支付状态。
    func iapReportPayState(state: TianxuPayState, orderId: String?, tranId: String?) async throws

    // 4. 反馈
    /// 用户意见反馈提交（走 AES 代理 → ios-server /api/v1/support/feedback，本地 SQLite 持久化）。
    func submitFeedback(_ payload: FeedbackPayload) async throws

    // 5. 订阅页策略决策（多策略商品映射）
    /// 按投放策略决定展示哪个周订阅商品：服务端调天枢 deviceInfo 拿 strategyId
    /// 查映射表，返回 {strategyId, plan, productId, copy}。业务兜底（DEFAULT+B）
    /// 也算 success，失败抛错由调用方回退 B。
    func paywallStrategy() async throws -> TianxuPaywallDecision

    /// 健康检查探针：真实调 login。
    func healthCheck() async throws -> Bool
}

/// 空实现（未配置 edge 时注入）。
public final class NullZhongtaiService: ZhongtaiService {
    public init() {}
    public var isConfigured: Bool { false }
    public var userId: Int64? { nil }
    public func login() async throws {}
    public func reportAttribution() async throws {}
    public func reportDigitalUnion() async throws {}
    public func reportBehavior(code: Int, value: Int) async throws {}
    public func reportEvent(name: String, params: [String: Any]) async throws {}
    public func reportEventBatch(_ sensorList: [[String: Any]]) async throws {}
    public func setProfile(params: [String: Any], create: Bool) async throws {}
    public func iapProducts(type: TianxuCommodityProperty?) async throws -> [TianxuProduct] { [] }
    public func iapCreateOrder(commodityId: String, userId: Int64?) async throws -> String? { nil }
    public func iapRestore(orderInfoList: [[String: Any]]) async throws {}
    public func iapVerify(receiptData: String, transactionId: String, orderId: String?, isSandbox: Bool) async throws {}
    public func iapReportPayState(state: TianxuPayState, orderId: String?, tranId: String?) async throws {}
    public func submitFeedback(_ payload: FeedbackPayload) async throws {
        // 未配置网关：FeedbackView 调用前应判 isConfigured 回退 mailto；这里抛错兜底。
        throw URLError(.badURL)
    }
    public func paywallStrategy() async throws -> TianxuPaywallDecision {
        throw URLError(.badURL)
    }
    public func healthCheck() async throws -> Bool { false }
}

/// 中台客户端：经 ios-server AES 代理调用全部业务接口。
public final class ZhongtaiClient: ZhongtaiService {
    public private(set) var userId: Int64?
    public private(set) var activityChannel: Int = 0

    private let config: ZhongtaiConfig
    private let appVersion: String
    private let appVersionCode: Int

    public init(config: ZhongtaiConfig, appVersion: String, appVersionCode: Int) {
        self.config = config
        self.appVersion = appVersion
        self.appVersionCode = appVersionCode
    }

    public var isConfigured: Bool {
        !config.prdId.isEmpty && !config.baseURL.isEmpty && !config.aesKey.isEmpty
    }

    // MARK: - 传输层

    /// 构造 adhead（裸 dict；server 会覆盖 platform/version/currentChannel/timestamp 并注入 ip）。
    /// `forceNoUserId`：login 接口绝不带 userId（userId 是 login 的返回值）。
    ///
    /// 字段口径与参考工程 EdgeClient 一致：`phone` 与 `model` 都取 machine（非 UIDevice.model），
    /// `imei` 与 `phoneId` 同值。服务端 `_require_prd_id` 会本地拦截缺 prdId 的请求（9004）。
    private func makeAdhead(forceNoUserId: Bool) async -> [String: Any] {
        let sysVersion = await UIDevice.current.systemVersion
        let machine = Self.machineIdentifier()
        var adhead: [String: Any] = [
            "phone": machine,
            "model": machine,
            "sys": sysVersion,
            "sysVersion": sysVersion,
            "platform": "iOS",
            "phoneType": "iOS",
            "manufacturer": "Apple",
            "sdk_version": Self.sdkVersion,
            "deviceId": DeviceID.current,
            "prdId": config.prdId,
            "currentChannel": config.channel,
            "appVersion": appVersion,
            "appVersionCode": appVersionCode,
            "version": Self.sdkVersion,
            "versionCode": Self.sdkVersionCode,
            "packageName": Bundle.main.bundleIdentifier ?? "",
            "phoneId": "",                  // IDFA（需 ATT 授权；工厂未接归因 SDK，默认空）
            "imei": "",
            "activityChannel": activityChannel,
            "digitalUnionId": "none",       // 工厂无数盟 SDK
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let uid = userId, !forceNoUserId { adhead["userId"] = uid }
        return adhead
    }

    /// 加密 POST：返回原始响应 Data（业务成败由调用方解包络判断）。
    ///
    /// `data` 是 `Any` 而不是 `[String: Any]`：上游「上报数盟id」(updateFields) 的
    /// body 是**数组**（`data: [{key, val}]`），不是对象。
    private func post(_ endpoint: String, data: Any, forceNoUserId: Bool = false) async throws -> Data {
        guard isConfigured else { throw URLError(.badURL) }
        let adhead = await makeAdhead(forceNoUserId: forceNoUserId)
        let auth = try TianxAES.encryptToBase64(adhead, key: config.aesKey, iv: config.aesIv)
        let bodyCipher = try TianxAES.encryptToBase64(["data": data], key: config.aesKey, iv: config.aesIv)

        guard let url = URL(string: config.baseURL + endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = Data(bodyCipher.utf8)

        let (raw, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return raw
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            Log.error("[Zhongtai] 响应解析失败: \(error)")
            throw error
        }
    }

    /// 仅判 ok、不关心 result 的接口统一处理。
    @discardableResult
    private func postVoid(_ endpoint: String, data: Any, forceNoUserId: Bool = false) async throws -> Bool {
        let raw = try await post(endpoint, data: data, forceNoUserId: forceNoUserId)
        let resp = try decode(TianxuVoid.self, from: raw)
        guard resp.ok else { throw TianxuError(code: resp.code, msg: resp.message) }
        return true
    }

    // MARK: - 1. 账号

    public func login() async throws {
        let raw = try await post("/api/v1/session/start", data: [:], forceNoUserId: true)
        let resp = try decode(TianxuResponse<TianxuLoginData>.self, from: raw)
        guard resp.ok else { throw TianxuError(code: resp.code, msg: resp.message) }
        if let uid = resp.result?.userId { userId = uid }
        Log.info("[Zhongtai] 登录成功 userId=\(userId.map(String.init) ?? "-")")
    }

    public func reportAttribution() async throws {
        // 归因请求体：必传字段以天枢 YAPI 27427（appStartNew）为准；
        // iOS 不暴露真实安装时间，用首次启动时间近似。
        let data: [String: Any] = [
            "installTime": Self.installTimeMillis,
            "idfv": await UIDevice.current.identifierForVendor?.uuidString ?? "",
            "newAttribution": 1,
            "oceanengineAttr": 1,
        ]
        let raw = try await post("/api/v1/install/attribute", data: data)
        let resp = try decode(TianxuResponse<TianxuAttributionData>.self, from: raw)
        guard resp.ok else { throw TianxuError(code: resp.code, msg: resp.message) }
        // 归因成功：activityChannel 写入请求头，后续所有接口自动带上。
        if let ch = resp.result?.activityChannel, ch != 0 {
            activityChannel = ch
            Log.info("[Zhongtai] 归因成功 activityChannel=\(ch)")
        } else {
            Log.info("[Zhongtai] 归因返回无渠道号（自然量或未匹配）")
        }
    }

    public func reportDigitalUnion() async throws {
        // 工厂无数盟 SDK：无真实 cdid 时不发（上游要求请求头带 userId 且 body 为数组形态）。
        // 接口契约保留：数盟 ID 取到后按 [{key, val}] 数组上报 updateFields。
        guard userId != nil else {
            Log.warn("[Zhongtai] userId 未就绪，数盟 ID 上报跳过（上游要求请求头带 userId）")
            return
        }
        try await postVoid("/api/v1/device/union",
                           data: [["key": "digital_union_id", "val": "none"]])
    }

    // MARK: - 2. 统计

    public func reportBehavior(code: Int, value: Int) async throws {
        try await postVoid("/api/v1/action/report", data: ["code": code, "value": value])
    }

    public func reportEvent(name: String, params: [String: Any]) async throws {
        try await postVoid("/api/v1/telemetry/event", data: ["eventName": name, "params": params])
    }

    public func reportEventBatch(_ sensorList: [[String: Any]]) async throws {
        try await postVoid("/api/v1/telemetry/event/batch", data: ["sensorList": sensorList])
    }

    public func setProfile(params: [String: Any], create: Bool) async throws {
        try await postVoid("/api/v1/telemetry/profile", data: ["params": params, "create": create])
    }

    // MARK: - 3. IAP

    public func iapProducts(type: TianxuCommodityProperty?) async throws -> [TianxuProduct] {
        var data: [String: Any] = [:]
        if let type { data["commodityProperty"] = type.rawValue }
        let raw = try await post("/api/v1/store/catalog", data: data)
        let resp = try decode(TianxuResponse<TianxuProductsData>.self, from: raw)
        guard resp.ok else { throw TianxuError(code: resp.code, msg: resp.message) }
        return resp.result?.purchaseCommodities ?? []
    }

    public func iapCreateOrder(commodityId: String, userId: Int64?) async throws -> String? {
        // 字段以天枢 YAPI 27454（addOrder）为准：required: commodityId / commoditNum(number) / type。
        // "commoditNum" 是上游字段拼写（少一个 y），不是笔误，且必须是数字。
        var data: [String: Any] = ["type": 3, "commodityId": commodityId, "commoditNum": 1]
        if let userId { data["identifier"] = userId }
        let raw = try await post("/api/v1/store/order", data: data)
        let resp = try decode(TianxuResponse<TianxuCreateOrderData>.self, from: raw)
        guard resp.ok else { throw TianxuError(code: resp.code, msg: resp.message) }
        return resp.result?.orderId
    }

    public func iapRestore(orderInfoList: [[String: Any]]) async throws {
        var data: [String: Any] = ["orderInfoList": orderInfoList]
        if let userId { data["identifier"] = userId }
        try await postVoid("/api/v1/store/restore", data: data)
    }

    public func iapVerify(receiptData: String, transactionId: String, orderId: String?, isSandbox: Bool) async throws {
        let data = IAPVerificationPayload.make(
            receiptData: receiptData,
            transactionId: transactionId,
            orderId: orderId,
            userId: userId,
            isSandbox: isSandbox
        )
        try await postVoid("/api/v1/store/verify", data: data)
    }

    public func iapReportPayState(state: TianxuPayState, orderId: String?, tranId: String?) async throws {
        // YAPI 27463（reportState）：required: orderId / orderState / platform；platform 固定 apple。
        var data: [String: Any] = ["orderState": state.rawValue, "platform": "apple"]
        if let orderId { data["orderId"] = orderId }
        if let tranId { data["tranId"] = tranId }
        try await postVoid("/api/v1/store/state", data: data)
    }

    // MARK: - 4. 反馈

    public func submitFeedback(_ payload: FeedbackPayload) async throws {
        var data: [String: Any] = [
            "fields": payload.fields,
            "appVersion": payload.appVersion,
            "deviceModel": payload.deviceModel,
            "systemVersion": payload.systemVersion,
        ]
        if let uid = userId { data["userId"] = uid }
        try await postVoid("/api/v1/support/feedback", data: data)
    }

    // MARK: - 5. 订阅页策略决策

    public func paywallStrategy() async throws -> TianxuPaywallDecision {
        let raw = try await post("/api/v1/paywall/strategy", data: [:])
        let resp = try decode(TianxuResponse<TianxuPaywallDecision>.self, from: raw)
        guard resp.ok, let decision = resp.result else {
            throw TianxuError(code: resp.code, msg: resp.message)
        }
        return decision
    }

    public func healthCheck() async throws -> Bool {
        guard isConfigured else { return false }
        do {
            try await login()
            return true
        } catch {
            Log.error("[Zhongtai] 健康检查失败: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 常量与设备信息

    /// 中台 SDK 版本号。天枢文档明确「默认 3.0.6.5」，版本号由客户端上报、服务端只做兜底覆盖，
    /// 保持与文档一致（不是 App 的 version）。
    static let sdkVersion = "3.0.6.5"
    static let sdkVersionCode = 3065

    /// 首次启动时间（毫秒）：iOS 不暴露真实安装时间，用首次启动近似（归因 installTime 用）。
    private static let installTimeMillis: Int64 = {
        let key = "zhongtai.installTime"
        if let existing = UserDefaults.standard.object(forKey: key) as? Int64 { return existing }
        let fresh = Int64(Date().timeIntervalSince1970 * 1000)
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    /// 机器标识（如 iPhone15,2）。模拟器可能返回 arm64/x86_64，仅用于上报，不影响业务。
    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}
