import XCTest

/// 本轮 5 点功能修复的 UI 回归。
///
/// 覆盖：
/// 1. 个人中心「意见反馈」→ 打开填写页，能输入内容并真实落库 / 在「我的反馈记录」里看到。
/// 2. 个人中心「关于我们」→ 打开关于页。
/// 3. 百宝箱「照片修复 / 照片抠图 / Live Photo转静态」分别进入各自页面，
///    不再统一跳「图片压缩」。
/// 4. 常用清理「查看更多」→「清理指引」→ 打开对应 App 的图文详情页。
/// 5. 工具页不是静态假页：用示例照片可以真实跑算法并产出结果。
///
/// 运行：
///   xcodebuild test -project FactoryCoreSim.xcodeproj -scheme FactoryCoreSim \
///     -configuration Debug -sdk iphonesimulator -derivedDataPath DerivedData-sim \
///     ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
///     -only-testing:FactoryCoreSimUITests/FeatureFlowTests \
///     -resultBundlePath TestResults-features.xcresult
final class FeatureFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 启动 / 通用工具

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // -uitest-pro：绕过订阅门（本用例测算法链路，非付费墙本身）
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding", "-uitest-pro"]
        app.launch()

        // 系统照片权限弹窗挂在 SpringBoard，需要跨应用查询
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["允许完全访问", "Allow Full Access", "好", "OK"] {
            let btn = springboard.buttons[title]
            if btn.waitForExistence(timeout: 1.5) {
                btn.tap()
                sleep(1)
                break
            }
        }

        XCTAssertTrue(app.buttons["tab.百宝箱"].waitForExistence(timeout: 12),
                      "主界面 TabBar 未出现（开机序列或订阅墙挡住了）")

        // 挽留/限时特惠浮层兜底：出现就关掉，避免吞点击
        let close = app.buttons["flashSale.close"]
        if close.waitForExistence(timeout: 2) {
            close.tap()
            sleep(1)
        }
        return app
    }

    @MainActor
    private func tap(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "未找到：\(label)")
        for _ in 0..<20 where !element.isHittable { usleep(150_000) }
        XCTAssertTrue(element.isHittable, "不可点击：\(label)")
        element.tap()
        sleep(1)
    }

    @MainActor
    private func assertExists(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 6) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "页面缺少：\(label)")
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - 1 + 2：个人中心两个入口

    @MainActor
    func testSettingsFeedbackAndAbout() throws {
        let app = launchApp()

        tap(app.buttons["tab.个人中心"], "个人中心 Tab")
        tap(app.buttons["settings.意见反馈"], "意见反馈行")

        // 原型 #214 自绘导航栏标题
        assertExists(app.staticTexts["意见反馈"], "意见反馈页标题")
        assertExists(app.staticTexts["请详细描述您的问题或建议"], "反馈表单")
        assertExists(app.buttons["feedback.submit"], "提交反馈按钮")
        snap("feature_feedback_page")

        let editor = app.textViews["feedback.content"]
        tap(editor, "反馈内容输入框")
        editor.typeText("扫描相似照片后无法一键清理，请帮忙看看")

        let contact = app.textFields["feedback.contact"]
        tap(contact, "联系方式输入框")
        contact.typeText("tester@example.com")

        // 键盘会盖住「提交反馈」：先收起键盘（App 提供了键盘工具栏「完成」）
        let done = app.buttons["feedback.keyboard.done"]
        if done.waitForExistence(timeout: 4) {
            done.tap()
            sleep(1)
        }
        if !app.buttons["feedback.submit"].isHittable {
            app.scrollViews.firstMatch.swipeUp()
            sleep(1)
        }

        tap(app.buttons["feedback.submit"], "提交反馈")

        // 模拟器无邮件账户 / 中台未配置时，诚实落本机并弹「反馈已收到」
        assertExists(app.alerts["反馈已收到"], "提交结果提示", timeout: 8)
        app.alerts["反馈已收到"].buttons.firstMatch.tap()
        sleep(1)

        // 反馈记录是真实持久化，不是弹完就没了
        tap(app.buttons["feedback.history"], "我的反馈记录")
        assertExists(app.staticTexts["我的反馈记录"], "反馈记录页标题")
        assertExists(app.staticTexts["扫描相似照片后无法一键清理，请帮忙看看"], "刚提交的反馈内容")
        assertExists(app.staticTexts["联系方式：tester@example.com"], "反馈联系方式")
        snap("feature_feedback_history")

        app.buttons["完成"].firstMatch.tap()
        sleep(1)
        tap(app.buttons["support.nav.back"], "意见反馈返回")

        // 关于我们（原型 #215）
        tap(app.buttons["settings.关于我们"], "关于我们行")
        assertExists(app.staticTexts["关于我们"], "关于我们页标题")
        assertExists(app.staticTexts["联系我们"], "关于我们联系入口")
        snap("feature_about_page")
    }

    // MARK: - 3 + 4 + 5：百宝箱工具页、清理指引、真实算法

    @MainActor
    func testToolboxRoutesGuidesAndRealProcessing() throws {
        let app = launchApp()
        tap(app.buttons["tab.百宝箱"], "百宝箱 Tab")
        assertExists(app.staticTexts["图片与视频工具"], "百宝箱页")

        // --- 3. 三个工具各自独立页面 ---
        tap(app.buttons["tool.照片修复"], "照片修复入口")
        assertExists(app.staticTexts["修复图片"], "修复图片页标题")
        XCTAssertFalse(app.staticTexts["图片压缩"].exists, "照片修复错误地跳到了图片压缩页")
        assertExists(app.buttons["选择照片 +"], "修复页选图按钮")
        snap("feature_photo_repair")
        tap(app.buttons["tool.nav.back"], "修复页返回")

        tap(app.buttons["tool.照片抠图"], "照片抠图入口")
        assertExists(app.staticTexts["照片抠图"], "照片抠图页标题")
        XCTAssertFalse(app.staticTexts["图片压缩"].exists, "照片抠图错误地跳到了图片压缩页")
        assertExists(app.buttons["选择照片 +"], "抠图页选图按钮")
        snap("feature_photo_cutout")
        tap(app.buttons["tool.nav.back"], "抠图页返回")

        tap(app.buttons["tool.Live Photo转静态"], "Live Photo转静态入口")
        assertExists(app.staticTexts["Live Photo转静态"], "Live Photo转静态页标题")
        XCTAssertFalse(app.staticTexts["图片压缩"].exists, "Live Photo 错误地跳到了图片压缩页")
        snap("feature_live_to_still")
        tap(app.buttons["tool.nav.back"], "Live 页返回")

        // --- 4. 查看更多 → 清理指引 → 详情 ---
        tap(app.buttons["查看更多"], "常用清理-查看更多")
        assertExists(app.buttons["guide.open.wechat"], "清理指引列表-微信行")
        tap(app.buttons["guide.open.wechat"], "微信清理指引行")
        assertExists(app.staticTexts["微信清理指引"], "微信指引详情标题")
        assertExists(app.buttons["打开微信"], "指引详情-打开微信动作")
        assertExists(app.buttons["完成，返回"], "指引详情完成按钮")
        snap("feature_guide_detail")
        tap(app.buttons["完成，返回"], "指引详情返回")
        assertExists(app.buttons["guide.open.qq"], "返回到清理指引列表")

        // --- 5. 工具页真实跑算法（不依赖相册内容） ---
        // 从列表返回百宝箱；列表是 NavigationStack push，用系统返回按钮
        let back = app.navigationBars.buttons.firstMatch
        if back.exists && back.isHittable { back.tap(); sleep(1) }

        tap(app.buttons["tool.照片修复"], "照片修复入口（算法验证）")
        tap(app.buttons["没有照片？试试示例照片"], "示例照片")
        assertExists(app.buttons["开始修复"], "开始修复按钮")
        tap(app.buttons["开始修复"], "开始修复")
        assertExists(app.buttons["对比原图"], "修复结果对比入口", timeout: 30)
        snap("feature_photo_repair_result")
    }
}
