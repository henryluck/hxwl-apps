import Foundation

/// IAP 验单请求载荷（/api/iap/verify 的 data 段）。
/// isSandbox 决定 simulatesAskToBuyInSandbox：沙盒交易 true，生产 false。
enum IAPVerificationPayload {
    static func make(
        receiptData: String,
        transactionId: String,
        orderId: String?,
        userId: Int64?,
        isSandbox: Bool,
        amount: Decimal? = nil,
        currency: String? = nil,
        promotionAmount: Decimal? = nil
    ) -> [String: Any] {
        var data: [String: Any] = [
            "receiptData": receiptData,
            "transactionId": transactionId,
            "xcludeOldTransactions": true,
            "simulatesAskToBuyInSandbox": isSandbox,
        ]
        if let orderId { data["orderId"] = orderId }
        if let userId { data["identifier"] = userId }
        // 文档 8.5.4：商品金额/币种/推介优惠（promotionAmount 仅首购优惠价时非 nil）
        if let amount { data["amount"] = amount }
        if let currency { data["currency"] = currency }
        if let promotionAmount { data["promotionAmount"] = promotionAmount }
        return data
    }
}
