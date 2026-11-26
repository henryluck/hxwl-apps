import XCTest

/// 11-26 首启振荡回归（用户反馈：只有**新安装第一次打开**才复现按钮大幅上下移动）：
/// 根因链 = 全新安装走完引导时 ShellRootView 用 `withAnimation(.easeInOut(0.25))`
/// 切换 finishedOnboarding → mainTabs 插入动画事务中，CleanBreathGlowEffect 的
/// `onAppear { pulsing = true }` 同时翻转，`.animation(.repeatForever, value:)`
/// 把按钮在首帧布局中产生的 position 差捕获为永久振荡（幅度 ≈ 健康度行高，
/// 与用户截图「按钮顶出卡片盖住分数行」吻合）。
/// 修复 = 无权限态 `.none` 分支不挂任何 `.animation` 修饰符。
/// 本测试复现真实路径：**引导页走完（withAnimation 事务）→ 拒绝权限态首页**，
/// 抓帧断言按钮 frame 零漂移。旧测试 `-uitest-skip-onboarding` 跳过了引导，
/// 从未覆盖到这条事务，故此前测试全绿但用户真机仍复现。
final class FreshLaunchButtonStaticTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testButtonStaticAfterOnboardingFinish() throws {
        let app = XCUIApplication()
        // -uitest-reset-onboarding：重放引导（等价新装首启的引导→主界面切换事务）
        // 注意：**不带** -uitest-skip-onboarding / -uitest-no-paywall，
        // 否则会跳过 withAnimation 事务，复现不了用户路径。
        app.launchArguments += ["-uitest-reset-onboarding"]
        app.launch()

        // 逐页点「下一步」（3 页），进入末页订阅墙
        let close = app.buttons["paywall.nav.back"]
        var guardCount = 0
        while !close.exists && guardCount < 8 {
            let next = app.buttons.matching(NSPredicate(format: "label == '下一步'")).firstMatch
            if next.waitForExistence(timeout: 3) {
                next.tap()
                usleep(600_000)   // 等页间过渡
            }
            guardCount += 1
        }
        XCTAssertTrue(close.waitForExistence(timeout: 10), "引导末页订阅墙未出现")
        // 关闭订阅墙 → withAnimation(.easeInOut) 切主界面（复现关键事务）
        close.tap()

        // 拒绝权限路径（simctl privacy revoke photos 已在运行前置为拒绝/未决定）
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["不允许", "Don't Allow", "禁止"] {
            let btn = springboard.buttons[title]
            if btn.waitForExistence(timeout: 3) {
                btn.tap()
                break
            }
        }

        XCTAssertTrue(app.buttons["home.primaryAction"].waitForExistence(timeout: 15),
                      "首页主按钮未出现（无权限态应为「去开启相册权限」）")
        sleep(2)   // 等扫描指示器↔内容切换稳定

        let btn = app.buttons["home.primaryAction"]
        // .none 模式无任何动画 → frame 必须严格零漂移（容差 1pt 防取帧抖动）
        var frames: [CGRect] = []
        for _ in 0..<8 {
            frames.append(btn.frame)
            usleep(400_000)   // 覆盖 >1.2s 呼吸周期 + 2.4s 扫光周期的多相位采样
        }
        for i in 1..<frames.count {
            XCTAssertLessThanOrEqual(abs(frames[i].minY - frames[0].minY), 1,
                                     "第\(i)帧按钮 Y 漂移 \(abs(frames[i].minY - frames[0].minY))pt——首启振荡复现！")
            XCTAssertLessThanOrEqual(abs(frames[i].height - frames[0].height), 1,
                                     "第\(i)帧按钮高度变化超容差")
            XCTAssertLessThanOrEqual(abs(frames[i].minX - frames[0].minX), 1,
                                     "第\(i)帧按钮 X 漂移超容差")
            XCTAssertLessThanOrEqual(abs(frames[i].width - frames[0].width), 1,
                                     "第\(i)帧按钮宽度变化超容差")
        }

        // 附加：后台→回前台，触发 scenePhase 重扫路径后再次采帧
        XCUIDevice.shared.press(XCUIDevice.Button.home)
        sleep(1)
        app.activate()
        XCTAssertTrue(app.buttons["home.primaryAction"].waitForExistence(timeout: 10))
        sleep(3)   // 等重扫完成/内容稳定
        let f2 = btn.frame
        XCTAssertLessThanOrEqual(abs(f2.minY - frames[0].minY), 1,
                                 "回前台后按钮 Y 漂移——重扫路径振荡复现！")
        XCTAssertLessThanOrEqual(abs(f2.height - frames[0].height), 1,
                                 "回前台后按钮高度变化超容差")
    }
}
