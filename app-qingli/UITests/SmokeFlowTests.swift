import XCTest

/// 冒烟链路：开机图/视频 → 引导页×3 → 订阅墙 → 挽留页 → 主界面（首页 + 我的）
/// 每屏留一张截图附件，用 `xcrun xcresulttool export attachments` 取出来看。
///
/// 两个坑（实测踩到）：
/// 1. 开机图/视频是 ZStack 覆盖层，不会把底下的引导页移出无障碍树 ——「按钮存在」不等于
///    「按钮可点」，必须等 isHittable，否则点击打在视频层上。
/// 2. 视频淡出（0.4s transition）期间，覆盖层仍在响应触摸，紧接的第一下点击会被吃掉。
///    所以这里不盲点固定次数，改成「点一次、验一次」，直到订阅墙真的出现。
final class SmokeFlowTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOnboardingToMainTabs() throws {
        let app = XCUIApplication()
        // 强制重走开机流程：跳过历史引导状态（上次运行残留的 UserDefaults）
        app.launchArguments += ["-uitest-reset-onboarding", "YES"]
        app.launch()

        // 0. 系统照片权限弹窗兜底（首页扫描触发；挂在 SpringBoard 上，需跨应用查询）
        springboardTapPermissionButton()

        // 1. 开机图（图停 1.5s）
        sleep(1)
        attach(app, "01-开机图")

        // 2. 等开机序列结束、引导页真正可点
        let next = app.buttons["下一步"]
        XCTAssertTrue(next.waitForExistence(timeout: 20), "引导页未出现")
        XCTAssertTrue(waitHittable(next, timeout: 20), "开机序列未结束，「下一步」始终不可点")
        sleep(1)
        attach(app, "02-引导页1")

        // 3. 逐页推进：每点一次截图验证，直到订阅墙出现（容忍淡出期吃掉的点击）
        let welcome = app.staticTexts["解锁全部会员内容"]
        let unlock = app.buttons["立即解锁权益"]
        var reachedPaywall = welcome.exists || unlock.exists
        var page = 1
        var taps = 0
        while !reachedPaywall && taps < 8 {
            let btn = app.buttons["下一步"]
            guard btn.exists, btn.isHittable else { break }
            btn.tap()
            taps += 1
            sleep(2)
            reachedPaywall = welcome.exists || unlock.exists
            if !reachedPaywall {
                page += 1
                attach(app, String(format: "03-引导页%d(第%d次点击后)", page, taps))
            }
        }
        XCTAssertTrue(reachedPaywall, "点了 \(taps) 次仍未进入订阅墙（引导页没走完）")
        attach(app, "04-订阅墙")

        // 4. 关闭订阅墙（左上角 ✕ 无文本标签，按坐标点）
        let size = app.frame.size
        app.coordinate(withNormalizedOffset: CGVector(dx: 35.0 / size.width,
                                                      dy: 80.0 / size.height)).tap()
        sleep(3)
        attach(app, "05-挽留页")

        // 5. 挽留页「我再想想」→ 进主界面
        let later = app.buttons["我再想想"]
        if later.waitForExistence(timeout: 6) {
            later.tap()
            sleep(3)
        }
        attach(app, "06-主界面-首页")

        let homeTab = app.tabBars.buttons["首页"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10), "主界面缺少首页 Tab")

        // 6. 切到「我的」
        app.tabBars.buttons["我的"].tap()
        sleep(2)
        attach(app, "07-主界面-我的")
    }

    /// 轮询直到元素可命中（被覆盖层盖住时 isHittable = false）
    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            usleep(300_000)
        }
        return false
    }

    /// 系统照片权限弹窗（SpringBoard 层）兜底：尝试点「允许完全访问 / Allow Full Access」
    private func springboardTapPermissionButton() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let zh = springboard.buttons["允许完全访问"]
        let en = springboard.buttons["Allow Full Access"]
        if zh.waitForExistence(timeout: 4) {
            zh.tap()
        } else if en.waitForExistence(timeout: 2) {
            en.tap()
        }
        sleep(1)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
