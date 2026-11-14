import XCTest

/// 截屏辅助：把 App 各页面截图导出到 xcresult 附件，用于与 Figma 原型对照。
/// 运行：xcodebuild test -project FactoryCoreSim.xcodeproj -scheme FactoryCoreSim
///       -only-testing:FactoryCoreUITests/ProtoScreenCaptureTests ...
final class ProtoScreenCaptureTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    private func launchApp(skipOnboarding: Bool = true,
                           extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding"] + extraArgs
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

    /// 完成订阅页（素材《订阅成功.png》对照）：购买成功后整屏展示，替代原「订阅成功」弹窗。
    /// 真机购买走 StoreKit 无法在 UI 测试里触发，用启动参数直接呈现该页截屏。
    @MainActor
    func testCaptureSubscriptionSuccess() throws {
        let app = launchApp(extraArgs: ["-uitest-subscription-success"])
        XCTAssertTrue(app.buttons["subscribeSuccess.start"].waitForExistence(timeout: 6))
        sleep(1)
        snap("proto_subscription_success")
    }

    /// 已订阅页 + 续订弹窗（素材《已订阅.png》《续订.png》对照）：
    /// 个人中心「管理订阅」→ 应用内已订阅页 → 点「取消续费」→ 续订弹窗 → ✕ 关闭。
    @MainActor
    func testCaptureSubscribedAndRenewGuide() throws {
        let app = launchApp(extraArgs: ["-uitest-proto-subscribed"])
        openProfileTab(app)
        let manage = app.buttons["管理订阅"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()

        let cancel = app.buttons["subscribed.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        sleep(1)
        snap("proto_subscribed_page")

        cancel.tap()
        let guideClose = app.buttons["renewGuide.close"]
        XCTAssertTrue(guideClose.waitForExistence(timeout: 5))
        sleep(1)
        snap("proto_renew_guide")

        guideClose.tap()
        sleep(1)
        XCTAssertFalse(guideClose.exists)
        XCTAssertTrue(app.buttons["subscribed.continue"].exists)
    }

    /// 复购订阅页（原型《复购订阅页面》对照）：钩子强制无首期资格 → 显示 ¥48/周，无新人特惠角标
    @MainActor
    func testCapturePaywallRenewal() throws {
        let app = launchApp(extraArgs: ["-uitest-force-renewal"])
        openProfileTab(app)
        sleep(1)
        if app.buttons["开通会员"].waitForExistence(timeout: 4) {
            app.buttons["开通会员"].tap()
            sleep(2)
            snap("proto_paywall_renewal")
        } else {
            snap("proto_paywall_renewal_button_missing")
        }
    }

    /// 四个清理详情页布局回归：相似照片 / 截图清理 / 模糊照片 / 相似视频。
    /// 用于核对列表是否铺满可用高度、底部有无多余空白占位。
    @MainActor
    func testCaptureCleanDetailLayout() throws {
        let app = launchApp()
        sleep(5)   // 等首页扫描完成，缩略图稳定
        let pages: [(String, String)] = [
            ("home.kind.similar_photos", "detail_similar_photos"),
            ("home.kind.screenshots", "detail_screenshots"),
            ("home.kind.blurred_photos", "detail_blurred_photos"),
            ("home.kind.similar_videos", "detail_similar_videos"),
        ]
        for (id, name) in pages {
            let btn = app.buttons[id]
            var found = btn.waitForExistence(timeout: 4) && btn.isHittable
            for _ in 0..<3 where !found {
                app.swipeUp()
                usleep(400_000)
                found = btn.exists && btn.isHittable
            }
            guard found else { snap(name + "_not_found"); continue }
            btn.tap()
            sleep(2)
            snap(name)
            if id == "home.kind.similar_photos" {
                // 长列表滚到底：确认图片能一直铺到底部按钮栏，不再留空白带
                app.swipeUp(); app.swipeUp(); app.swipeUp()
                sleep(1)
                snap(name + "_bottom")
            }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() } else { app.swipeRight() }
            sleep(1)
        }
    }
}
