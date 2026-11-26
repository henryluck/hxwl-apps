import XCTest

/// Bug表 R33 回归：锁屏实时活动卡片图标应为 App 真实图标（扫帚），不是 SF Symbol 色块。
///
/// 链路：走完引导授权照片 → 首页自动扫描 → 扫描发现可清理垃圾 →
/// CleanLiveActivityManager.showScanResult 启动 Live Activity → 锁屏显示卡片。
/// 卡片 UI 由 Widget 扩展（CleanLiveActivity.appex）在渲染进程绘制，
/// 图标加载三层来源：扩展 Assets.car 的 LiveActivityIcon → 宿主 AppIcon → 散资源 AppIcon.bin。
///
/// 验证方式：触发后锁屏截图留附件，人工/视觉比对图标是否为扫帚图。
/// 注意：不带任何 -uitest* 前缀参数（CleanHomeView 扫描回调里 -uitest* 会跳过 Live Activity 启动）。
final class LiveActivityIconTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveActivityShowsRealAppIcon() throws {
        let app = XCUIApplication()
        // 不加 -uitest* 参数：Live Activity 只在正常参数下启动。
        // 引导残留状态用 reset-onboarding 处理（该参数只在启动早期读，不影响 LA 链路）。
        // 等等——reset-onboarding 也带 -uitest 前缀。改为依赖模拟器已持久化的引导完成状态。
        app.launch()
        sleep(3)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // 0. 系统照片权限弹窗兜底
        tapSpringboardPermission(springboard)
        // App 内权限引导页（PermissionPrimer）的「允许完全访问」按钮
        let primerAllow = app.buttons["允许完全访问"]
        if primerAllow.waitForExistence(timeout: 4), primerAllow.isHittable {
            primerAllow.tap()
            sleep(1)
            tapSpringboardPermission(springboard)
        }
        // 引导页「下一步」推进（若残留引导未走完）
        var taps = 0
        while taps < 8 {
            let next = app.buttons["下一步"]
            guard next.waitForExistence(timeout: 2), next.isHittable else { break }
            next.tap()
            taps += 1
            sleep(2)
            tapSpringboardPermission(springboard)
            // 订阅墙出现即停（无 -uitest-no-paywall，会真的弹订阅墙）
            if app.staticTexts["会员权益"].exists { break }
        }
        attach(app, "LA-01-扫描前")

        // 1. 订阅墙兜底关闭（右上角✕）
        let paywallClose = app.buttons["closePaywall"]
        if paywallClose.waitForExistence(timeout: 4), paywallClose.isHittable {
            paywallClose.tap()
            sleep(1)
        } else {
            let xmark = app.buttons["✕"]
            if xmark.exists, xmark.isHittable { xmark.tap(); sleep(1) }
        }

        // 2. 首页自动扫描进行中；等扫描完成（按钮从「扫描中」变回可清理态）
        // 扫描完成且 totalCleanableBytes>0 → Live Activity 启动
        sleep(12)
        attach(app, "LA-02-扫描后")

        // 3. 锁屏验证卡片（新版 Xcode 无 homeButton API，用 springboard 休眠键模拟；
        //    失败时直接截 SpringBoard 当前画面兜底）
        lockScreenAndShoot(springboard)

        // 4. 解锁回 App，结束活动避免残留
        unlockScreen()
    }

    /// 系统照片权限弹窗（SpringBoard 层）兜底
    private func tapSpringboardPermission(_ springboard: XCUIApplication) {
        for title in ["允许完全访问", "Allow Full Access", "好", "OK"] {
            let btn = springboard.buttons[title]
            if btn.waitForExistence(timeout: 2), btn.isHittable {
                btn.tap()
                sleep(1)
                return
            }
        }
    }

    /// 锁屏并截图（等锁屏动画结束后从 SpringBoard 截）
    private func lockScreenAndShoot(_ springboard: XCUIApplication) {
        // iOS 17+ 模拟器：XCUIDevice 只剩 home/lock 等少数按钮；lock 在新版被移除，
        // 用 Siri 不可靠 → 直接用「菜单锁定」不可行时退化为不锁屏，
        // Live Activity 横幅在 App 前台时也会短暂显示，SpringBoard 截图兜底。
        if #available(iOS 17.0, *) {
            // press(.lock) 已不可用；改截当前 SpringBoard（可能有横幅）
        }
        sleep(1)
        let shot = XCTAttachment(screenshot: springboard.screenshot())
        shot.name = "LA-03-锁屏卡片"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func unlockScreen() {
        sleep(1)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
