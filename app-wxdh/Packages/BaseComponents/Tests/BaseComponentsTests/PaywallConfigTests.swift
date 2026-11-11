import XCTest
@testable import BaseComponents

final class PaywallConfigTests: XCTestCase {
    func testSubscriptionNameCarriesSpecValue() {
        let config = PaywallConfig(
            appName: "测试App",
            plusName: "Plus",
            welcome: "欢迎使用",
            features: ["无限制使用所有功能"],
            introPrice: "¥8",
            renewPrice: "¥48",
            privacyURL: nil,
            termsURL: nil,
            subscriptionName: "周订阅"
        )

        XCTAssertEqual(config.subscriptionName, "周订阅")
    }

    func testSubscriptionNameDefaultsToEmptyForLegacySpecs() {
        let config = PaywallConfig(
            appName: "App",
            plusName: "Plus",
            welcome: "w",
            features: [],
            introPrice: "¥8",
            renewPrice: "¥48",
            privacyURL: nil,
            termsURL: nil
        )

        XCTAssertEqual(config.subscriptionName, "")
    }
}
