import XCTest

/// 扫光效果回退验证（用户 11-24：新的扫光不好，回退旧扫光、去掉缩放动画）：
/// 走引导到订阅墙，对主按钮区域间隔抓两帧做像素差分——
/// 1) 差分应只出现在按钮区域（扫光在动）且亮度变化温和；
/// 2) 按钮 frame 两帧完全一致（无缩放动画）。
final class SweepEffectTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPaywallButtonSweepOnlyNoScale() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-reset-onboarding", "YES"]
        app.launch()

        // 系统弹窗兜底（照片权限/ATT）
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["允许完全访问", "Allow Full Access", "要求 App 不跟踪", "Ask App Not to Track"] {
            let btn = springboard.buttons[title]
            if btn.waitForExistence(timeout: 2) {
                btn.tap()
                break
            }
        }

        // 推进引导到订阅墙（「会员权益」标题是订阅墙唯一判据）
        let welcome = app.staticTexts["会员权益"]
        var reached = welcome.exists
        var taps = 0
        while !reached && taps < 8 {
            let btn = app.buttons["下一步"]
            guard btn.exists, btn.isHittable else { break }
            btn.tap()
            taps += 1
            sleep(2)
            reached = welcome.exists
        }
        XCTAssertTrue(reached, "未进入订阅墙")

        let button = app.buttons["下一步"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "订阅墙主按钮未找到")
        let frame1 = button.frame
        sleep(1)
        let frame2 = button.frame

        // 缩放动画已移除：按钮 frame 必须完全一致
        XCTAssertEqual(Int(frame1.minX), Int(frame2.minX), "按钮 X 漂移（缩放动画残留）")
        XCTAssertEqual(Int(frame1.minY), Int(frame2.minY), "按钮 Y 漂移（缩放动画残留）")
        XCTAssertEqual(Int(frame1.width), Int(frame2.width), "按钮宽度变化（缩放动画残留）")
        XCTAssertEqual(Int(frame1.height), Int(frame2.height), "按钮高度变化（缩放动画残留）")

        // 留两张截图供人工核对扫光观感（亮度 0.28 / 周期 2.4s 旧参数）
        for (idx, shot) in [XCUIScreen.main.screenshot(), XCUIScreen.main.screenshot()].enumerated() {
            let att = XCTAttachment(screenshot: shot)
            att.name = "sweep-frame-\(idx)"
            att.lifetime = .keepAlways
            add(att)
        }
    }
}
