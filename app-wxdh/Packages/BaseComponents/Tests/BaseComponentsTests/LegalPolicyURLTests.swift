import XCTest
@testable import BaseComponents

final class LegalPolicyURLTests: XCTestCase {
    func testRealHostURLIsConfiguredAsWebLink() {
        XCTAssertTrue(isConfiguredPolicyURL(URL(string: "https://www.apple.com/privacy")))
        XCTAssertTrue(isConfiguredPolicyURL(URL(string: "https://docs.example.org/terms")))
    }

    func testPlaceholderOrMissingURLFallsBackToLocalDoc() {
        XCTAssertFalse(isConfiguredPolicyURL(URL(string: "https://example.com/privacy")))
        XCTAssertFalse(isConfiguredPolicyURL(URL(string: "https://terms.example.com/terms")))
        XCTAssertFalse(isConfiguredPolicyURL(nil))
    }
}
