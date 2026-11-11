import CoreKit
import Foundation
import UIKit

// MARK: - 中台接入：经 ios-server AES 代理调用天枢
//
// 设计：配置驱动（spec.integrations.zhongtai）→ 走 ios-server AES 加密代理（非直连天枢）。
// 线格式（对齐 ios-demo / ios-server app/crypto.py）：
//   - Authorization 头 = AES(adhead) 后 base64
//   - body            = AES({"data": <payload>}) 后 base64 的 UTF8 字节
//   - POST application/json，不带 Access-Token（代理自管天枢 token）
//   - 响应明文 JSON：{ success, code, msg, data }；错误也返回 HTTP 200，按 success 判断
// 全部 12 个接口见《产品定义》/ ios-server 路由。

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

/// 中台代理配置（说明书 integrations.zhongtai 段注入）。
/// baseURL 为 ios-server 代理地址（如 http://host:8000）；aesKey/aesIv 各 16 字节。
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

/// 中台服务协议（12 接口）。插件/壳只面向此协议编程。
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
    /// 用户意见反馈提交（走 AES 代理 → ios-server/天枢 /api/feedback/submit）。
    func submitFeedback(_ payload: FeedbackPayload) async throws

    /// 健康检查探针：真实调 login。
    func healthCheck() async throws -> Bool
}

/// 空实现（未配置 zhongtai 时注入）。
public final class NullZhongtaiService: ZhongtaiService {
    public init() {}
    public var isConfigured: Bool { false }
    public var userId: Int64? { nil }
    public func login() async throws {}
    public func reportAttribution() async throws {}
    public func reportDigitalUnion() async throws {}
    public func reportBehavior(code: Int, value: Int) async throws {}
    public func reportEvent(name: String, params: [String: Any]) async throws {}
    public func setProfile(params: [String: Any], create: Bool) async throws {}
    public func iapProducts(type: TianxuCommodityProperty?) async throws -> [TianxuProduct] { [] }
    public func iapCreateOrder(commodityId: String, userId: Int64?) async throws -> String? { nil }
    public func iapRestore(orderInfoList: [[String: Any]]) async throws {}
    public func iapVerify(receiptData: String, transactionId: String, orderId: String?, isSandbox: Bool) async throws {}
    public func iapReportPayState(state: TianxuPayState, orderId: String?, tranId: String?) async throws {}
    public func submitFeedback(_ payload: FeedbackPayload) async throws {
        // 未配置中台：FeedbackView 调用前应判 isConfigured 回退 mailto；这里抛错兜底。
        throw URLError(.badURL)
    }
    public func healthCheck() async throws -> Bool { false }
}

