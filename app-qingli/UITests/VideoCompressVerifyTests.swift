import XCTest

/// 临时用例：验证「视频压缩」完成页显示压缩后的视频预览（播放器）而非静态图。
/// 流程：百宝箱 → 视频压缩 → 选刚导入的视频 → 开始压缩（-uitest-pro 跳订阅门）
/// → 完成页截图（应出现 VideoPlayer 而非 AssetThumb 静态网格）。
final class VideoCompressVerifyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testVideoCompressShowsPlayer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding", "-uitest-pro"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow", "好", "OK"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 2) { btn.tap(); break }
        }

        _ = app.buttons["home.primaryAction"].waitForExistence(timeout: 12)
        sleep(10)

        // 进百宝箱
        let toolbox = app.buttons["tab.百宝箱"]
        if toolbox.waitForExistence(timeout: 5) {
            toolbox.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.948)).tap()
        }
        sleep(2)
        let toolboxTitle = app.staticTexts["图片与视频工具"]
        if !toolboxTitle.waitForExistence(timeout: 4) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.948)).tap()
            sleep(2)
        }
        snap("t1-百宝箱")

        // 进视频压缩
        var entered = false
        let videoCell = app.buttons["tool.视频压缩"]
        if videoCell.waitForExistence(timeout: 4), videoCell.isHittable {
            videoCell.tap(); entered = true
        } else {
            let byText = app.staticTexts["视频压缩"]
            if byText.waitForExistence(timeout: 3) { byText.tap(); entered = true }
        }
        if !entered {
            snap("t1b-找不到视频压缩入口")
            return
        }
        sleep(2)
        snap("t2-视频压缩页")

        // 添加视频（PHPicker 系统面板：视频网格第一个单元格在左上角，
        // PHPicker 内容不在 accessibility 树的 cells 里 → 按坐标点击）
        let add = app.staticTexts["添加视频"]
        if add.waitForExistence(timeout: 4) {
            add.tap()
            sleep(3)
            snap("t3-选择器打开")
            // 点第一个视频缩略图（左上角，缩略图约 172x186pt → 中心 ≈ (0.22, 0.28)）
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.28)).tap()
            sleep(1)
            snap("t3c-已选中视频")
            // 点右上角 ✓ 确认（坐标 ≈ (0.88, 0.16)）
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.16)).tap()
            sleep(2)
        }
        snap("t4-已选视频")

        // 开始压缩
        let start = app.buttons["开始压缩"]
        if start.waitForExistence(timeout: 5) {
            start.tap()
            // 视频转码耗时较长，等待完成页出现（「压缩完成」标题）
            _ = app.staticTexts["压缩完成"].waitForExistence(timeout: 90)
            sleep(4)   // 给播放器加载时间
            snap("t5-视频压缩完成页")
        } else {
            snap("t4b-未找到开始压缩按钮")
        }
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
