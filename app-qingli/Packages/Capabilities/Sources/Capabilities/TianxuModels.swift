import Foundation

// MARK: - 天枢代理（ios-server）响应模型
//
// ios-server 把天枢响应原样透传，统一包络：{ success, code, msg, data }。
// 注意：错误也返回 HTTP 200（code=500x），所以必须解包络、按 success 判断。

/// 统一响应包络。`data` 类型由调用方按接口指定。
public struct TianxuResponse<T: Decodable>: Decodable {
    public let success: Bool
    public let code: Int?
    public let msg: String?
    public let data: T?

    public init(success: Bool, code: Int? = nil, msg: String? = nil, data: T? = nil) {
        self.success = success
        self.code = code
        self.msg = msg
        self.data = data
    }
}

/// 业务错误（success==false 时抛出）。
public struct TianxuError: Error, CustomStringConvertible {
    public let code: Int?
    public let msg: String?
    public init(code: Int?, msg: String?) { self.code = code; self.msg = msg }
    public var description: String { "TianxuError(code=\(code ?? -1), msg=\(msg ?? ""))" }
}
extension TianxuError: LocalizedError {
    /// 让 error.localizedDescription 也能看到天枢的 code/msg（默认只显示 "error 1"）。
    public var errorDescription: String? {
        "天枢接口失败[code=\(code.map(String.init) ?? "-1")] \(msg ?? "")"
    }
}

/// 「任意 JSON」占位类型：init 不读任何键，可吞掉任意 data（用于只关心 success 的接口）。
public struct TianxuAny: Decodable { public init(from _: Decoder) throws {} }

/// 仅判 success、不关心 data 的接口（统计上报、恢复、支付状态等）的返回占位。
public typealias TianxuVoid = TianxuResponse<TianxuAny>

// MARK: - 登录（/api/account/login）

public struct TianxuLoginData: Decodable {
    public let userId: Int64?
    public let newUser: Bool?
    /// 天枢下发的业务 token（与代理自管的 Access-Token 不同；客户端存业务用，回传本代理不需要）。
    public let accessToken: String?
    public let prdId: String?
    public let tongdunTimeout: Int?
}

// MARK: - 归因（/api/attribution/report）

public struct TianxuAttributionData: Decodable {
    public let activityChannel: Int?
    public let isNatureChannel: Bool?
    public let marketingPlatform: String?
}

// MARK: - IAP 商品（/api/iap/products）

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

// MARK: - IAP 下单（/api/iap/order）

public struct TianxuCreateOrderData: Decodable {
    public let orderId: String?
}

// MARK: - IAP 商品类型（ios-demo Purchase_Product_Type）

public enum TianxuCommodityProperty: String {
    case consumable      = "TYPE_COMSUMABLE"
    case nonConsumable   = "TYPE_NO_COMSUMABLE"
    case autoRenewable   = "TYPE_AUTO_RENEWAL"
    case nonAutoRenewable = "TYPE_NO_AUTO_RENEWAL"
}

/// IAP 支付状态（/api/iap/pay-state 的 orderState）。
public enum TianxuPayState: String {
    case success = "PAY_SUCCESS"
    case failure = "PAY_FAILURE"
}
