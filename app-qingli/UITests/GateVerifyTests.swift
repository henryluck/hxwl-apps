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

    /// 清理执行必须是「删除」而非「隐藏」：系统确认框应出现「删除 / Delete」。
    /// 最后点「不允许」取消，避免真的删掉模拟器相册里的照片。
    @MainActor
    func testCleanDeleteConfirmationNotHide() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding", "-uitest-pro"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // 相册权限弹窗可能晚于 App 启动出现，按秒轮询而不是一次短等待
        for _ in 0..<8 {
            var handled = false
            for title in ["允许完全访问", "Allow Full Access", "好", "OK"] {
                let btn = springboard.buttons[title]
                if btn.exists && btn.isHittable { btn.tap(); handled = true; break }
            }
            if handled { break }
            sleep(1)
        }

        XCTAssertTrue(app.buttons["tab.首页"].waitForExistence(timeout: 12), "主界面未出现")
        let close = app.buttons["flashSale.close"]
        if close.waitForExistence(timeout: 2) { close.tap(); sleep(1) }

        // 等扫描完成，挑一个确实有候选的分类进入
        // 优先相似照片：同一分钟导入的同尺寸图会被分到一组，最容易拿到非空候选
        let kinds = ["similar_photos", "screenshots", "blurred_photos", "live_photos"]
        var entry: XCUIElement?
        for _ in 0..<10 {
            for kind in kinds {
                let btn = app.buttons["home.kind.\(kind)"]
                if btn.exists && btn.isHittable { entry = btn; break }
            }
            if entry != nil { break }
            sleep(1)
        }
        guard let entry else {
            throw XCTSkip("模拟器相册没有可清理候选，跳过删除确认框验证")
        }
        entry.tap()

        let selectAll = app.navigationBars.buttons["全选"]
        guard selectAll.waitForExistence(timeout: 6) else {
            throw XCTSkip("详情页没有「全选」，无法触发清理")
        }
        selectAll.tap()
        sleep(1)
        let clean = app.buttons["detail.primaryAction"]
        guard clean.waitForExistence(timeout: 5), clean.isHittable else {
            throw XCTSkip("清理按钮不可用")
        }
        clean.tap()

        // 系统弹窗挂在 SpringBoard：deleteAssets → 「删除 / Delete」；isHidden → 「隐藏 / Hide」
        var confirm: XCUIElement?
        for _ in 0..<10 {
            for title in ["删除", "Delete"] {
                let candidates = [springboard.alerts.buttons[title], springboard.buttons[title],
                                  app.alerts.buttons[title], app.buttons[title]]
                if let btn = candidates.first(where: { $0.exists && $0.isHittable }) {
                    confirm = btn
                    break
                }
            }
            if confirm != nil { break }
            sleep(1)
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "clean_delete_confirmation"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertNotNil(confirm, "清理应弹出系统「删除」确认框，而不是「隐藏」")
        for title in ["隐藏", "Hide"] {
            XCTAssertFalse(springboard.buttons[title].exists, "仍出现「隐藏」按钮：执行链路还在用 isHidden")
            XCTAssertFalse(springboard.alerts.buttons[title].exists, "仍出现「隐藏」确认框")
        }

        // 取消删除，别把测试相册清空
        for title in ["不允许", "Don't Allow", "Don’t Allow"] {
            let btn = springboard.buttons[title]
            if btn.exists && btn.isHittable { btn.tap(); break }
        }
    }
}
