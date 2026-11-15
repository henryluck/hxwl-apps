import XCTest

/// 临时用例：截取「相似照片详情页（每组独立日期卡）」多屏截图供人工核对。
/// 运行：xcodebuild test -project FactoryCoreSim.xcodeproj -scheme FactoryCoreSim
///       -only-testing:FactoryCoreSimUITests/SimilarityScreenshotTests ...
final class SimilarityScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureSimilarityDetail() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding"]
        app.launch()

        // 系统弹窗兜底（通知/照片权限，可能挂在 SpringBoard）
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow", "好", "OK"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 2) { btn.tap(); break }
        }
        for ident in ["允许", "Allow"] {
            let btn = app.alerts.buttons[ident]
            if btn.waitForExistence(timeout: 2) { btn.tap(); break }
        }

        // 等首页扫描完成（主按钮出现即可点）
        let primary = app.buttons["home.primaryAction"]
        _ = primary.waitForExistence(timeout: 12)
        sleep(12)

        // 进入相似照片详情
        let cell = app.buttons["home.kind.similar_photos"]
        guard cell.waitForExistence(timeout: 6) else {
            attach(name: "00-首页(无相似入口)")
            return
        }
        cell.tap()
        sleep(3)
        attach(name: "01-相似照片详情-顶部")
        app.swipeUp()
        sleep(1)
        attach(name: "02-相似照片详情-中部")
        app.swipeUp()
        sleep(1)
        attach(name: "03-相似照片详情-底部")
    }

    private func attach(name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
