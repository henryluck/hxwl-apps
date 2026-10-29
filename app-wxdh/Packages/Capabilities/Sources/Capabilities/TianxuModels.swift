import Foundation

// MARK: - 中台网关（ios-server）响应模型
//
// ios-server 统一包络：{ ok, code, message, result }。
// 注意：错误也返回 HTTP 200（code=9xxx / 31xxxx 透传），且失败包络不含 result 键，
// 所以必须解包络、按 ok 判断，不能看 HTTP 状态码。

/// 统一响应包络。`result` 类型由调用方按接口指定。
public struct TianxuResponse<T: Decodable>: Decodable {
    public let ok: Bool
    public let code: Int?
    public let message: String?
    public let result: T?

    public init(ok: Bool, code: Int? = nil, message: String? = nil, result: T? = nil) {
        self.ok = ok
        self.code = code
        self.message = message
        self.result = result
    }
}

/// 业务错误（ok==false 时抛出）。
public struct TianxuError: Error, CustomStringConvertible {
    public let code: Int?
    public let msg: String?
    public init(code: Int?, msg: String?) { self.code = code; self.msg = msg }
    public var description: String { "TianxuError(code=\(code ?? -1), msg=\(msg ?? ""))" }
}
extension TianxuError: LocalizedError {
    /// 让 error.localizedDescription 也能看到服务端的 code/message（默认只显示 "error 1"）。
    public var errorDescription: String? {
        "网关接口失败[code=\(code.map(String.init) ?? "-1")] \(msg ?? "")"
    }
}

/// 「任意 JSON」占位类型：init 不读任何键，可吞掉任意 result（用于只关心 ok 的接口）。
public struct TianxuAny: Decodable { public init(from _: Decoder) throws {} }

/// 仅判 ok、不关心 result 的接口（统计上报、恢复、支付状态等）的返回占位。
public typealias TianxuVoid = TianxuResponse<TianxuAny>

// MARK: - 登录（/api/v1/session/start）

public struct TianxuLoginData: Decodable {
    public let userId: Int64?
    public let newUser: Bool?
    /// 天枢下发的业务 token（与代理自管的 Access-Token 不同；客户端存业务用，回传本代理不需要）。
    public let accessToken: String?
    public let prdId: String?
    /// 风控等待时长（毫秒）。
    public let tongdunTimeout: Int?
}

// MARK: - 归因（/api/v1/install/attribute）

public struct TianxuAttributionData: Decodable {
    public let activityChannel: Int?
    public let isNatureChannel: Bool?
    public let marketingPlatform: String?
}

// MARK: - IAP 商品（/api/v1/store/catalog）

public struct TianxuProduct: Decodable, Identifiable {
    public var id: String { commodityId ?? iosProductId ?? UUID().uuidString }
    public let commodityId: String?
    public let iosProductId: String?
    public let commodityProperty: String?     // TYPE_COMSUMABLE / TYPE_AUTO_RENEWAL …
    public let unitPrice: Double?
}

public struct TianxuProductsData: Decodable {
    public let purchaseCommodities: [TianxuProduct]?
}

// MARK: - IAP 下单（/api/v1/store/order）

public struct TianxuCreateOrderData: Decodable {
    public let orderId: String?
}

// MARK: - IAP 商品类型（上游 Purchase_Product_Type）

public enum TianxuCommodityProperty: String {
    case consumable      = "TYPE_COMSUMABLE"
    case nonConsumable   = "TYPE_NO_COMSUMABLE"
    case autoRenewable   = "TYPE_AUTO_RENEWAL"
    case nonAutoRenewable = "TYPE_NO_AUTO_RENEWAL"
}

/// IAP 支付状态（/api/v1/store/state 的 orderState）。
public enum TianxuPayState: String {
    case success = "PAY_SUCCESS"
    case failure = "PAY_FAILURE"
}

// MARK: - 订阅页策略决策（/api/v1/paywall/strategy，多策略商品映射 A/B/C/D）

/// 服务端下发的展示文案（任一字段空/缺省 → 客户端回退内置模板）。
public struct TianxuPaywallCopy: Decodable, Equatable, Sendable {
    /// 启动入口价格行（如「新人优惠首周¥5.8，之后¥58/周」）
    public let launch_price_line: String?
    /// 周卡标题（如「新人优惠首周」）
    public let card_title: String?
    /// 周卡说明（如「之后¥58/周自动续费」）
    public let card_desc: String?
    /// 角标文案（空/缺省 = 不显示角标）
    public let tag: String?
}

/// 策略决策结果：`plan` 为 "A"/"B"/"C"/"D"（命中映射）或 "DEFAULT"（服务端兜底）。
public struct TianxuPaywallDecision: Decodable, Sendable {
    public let strategyId: Int?
    public let plan: String
    public let productId: String
    public let copy: TianxuPaywallCopy?
}
