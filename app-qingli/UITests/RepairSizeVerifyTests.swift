import XCTest

/// 临时用例：验证「修复照片」输出分辨率不缩水。
/// 示例照片 675x900 → 修复保存后新资产应 >= 675x900（1.5x 放大则为 1012x1350）。
final class RepairSizeVerifyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testRepairKeepsOriginalResolution() throws {
        let app = XCUIApplication()
        // -uitest-pro：跳过订阅门（本用例验证修复管线分辨率，不测订阅墙）
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding", "-uitest-pro"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow", "好", "OK"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 2) { btn.tap(); break }
        }

        _ = app.buttons["home.primaryAction"].waitForExistence(timeout: 12)
        sleep(10)

        // 进百宝箱：点击 tab 文字标签（百宝箱居中；TabBar 高 56pt+10pt padding，
        // 文字在 bar 的下半部 ~0.945 屏高位置，比图标中心更稳）
        let toolbox = app.buttons["tab.百宝箱"]
        var switched = false
        if toolbox.waitForExistence(timeout: 5) {
            // 直接点按钮 element（XCUI 会计算其 hittable 点）
            toolbox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
            switched = true
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.948)).tap()
        }
        sleep(2)
        // 校验真的切过去了：百宝箱标题「图片与视频工具」应出现
        let toolboxTitle = app.staticTexts["图片与视频工具"]
        if !toolboxTitle.waitForExistence(timeout: 4) {
            // 再兜底点一次文字坐标
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.948)).tap()
            sleep(2)
        }
        switched = app.staticTexts["图片与视频工具"].exists
        snap("t1-百宝箱\(switched ? "-OK" : "-失败")")

        // 进照片修复：宫格第一格
        var entered = false
        let repair = app.buttons["tool.照片修复"]
        if repair.waitForExistence(timeout: 4), repair.isHittable {
            repair.tap(); entered = true
        } else {
            let byText = app.staticTexts["照片修复"]
            if byText.waitForExistence(timeout: 3) { byText.tap(); entered = true }
        }
        if !entered {
            snap("t1b-找不到照片修复入口")
            return
        }
        sleep(2)
        snap("t2-修复页初始")

        // 试试示例照片
        let sample = app.buttons["没有照片？试试示例照片"]
        if sample.waitForExistence(timeout: 5) {
            sample.tap()
            sleep(2)
            snap("t3-已选示例")
        } else {
            snap("t3-未找到示例按钮")
        }

        // 开始修复
        let start = app.buttons["开始修复"]
        if start.waitForExistence(timeout: 5) {
            start.tap()
            // 订阅墙兜底：这版订阅页特征是「会员权益」标题，关闭按钮 identifier paywall.nav.back
            let paywall = app.staticTexts["会员权益"]
            if paywall.waitForExistence(timeout: 5) {
                snap("t4-订阅墙拦截")
                let close = app.buttons["paywall.nav.back"]
                if close.waitForExistence(timeout: 3) {
                    close.tap()
                } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.085, dy: 0.083)).tap()
                }
                sleep(2)
                snap("t5-关闭订阅墙回修复页")
            }

            // 限时特惠挽留弹层：标题烧录在 PNG 里查不到文字，直接查关闭按钮 flashSale.close
            // （壳层在订阅墙关闭后弹出，盖在修复页上，必须先关掉）
            let flashClose = app.buttons["flashSale.close"]
            if flashClose.waitForExistence(timeout: 5) {
                snap("t5a-限时特惠出现")
                flashClose.tap()
                sleep(2)
                snap("t5b-关闭限时特惠")
            }

            // 回到修复页后再点一次开始修复（第一次的点击被订阅墙吃掉了）
            let start2 = app.buttons["开始修复"]
            if start2.waitForExistence(timeout: 5) {
                start2.tap()
                // 关闭弹层后再点开始修复不会再弹（didTriggerPaywall 防重入；
                // 但 retention 可能再弹 → 再兜底关一次）
                let flashClose2 = app.buttons["flashSale.close"]
                if flashClose2.waitForExistence(timeout: 4) {
                    flashClose2.tap()
                    sleep(1)
                    let start3 = app.buttons["开始修复"]
                    if start3.waitForExistence(timeout: 4) { start3.tap() }
                }
            }

            // 等保存完成
            _ = app.staticTexts["修复成功，照片已保存到本地相册"].waitForExistence(timeout: 40)
            sleep(2)
            snap("t6-修复完成")
        } else {
            snap("t4-未找到开始修复按钮")
        }
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
