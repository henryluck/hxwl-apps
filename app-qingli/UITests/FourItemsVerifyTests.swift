import XCTest

/// 验证 11-15 晚四项 UI 需求：
/// 1. 修复照片页：示例态与选照片后，图片/按钮位置完全一致
/// 2. 照片抠图页：同上
/// 3. 压缩页添加区域加大、加号居中
/// 4. 已订阅页文字原生渲染（文本元素可查询 = 非 位图烧录）
final class FourItemsVerifyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testToolLayoutConsistencyAndSubscribedNativeText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-reset-onboarding", "-uitest-skip-onboarding", "-uitest-pro"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow", "好", "OK"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 2) { btn.tap(); break }
        }

        _ = app.buttons["home.primaryAction"].waitForExistence(timeout: 12)
        sleep(8)

        // 需求4 前置：已订阅（-uitest-pro）点右上角会员图标 → 应弹「已订阅页」
        let subEntry = app.buttons["home.subscription.manage"]
        if subEntry.waitForExistence(timeout: 4) {
            subEntry.tap()
            let subscribedTitle = app.staticTexts["已成功订阅"]
            let isNative = subscribedTitle.waitForExistence(timeout: 6)
            XCTAssertTrue(isNative, "已订阅页标题应为原生文本（staticText 可查询）")
            snap(isNative ? "s1-已订阅页原生文本" : "s1-已订阅页异常")
            if isNative {
                let benefits = ["相似模糊截图清理", "照片修复 & 智能抠图", "图片 & 视频压缩", "全程本地，无限清理"]
                for b in benefits {
                    XCTAssertTrue(app.staticTexts[b].exists, "权益文字缺失（应为原生文本）：\(b)")
                }
                XCTAssertTrue(app.buttons["subscribed.continue"].exists, "继续优化按钮应存在")
                XCTAssertTrue(app.buttons["subscribed.cancel"].exists, "取消续费按钮应存在")
                XCTAssertTrue(app.buttons["subscribed.close"].exists, "✕ 关闭热区应存在")
                snap("s2-已订阅页权益明细")
                app.buttons["subscribed.close"].tap()
                sleep(2)
            }
        } else {
            snap("s0-会员入口未找到")
        }

        // 进百宝箱
        let toolbox = app.buttons["tab.百宝箱"]
        if toolbox.waitForExistence(timeout: 5), toolbox.isHittable {
            toolbox.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.955)).tap()
        }
        sleep(2)

        // ---- 需求1：修复照片页两态布局对比 ----
        if app.buttons["tool.照片修复"].waitForExistence(timeout: 4) {
            app.buttons["tool.照片修复"].tap()
            sleep(2)
            // 示例态：取底部按钮区首元素位置作为布局锚点
            let anchor0 = anchorFrame(app)
            snap("t1-修复页示例态")
            // 试试示例照片 → 进入选后态（original 非空，与示例态同布局帧）
            let sampleBtn = app.buttons["没有照片？试试示例照片"]
            if sampleBtn.waitForExistence(timeout: 4) {
                sampleBtn.tap()
                sleep(2)
                let anchor1 = anchorFrame(app)
                snap("t2-修复页选后态")
                // 图片位置：两态锚点（底部按钮区上沿）垂直位置完全一致
                if let a0 = anchor0, let a1 = anchor1 {
                    XCTAssertEqual(Int(a0.minY), Int(a1.minY),
                                   "修复页示例态与选后态按钮区位置应一致（\(Int(a0.minY)) vs \(Int(a1.minY))）")
                }
                // 按钮位置：主按钮（选择照片+ / 开始修复）水平中心与宽度一致
                let btn0 = app.buttons["选择照片 +"]
                let btn1 = app.buttons["开始修复"]
                if btn0.exists && btn1.exists {
                    XCTAssertEqual(Int(btn0.frame.midX), Int(btn1.frame.midX), "修复页主按钮水平中心应一致")
                    XCTAssertEqual(Int(btn0.frame.width), Int(btn1.frame.width), "修复页主按钮宽度应一致")
                }
                snap("t3-修复页按钮对比")
            }
            // 返回百宝箱
            app.buttons["tool.nav.back"].tap()
            sleep(1)
        }

        // ---- 需求2：抠图页同验证 ----
        if app.buttons["tool.照片抠图"].waitForExistence(timeout: 4) {
            app.buttons["tool.照片抠图"].tap()
            sleep(2)
            let anchor0 = anchorFrame(app)
            snap("u1-抠图页示例态")
            let sampleBtn = app.buttons["没有照片？试试示例照片"]
            if sampleBtn.waitForExistence(timeout: 4) {
                sampleBtn.tap()
                sleep(2)
                let anchor1 = anchorFrame(app)
                snap("u2-抠图页选后态")
                if let a0 = anchor0, let a1 = anchor1 {
                    XCTAssertEqual(Int(a0.minY), Int(a1.minY),
                                   "抠图页示例态与选后态按钮区位置应一致（\(Int(a0.minY)) vs \(Int(a1.minY))）")
                }
            }
            app.buttons["tool.nav.back"].tap()
            sleep(1)
        }

        // ---- 需求3：压缩页添加区域尺寸 ----
        if app.buttons["tool.照片压缩"].waitForExistence(timeout: 4) {
            app.buttons["tool.照片压缩"].tap()
            sleep(2)
            let add = app.buttons["compress.addPhoto"]
            if add.waitForExistence(timeout: 4) {
                let f = add.frame
                XCTAssertGreaterThan(f.height, 300, "添加照片区域高度应 >300pt（加大后）")
                snap("v1-压缩添加区（\(Int(f.width))x\(Int(f.height))）")
            }
        }
    }

    /// 布局锚点：底部按钮区第一个可见按钮（示例态=选择照片+；选后态=开始修复/开始抠图）的 frame
    private func anchorFrame(_ app: XCUIApplication) -> CGRect? {
        let sample = app.buttons["选择照片 +"]
        if sample.exists { return sample.frame }
        for title in ["开始修复", "开始抠图"] {
            let b = app.buttons[title]
            if b.exists { return b.frame }
        }
        return nil
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
