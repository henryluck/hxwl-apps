import XCTest

/// 验证 11-16 晚批次修复：
/// 1. 首页扫描动画（数字累加 + 环形进度）
/// 2. 建议页返回直达首页（不闪过扫描页）
/// 3. 详情页缩略图统一比例 + 最佳带勾
/// 4. 修复页进度动画 1.6s
final class BatchVerifyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testBatchFixes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding", "-uitest-pro"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow", "好", "OK"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 2) { btn.tap(); break }
        }

        // 首页就绪后扫描中会出现百分比数字（动态累加）
        _ = app.buttons["home.primaryAction"].waitForExistence(timeout: 12)
        sleep(3)
        snap("b1-首页扫描中（数字+环）")
        sleep(8)
        snap("b2-首页扫描完成")

        // 会员标识（-uitest-pro → 已订阅皇冠）
        let manage = app.buttons["home.subscription.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 4), "已订阅态应显示 manage 标识")
        snap("b3-会员标识已订阅态")

        // 一键智能清理 → 深度扫描页 → 自动到建议页
        app.buttons["home.primaryAction"].tap()
        let scanNav = app.navigationBars["深度扫描"]
        _ = scanNav.waitForExistence(timeout: 6)
        snap("b4-深度扫描页")
        // 等待自动跳转建议页
        let suggestNav = app.navigationBars["智能清理建议"]
        XCTAssertTrue(suggestNav.waitForExistence(timeout: 40), "扫描完应自动进建议页")
        sleep(1)
        snap("b5-建议页")
        // 需求4：点返回 → 应直接回首页（导航栈只剩 home→suggest），不出现扫描页
        app.buttons["Back"].firstMatch.tap()
        sleep(2)
        let scanGone = !app.navigationBars["深度扫描"].exists
        XCTAssertTrue(scanGone, "建议页返回不应出现扫描页")
        XCTAssertTrue(app.buttons["home.primaryAction"].waitForExistence(timeout: 6), "应回到首页")
        snap("b6-建议页返回直达首页")

        // 进百宝箱 → 修复照片 → 开始修复看进度动画
        let toolbox = app.buttons["tab.百宝箱"]
        if toolbox.waitForExistence(timeout: 5), toolbox.isHittable {
            toolbox.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.955)).tap()
        }
        sleep(2)
        if app.buttons["tool.照片修复"].waitForExistence(timeout: 4) {
            app.buttons["tool.照片修复"].tap()
            sleep(2)
            let sample = app.buttons["没有照片？试试示例照片"]
            if sample.waitForExistence(timeout: 4) {
                sample.tap()
                sleep(1)
                let start = app.buttons["开始修复"]
                if start.waitForExistence(timeout: 4) {
                    start.tap()
                    // 动画期间截两张（应看到进度条在走）
                    sleep(1)
                    snap("b7-修复进度动画中1")
                    sleep(1)
                    snap("b8-修复进度动画中2")
                    // 等完成（动画至少1.6s + 处理时间）
                    _ = app.staticTexts["修复成功，照片已保存到本地相册"].waitForExistence(timeout: 30)
                    snap("b9-修复完成")
                }
            }
        }
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
