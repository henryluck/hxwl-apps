import XCTest
@testable import Capabilities

final class IAPVerificationPayloadTests: XCTestCase {
    func testSandboxTransactionEncodesSandboxEnvironment() {
        let payload = IAPVerificationPayload.make(
            receiptData: "receipt",
            transactionId: "123",
            orderId: nil,
            userId: nil,
            isSandbox: true
        )

        XCTAssertEqual(payload["simulatesAskToBuyInSandbox"] as? Bool, true)
    }

    func testProductionTransactionEncodesProductionEnvironment() {
        let payload = IAPVerificationPayload.make(
            receiptData: "receipt",
            transactionId: "123",
            orderId: "order",
            userId: 42,
            isSandbox: false
        )

        XCTAssertEqual(payload["simulatesAskToBuyInSandbox"] as? Bool, false)
        XCTAssertEqual(payload["orderId"] as? String, "order")
        XCTAssertEqual(payload["identifier"] as? Int64, 42)
    }
}
