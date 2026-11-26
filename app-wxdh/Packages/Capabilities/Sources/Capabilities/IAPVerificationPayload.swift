import Foundation
import StoreKit

/// IAP 验单请求载荷（/api/iap/verify 的 data 段）。
/// isSandbox 决定 simulatesAskToBuyInSandbox：沙盒交易 true，生产 false。
/// 【文档 361-617 §8.5.4】推介优惠（introductory offer）需传 promotionAmount；
/// amount/currency 为商品原价与币种（SK2 等价实现：Product.prices / offer 价）。
enum IAPVerificationPayload {
    static func make(
        receiptData: String,
        transactionId: String,
        orderId: String?,
        userId: Int64?,
        isSandbox: Bool,
        amount: String? = nil,
        currency: String? = nil,
        promotionAmount: String? = nil
    ) -> [String: Any] {
        var data: [String: Any] = [
            "receiptData": receiptData,
            "transactionId": transactionId,
            "xcludeOldTransactions": true,
            "simulatesAskToBuyInSandbox": isSandbox,
        ]
        if let orderId { data["orderId"] = orderId }
        if let userId { data["identifier"] = userId }
        if let amount { data["amount"] = amount }
        if let currency { data["currency"] = currency }
        // 推介优惠价（首期优惠）；无 offer 不传
        if let promotionAmount { data["promotionAmount"] = promotionAmount }
        return data
    }

    /// 从 StoreKit 2 Product 提取验单金额字段（displayPrice 含币种符号，
    /// 服务端接受数值字符串；currency 用 ISO 4217 代码）。
    static func amounts(from product: Product) -> (amount: String, currency: String, promotion: String?) {
        // SK2：locale.currencyCode 取 ISO 4217（价格区域即用户商店区域）
        let currency = product.priceFormatStyle.locale.currencyCode ?? "CNY"
        //推介优惠：订阅推介（introductory）优先，其次 win-back/促销 offer 不属于推介口径
        var promo: String?
        if let intro = product.subscription?.introductoryOffer {
            // offer 支付金额（displayPrice 形态，如 "¥0.00"）→ 数值串
            let formatted = intro.displayPrice
            promo = numericPart(from: formatted)
        }
        return (numericPart(from: product.displayPrice), currency, promo)
    }

    /// "¥5.80" / "5.8" → "5.8"（去符号留数字与小数点）
    private static func numericPart(from price: String) -> String {
        String(price.filter { "0123456789.".contains($0) })
    }
}
