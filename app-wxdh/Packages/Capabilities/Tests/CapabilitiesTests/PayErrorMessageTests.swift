import XCTest
import StoreKit
@testable import Capabilities

/// 购买失败提示文案映射：审核实拍「购买失败 / Unable to Complete Request」
/// 即 StoreKitError.unknown 的英文原文被直接弹给用户，必须映射为中文可重试文案。
final class PayErrorMessageTests: XCTestCase {

    func testStoreKitUnknownMapsToFriendlyChinese() {
        // 审核员截图中，该错误在英文环境下的 localizedDescription 为
        // "Unable to Complete Request"（不应原样弹给用户）
        XCTAssertTrue(StoreKitError.unknown.payUserMessage.contains("重试"))
    }

    func testNetworkErrorMapsToNetworkHint() {
        let err = StoreKitError.networkError(URLError(.notConnectedToInternet))
        XCTAssertTrue(err.payUserMessage.contains("网络"))
    }

    func testSystemErrorMapsToFriendlyChinese() {
        let err = StoreKitError.systemError(URLError(.cannotConnectToHost))
        XCTAssertTrue(err.payUserMessage.contains("重试"))
    }

    func testProductNotFoundKeepsOwnMessage() {
        XCTAssertEqual(PayError.productNotFound.payUserMessage, "商品信息未加载，请检查网络后重试")
    }

    func testUnknownErrorFallsBackToGenericChinese() {
        let err = NSError(domain: "com.test", code: 42)
        let msg = err.payUserMessage
        XCTAssertTrue(msg.contains("重试"))
        XCTAssertFalse(msg.contains("com.test"))   // 不透出内部错误细节
    }

    func testRetryableClassification() {
        XCTAssertTrue(StoreKitError.unknown.isTransientPurchaseFailure)
        XCTAssertTrue(StoreKitError.networkError(URLError(.timedOut)).isTransientPurchaseFailure)
        XCTAssertTrue(StoreKitError.systemError(URLError(.cannotConnectToHost)).isTransientPurchaseFailure)
        XCTAssertFalse(StoreKitError.userCancelled.isTransientPurchaseFailure)
        XCTAssertFalse(PayError.productNotFound.isTransientPurchaseFailure)
        XCTAssertFalse(NSError(domain: "com.test", code: 1).isTransientPurchaseFailure)
    }
}