/// 中台客户端：经 ios-server AES 代理调用全部 12 个接口。
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
    private func makeAdhead(forceNoUserId: Bool) async -> [String: Any] {
        let sysVersion = await UIDevice.current.systemVersion
        let model = await UIDevice.current.model
        var adhead: [String: Any] = [
            "phone": Self.machineIdentifier(),
            "model": model,
            "sys": sysVersion,
            "sysVersion": sysVersion,
            "platform": "iOS",
            "phoneType": "iOS",
            "manufacturer": "Apple",
            "deviceId": DeviceID.current,
            "prdId": config.prdId,
            "currentChannel": config.channel,
            "appVersion": appVersion,
            "appVersionCode": appVersionCode,
            "version": "3.0.6.5",
            "versionCode": 3065,
            "packageName": Bundle.main.bundleIdentifier ?? "",
            "phoneId": "",                  // IDFA（需 ATT 授权；默认空）
            "activityChannel": activityChannel,
            "digitalUnionId": "none",       // 工厂无数盟 SDK
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let uid = userId, !forceNoUserId { adhead["userId"] = uid }
        return adhead
    }

    /// 加密 POST：返回原始响应 Data（业务成败由调用方解包络判断）。
    private func post(_ endpoint: String, data: [String: Any], forceNoUserId: Bool = false) async throws -> Data {
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

    /// 仅判 success、不关心 data 的接口统一处理。
    @discardableResult
    private func postVoid(_ endpoint: String, data: [String: Any], forceNoUserId: Bool = false) async throws -> Bool {
        let raw = try await post(endpoint, data: data, forceNoUserId: forceNoUserId)
        let resp = try decode(TianxuVoid.self, from: raw)
        guard resp.success else { throw TianxuError(code: resp.code, msg: resp.msg) }
        return true
    }

    // MARK: - 1. 账号

    public func login() async throws {
        let raw = try await post("/api/account/login", data: [:], forceNoUserId: true)
        let resp = try decode(TianxuResponse<TianxuLoginData>.self, from: raw)
        guard resp.success else { throw TianxuError(code: resp.code, msg: resp.msg) }
        if let uid = resp.data?.userId { userId = uid }
        Log.info("[Zhongtai] 登录成功 userId=\(userId.map(String.init) ?? "-")")
    }

    public func reportAttribution() async throws {
        let idfv = await UIDevice.current.identifierForVendor?.uuidString ?? ""
        let raw = try await post("/api/attribution/report", data: ["idfv": idfv])
        let resp = try decode(TianxuResponse<TianxuAttributionData>.self, from: raw)
        guard resp.success else { throw TianxuError(code: resp.code, msg: resp.msg) }
        if let ch = resp.data?.activityChannel { activityChannel = ch }
    }

    public func reportDigitalUnion() async throws {
        // 工厂无数盟 SDK，上报占位值（接口存在以保持完整契约；无真实 cdid）。
        try await postVoid("/api/risk/digital-union",
                           data: ["digital_union_id": "none"])
    }

    // MARK: - 2. 统计

    public func reportBehavior(code: Int, value: Int) async throws {
        try await postVoid("/api/statistics/behavior", data: ["code": code, "value": value])
    }

    public func reportEvent(name: String, params: [String: Any]) async throws {
        try await postVoid("/api/statistics/event", data: ["eventName": name, "params": params])
    }

    public func setProfile(params: [String: Any], create: Bool) async throws {
        try await postVoid("/api/statistics/profile", data: ["params": params, "create": create])
    }

    // MARK: - 3. IAP

    public func iapProducts(type: TianxuCommodityProperty?) async throws -> [TianxuProduct] {
        var data: [String: Any] = [:]
        if let type { data["commodityProperty"] = type.rawValue }
        let raw = try await post("/api/iap/products", data: data)
        let resp = try decode(TianxuResponse<TianxuProductsData>.self, from: raw)
        guard resp.success else { throw TianxuError(code: resp.code, msg: resp.msg) }
        return resp.data?.purchaseCommodities ?? []
    }

    public func iapCreateOrder(commodityId: String, userId: Int64?) async throws -> String? {
        // 注意 "commoditNum" 是天枢约定的字段拼写（与 ios-demo 一致，非笔误）。
        var data: [String: Any] = ["type": 3, "commodityId": commodityId, "commoditNum": "1"]
        if let userId { data["identifier"] = userId }
        let raw = try await post("/api/iap/order", data: data)
        let resp = try decode(TianxuResponse<TianxuCreateOrderData>.self, from: raw)
        guard resp.success else { throw TianxuError(code: resp.code, msg: resp.msg) }
        return resp.data?.orderId
    }

    public func iapRestore(orderInfoList: [[String: Any]]) async throws {
        try await postVoid("/api/iap/restore", data: ["orderInfoList": orderInfoList])
    }

    public func iapVerify(receiptData: String, transactionId: String, orderId: String?, isSandbox: Bool) async throws {
        let data = IAPVerificationPayload.make(
            receiptData: receiptData,
            transactionId: transactionId,
            orderId: orderId,
            userId: userId,
            isSandbox: isSandbox
        )
        try await postVoid("/api/iap/verify", data: data)
    }

    public func iapReportPayState(state: TianxuPayState, orderId: String?, tranId: String?) async throws {
        var data: [String: Any] = ["orderState": state.rawValue]
        if let orderId { data["orderId"] = orderId }
        if let tranId { data["tranId"] = tranId }
        try await postVoid("/api/iap/pay-state", data: data)
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
        try await postVoid("/api/feedback/submit", data: data)
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

    // MARK: - 设备信息

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
