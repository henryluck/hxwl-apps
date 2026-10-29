import Foundation

/// IAP 验单请求载荷（/api/iap/verify 的 data 段）。
/// isSandbox 决定 simulatesAskToBuyInSandbox：沙盒交易 true，生产 false。
enum IAPVerificationPayload {
    static func make(
        receiptData: String,
        transactionId: String,
        orderId: String?,
        userId: Int64?,
        isSandbox: Bool
    ) -> [String: Any] {
        var data: [String: Any] = [
            "receiptData": receiptData,
            "transactionId": transactionId,
            "xcludeOldTransactions": true,
            "simulatesAskToBuyInSandbox": isSandbox,
        ]
        if let orderId { data["orderId"] = orderId }
        if let userId { data["identifier"] = userId }
        return data
    }
}
