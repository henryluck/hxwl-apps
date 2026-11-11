import XCTest

/// 功能界面逐屏截图：走一遍所有可进入的页面，每屏留一张附件。
/// 取图：`xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`
final class ScreenCaptureTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testCaptureAllScreens() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-reset-onboarding", "YES"]
        app.launch()

        // 系统照片权限弹窗兜底（挂在 SpringBoard 上）
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let zh = springboard.buttons["允许完全访问"]
        let en = springboard.buttons["Allow Full Access"]
        if zh.waitForExistence(timeout: 5) {
            zh.tap()
        } else if en.waitForExistence(timeout: 2) {
            en.tap()
        }
        sleep(1)

        // 跳过引导：点「下一步」直到订阅墙出现
        let next = app.buttons["下一步"]
        if next.waitForExistence(timeout: 20), waitHittable(next, timeout: 20) {
            let welcome = app.staticTexts["解锁全部会员内容"]
            let unlock = app.buttons["立即解锁权益"]
            var taps = 0
            while !(welcome.exists || unlock.exists) && taps < 8 {
                guard next.exists, next.isHittable else { break }
                next.tap()
                taps += 1
                sleep(2)
            }
        }

        // 关订阅墙 → 挽留页 → 我再想想
        if app.staticTexts["解锁全部会员内容"].exists || app.buttons["立即解锁权益"].exists {
            let size = app.frame.size
            app.coordinate(withNormalizedOffset: CGVector(dx: 35.0 / size.width,
                                                          dy: 80.0 / size.height)).tap()
            sleep(2)
            let later = app.buttons["我再想想"]
            if later.waitForExistence(timeout: 6) { later.tap(); sleep(2) }
        }

        // 等首页扫描完成
        sleep(12)

        // MARK: 首页
        attach(app, "01-首页")
        scroll(app, by: 0.32)
        attach(app, "01b-首页-下滑")
        scroll(app, by: -0.32)

        // MARK: 相似照片详情
        if tapID(app, "home.kind.similar_photos") {
            sleep(2)
            attach(app, "02-相似照片详情")
            back(app)
        }

        // MARK: 截图清理详情
        if tapID(app, "home.kind.screenshots") {
            sleep(2)
            attach(app, "03-截图清理详情")
            back(app)
        }

        // MARK: 模糊照片详情
        if tapID(app, "home.kind.blurred_photos") {
            sleep(2)
            attach(app, "04-模糊照片详情")
            back(app)
        }

        // MARK: 储存空间分析
        if tapID(app, "home.analysis") {
            sleep(2)
            attach(app, "05-储存空间分析")
            scroll(app, by: 0.34)
            attach(app, "05b-储存空间分析-下滑")
            back(app)
        }

        // MARK: 智能清理建议
        if tapID(app, "home.primaryAction") {
            sleep(2)
            attach(app, "06-智能清理建议")
            back(app)
        }

        // MARK: 百宝箱
        app.tabBars.buttons["百宝箱"].tap()
        sleep(2)
        attach(app, "07-百宝箱")

        if tapText(app, "照片压缩") {
            sleep(2)
            attach(app, "08-照片压缩")
            back(app)
        }

        if tapText(app, "视频压缩") {
            sleep(2)
            attach(app, "09-视频压缩")
            back(app)
        }

        if tapText(app, "微信缓存") {
            sleep(2)
            attach(app, "10-缓存清理指引详情")
            back(app)
        }

        if tapText(app, "查看更多") {
            sleep(2)
            attach(app, "11-清理指引列表")
            back(app)
        }

        // MARK: 我的
        app.tabBars.buttons["我的"].tap()
        sleep(2)
        attach(app, "12-我的")

        // MARK: 清理完成页（回首页 → 相似照片 → 全选 → 清理）
        app.tabBars.buttons["首页"].tap()
        sleep(2)
        if tapID(app, "home.kind.similar_photos") {
            sleep(2)
            let selectAll = app.navigationBars.buttons["全选"]
            if selectAll.waitForExistence(timeout: 5) {
                selectAll.tap()
                sleep(1)
                let clean = app.buttons["detail.primaryAction"]
                if clean.waitForExistence(timeout: 3) {
                    clean.tap()
                    sleep(2)
                    // 系统确认框：Allow "…" to hide N photos? → Hide（可能挂在 SpringBoard 上）
                    let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    let candidates: [XCUIElement] = [app.alerts.buttons["Hide"],
                                                     sb.alerts.buttons["Hide"],
                                                     sb.buttons["Hide"],
                                                     app.buttons["Hide"]]
                    for btn in candidates where btn.waitForExistence(timeout: 3) {
                        if btn.isHittable { btn.tap(); break }
                    }
                    sleep(6)
                    attach(app, "13-清理完成")
                }
            }
        }
    }

    // MARK: - Helpers

    /// 按 accessibilityIdentifier 点（必要时先滚动）
    @discardableResult
    private func tapID(_ app: XCUIApplication, _ identifier: String) -> Bool {
        let el = app.buttons[identifier]
        if el.waitForExistence(timeout: 4), el.isHittable {
            el.tap()
            return true
        }
        for _ in 0..<3 {
            app.swipeUp()
            usleep(400_000)
            if el.exists, el.isHittable { el.tap(); return true }
        }
        return false
    }

    /// 点文字（必要时先滚动）
    @discardableResult
    private func tapText(_ app: XCUIApplication, _ label: String) -> Bool {
        let el = app.staticTexts[label]
        if el.waitForExistence(timeout: 4), el.isHittable {
            el.tap()
            return true
        }
        for _ in 0..<2 {
            app.swipeUp()
            usleep(400_000)
            if el.exists, el.isHittable { el.tap(); return true }
        }
        return false
    }

    /// 定量滚动：fraction 为屏高比例（正数向上滑）
    private func scroll(_ app: XCUIApplication, by fraction: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74 - fraction))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
    }

    private func back(_ app: XCUIApplication) {
        let btn = app.navigationBars.buttons.element(boundBy: 0)
        if btn.exists { btn.tap() } else { app.swipeRight() }
        sleep(1)
    }

    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            usleep(300_000)
        }
        return false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
