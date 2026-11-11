import XCTest

/// 截屏辅助：把 App 各页面截图导出到 xcresult 附件，用于与 Figma 原型对照。
/// 运行：xcodebuild test -project FactoryCoreSim.xcodeproj -scheme FactoryCoreSim
///       -only-testing:FactoryCoreUITests/ProtoScreenCaptureTests ...
final class ProtoScreenCaptureTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    private func launchApp(skipOnboarding: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding"]
        app.launch()
        // 系统照片权限弹窗（SpringBoard 层）兜底
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let zh = springboard.buttons["允许完全访问"]
        let en = springboard.buttons["Allow Full Access"]
        if zh.waitForExistence(timeout: 4) {
            zh.tap()
            sleep(1)
        } else if en.waitForExistence(timeout: 2) {
            en.tap()
            sleep(1)
        }
        _ = app.buttons["home.primaryAction"].waitForExistence(timeout: 6)
        return app
    }

    private func snap(_ name: String) {
        let full = ProcessInfo.processInfo.environment["SIMULATOR_SScreenshots"] ?? name
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 个人中心 Tab（原型《个人中心-包含底部tab菜单》对照）
    @MainActor
    func testCaptureProfile() throws {
        let app = launchApp()
        sleep(2)
        openProfileTab(app)
        sleep(2)
        snap("proto_profile_tab")
    }

    /// 自绘 TabBar 按钮（无系统 tabBars 容器，用 accessibilityIdentifier 定位）
    @MainActor
    private func openProfileTab(_ app: XCUIApplication) {
        let btn = app.buttons["tab.个人中心"]
        if btn.waitForExistence(timeout: 3) {
            btn.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.833, dy: 0.955)).tap()
        }
        sleep(1)
    }

    /// 订阅墙（原型《首购订阅页面》对照）——跳过引导后从个人中心「开通会员」进入
    @MainActor
    func testCapturePaywall() throws {
        let app = launchApp()
        openProfileTab(app)
        sleep(1)
        // 未订阅态 → 会员卡「开通会员」按钮可见
        let openBtn = app.buttons["开通会员"]
        if openBtn.waitForExistence(timeout: 4) {
            openBtn.tap()
            sleep(2)
            snap("proto_paywall_first")
        } else {
            snap("proto_paywall_button_missing")
        }
    }

    /// 限时特惠弹页（原型《限时特惠页面》对照）：关掉订阅墙后弹出
    @MainActor
    func testCaptureFlashSale() throws {
        let app = launchApp()
        openProfileTab(app)
        sleep(1)
        if app.buttons["开通会员"].waitForExistence(timeout: 4) {
            app.buttons["开通会员"].tap()
            sleep(2)
            // 关闭订阅墙（左上 ✕ 无 accessibility，点坐标兜底）→ 挽留页（限时特惠）弹出
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.075)).tap()
            sleep(2)
            snap("proto_flash_sale")
        }
    }
}
