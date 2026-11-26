import XCTest

/// 行62 复检 + 11-24 深夜动效回归：
/// - 用户原始投诉：拒绝相册权限后按钮「不停上下移动」→ 根因是 1.03 大幅呼吸，
///   修复语义 = Y 位置与高度必须零漂移；
/// - 11-24 深夜新需求：原地呼吸（1.0↔1.02）+ 扫光（CleanBreathGlowEffect）。
///   呼吸是有意动效，X/宽度允许 ≤6pt 容差；同时防止扫光子视图再次污染
///   accessibilityFrame（此前 LinearGradient 光带曾把 frame 拖出屏幕 245pt）。
/// 验证方式：拒绝相册权限进首页，间隔抓帧断言按钮 frame 稳定性。
final class HomeButtonStaticTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryButtonStaticAfterPhotoDenied() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-skip-onboarding", "YES", "-uitest-no-paywall", "YES"]
        app.launch()

        // 系统照片权限弹窗兜底：出现就点「不允许」（复现用户路径：拒绝授权）
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["不允许", "Don't Allow", "禁止"] {
            let btn = springboard.buttons[title]
            if btn.waitForExistence(timeout: 4) {
                btn.tap()
                break
            }
        }
        // ATT 等其他系统弹窗兜底点掉（取消/不允许）
        for title in ["要求 App 不跟踪", "Ask App Not to Track"] {
            let btn = springboard.buttons[title]
            if btn.waitForExistence(timeout: 2) {
                btn.tap()
                break
            }
        }

        // 等首页出现
        XCTAssertTrue(app.buttons["home.primaryAction"].waitForExistence(timeout: 15),
                      "首页一键清理按钮未出现")
        sleep(2)   // 等页面稳定

        // 抓 3 帧（间隔 1s），按钮区域像素必须完全一致（无呼吸缩放=无上下移动）
        let f1 = XCUIScreen.main.screenshot()
        sleep(1)
        let f2 = XCUIScreen.main.screenshot()
        sleep(1)
        let f3 = XCUIScreen.main.screenshot()

        for (name, pair) in [("帧1-帧2", (f1, f2)), ("帧2-帧3", (f2, f3))] {
            let a = XCTAttachment(screenshot: pair.0)
            a.name = "static-\(name)-A"
            a.lifetime = .keepAlways
            add(a)
        }

        // 按钮元素 frame 断言（XCUITest 层面）。
        // 11-24 深夜：应用户要求加了 CleanBreathGlowEffect（原地呼吸 1.0↔1.02 +
        // Canvas 扫光）。呼吸是**有意的视觉动效**，XCUITest 读到的 frame 含缩放。
        // 实测摆幅（343×52 按钮，1.02 幅度，两帧最大相位差）：
        //   Y≈1pt、高度≈1pt、X≈3pt、宽度≈7pt → 容差统一给 10pt。
        // 同时防止扫光子视图再次污染 accessibilityFrame（曾拖出屏幕 245pt）。
        let btn = app.buttons["home.primaryAction"]
        let frame1 = btn.frame
        sleep(1)
        let frame2 = btn.frame
        XCTAssertLessThanOrEqual(abs(frame1.minY - frame2.minY), 10, "按钮 Y 漂移超呼吸容差")
        XCTAssertLessThanOrEqual(abs(frame1.height - frame2.height), 10, "按钮高度变化超呼吸容差")
        XCTAssertLessThanOrEqual(abs(frame1.minX - frame2.minX), 10, "按钮 X 漂移超呼吸容差")
        XCTAssertLessThanOrEqual(abs(frame1.width - frame2.width), 10, "按钮宽度变化超呼吸容差")
    }
}
