import XCTest

/// 订阅门验证 + 指引整页长图验证
final class GateVerifyTests: XCTestCase {
    /// 未订阅点「开始修复」应弹出订阅墙（会员权益）
    @MainActor
    func testPaywallGateBlocksRepair() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding", "-uitest-gate-block"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["允许完全访问", "Allow Full Access", "好", "OK"] {
            let btn = springboard.buttons[title]
            if btn.waitForExistence(timeout: 1.5) {
                btn.tap()
                sleep(1)
                break
            }
        }

        XCTAssertTrue(app.buttons["tab.百宝箱"].waitForExistence(timeout: 12), "主界面未出现")
        let close = app.buttons["flashSale.close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
            sleep(1)
        }

        app.buttons["tab.百宝箱"].tap()
        XCTAssertTrue(app.buttons["tool.照片修复"].waitForExistence(timeout: 8), "百宝箱未出现")
        app.buttons["tool.照片修复"].tap()
        XCTAssertTrue(app.buttons["没有照片？试试示例照片"].waitForExistence(timeout: 8), "修复页未出现")
        app.buttons["没有照片？试试示例照片"].tap()
        XCTAssertTrue(app.buttons["开始修复"].waitForExistence(timeout: 8), "开始修复按钮未出现")
        app.buttons["开始修复"].tap()
        let paywall = app.staticTexts["会员权益"]
        XCTAssertTrue(paywall.waitForExistence(timeout: 6), "未订阅点开始修复应弹出订阅墙")
    }

    /// 指引详情页应展示原型整页长图（含红框+箭头标注）
    @MainActor
    func testGuideDetailShowsFullPrototypeImage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["允许完全访问", "Allow Full Access", "好", "OK"] {
            let btn = springboard.buttons[title]
            if btn.waitForExistence(timeout: 1.5) {
                btn.tap()
                sleep(1)
                break
            }
        }

        XCTAssertTrue(app.buttons["tab.百宝箱"].waitForExistence(timeout: 12), "主界面未出现")
        let close = app.buttons["flashSale.close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
            sleep(1)
        }

        app.buttons["tab.百宝箱"].tap()
        XCTAssertTrue(app.buttons["查看更多"].waitForExistence(timeout: 8), "百宝箱未出现")
        app.buttons["查看更多"].tap()
        XCTAssertTrue(app.buttons["guide.open.wechat"].waitForExistence(timeout: 8), "指引列表未出现")
        app.buttons["guide.open.wechat"].tap()
        XCTAssertTrue(app.staticTexts["微信清理指引"].waitForExistence(timeout: 8), "指引详情未出现")
        sleep(2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "guide_full_image_page"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
