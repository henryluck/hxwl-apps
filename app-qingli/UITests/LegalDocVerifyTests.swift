import XCTest

/// 验证协议/隐私政策：URL 内容加载 + 缓存离线兜底
final class LegalDocVerifyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testLegalDocLoadsRemoteContent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow", "好", "OK"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 2) { btn.tap(); break }
        }
        _ = app.buttons["home.primaryAction"].waitForExistence(timeout: 12)
        sleep(6)

        // 进个人中心
        let profile = app.buttons["tab.个人中心"]
        if profile.waitForExistence(timeout: 5), profile.isHittable {
            profile.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.955)).tap()
        }
        sleep(2)

        // 点「用户协议」行（settings.用户协议 identifier）
        let terms = app.buttons["settings.用户协议"]
        if !terms.waitForExistence(timeout: 4) {
            // 向下滚动找到
            app.swipeUp()
            sleep(1)
        }
        let termsRow = app.buttons["settings.用户协议"]
        if termsRow.waitForExistence(timeout: 4) {
            termsRow.tap()
            sleep(5)   // 等远程内容加载 + 无感刷新
            snap("l1-用户协议在线内容")
            // 远程页特征文案（terms.html 标题「垃圾清理助手用户服务协议」正文出现）
            let hasRemote = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '服务协议'")).firstMatch.exists
                         || app.webViews.firstMatch.exists
            XCTAssertTrue(hasRemote, "应展示远程协议内容（WebView 或特征文案）")
            // 关闭
            let close = app.buttons["关闭"]
            if close.waitForExistence(timeout: 3) { close.tap() }
            sleep(1)
        }

        // 点「隐私政策」
        let privacy = app.buttons["settings.隐私政策"]
        if privacy.waitForExistence(timeout: 4) {
            privacy.tap()
            sleep(5)
            snap("l2-隐私政策在线内容")
            let close = app.buttons["关闭"]
            if close.waitForExistence(timeout: 3) { close.tap() }
            sleep(1)
        }
    }

    /// 缓存文件验证：协议页打开后 Documents/LegalCache/<kind>.html 应已落盘
    @MainActor
    func testLegalCacheFileWritten() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding"]
        app.launch()
        _ = app.buttons["home.primaryAction"].waitForExistence(timeout: 12)
        sleep(5)

        let profile = app.buttons["tab.个人中心"]
        if profile.waitForExistence(timeout: 5), profile.isHittable {
            profile.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.83, dy: 0.955)).tap()
        }
        sleep(2)
        let termsRow = app.buttons["settings.用户协议"]
        if !termsRow.waitForExistence(timeout: 4) { app.swipeUp(); sleep(1) }
        if termsRow.waitForExistence(timeout: 4) {
            termsRow.tap()
            sleep(6)   // 等远程拉取 + 缓存写入
            snap("c1-协议已打开")
        }
        // 断言在 shell 侧做（容器路径运行时才知道）；这里只保证流程走到
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
