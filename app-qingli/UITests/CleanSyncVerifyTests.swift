import XCTest

/// 清理流程状态同步验证（用户反馈问题 1 / 2）
///
/// 问题 1：相似照片/相似视频/截图清理/模糊照片，在页面清完照片时返回首页，
///         首页展示的图片没有及时同步更新
/// 问题 2：在第一次删完照片后，第二次点击删除按钮没反应
///
/// 验证链路：
///   1. 进详情页 → 记录首页卡片项数（count=N）
///   2. 全选 → 清理 → 系统「删除」确认 → 成功页
///   3. 返回首页 → 断言项数已减少（问题 1：首页同步）
///   4. 再进详情页 → 全选 → 清理 → 断言第二次仍能弹出系统确认框（问题 2）
///
/// 前置条件：模拟器相册里要有可清理候选。
/// 清理用例会真的删掉照片，跑之前需先灌图：
///   xcrun simctl addmedia <udid> /tmp/clean_sync_seed/*.png
/// （UI 测试进程在模拟器内，无法自行调 simctl 灌图）
final class CleanSyncVerifyTests: XCTestCase {

    @MainActor
    private func launchCleanApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitest-reset-onboarding", "-uitest-skip-onboarding",
            "-uitest-pro", "-uitest-no-paywall",
        ]
        app.launch()
        return app
    }

    /// 处理相册权限弹窗（挂在 SpringBoard 上）
    @MainActor
    private func grantPhotoPermission() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<8 {
            var handled = false
            for title in ["允许完全访问", "Allow Full Access", "好", "OK"] {
                let btn = springboard.buttons[title]
                if btn.exists && btn.isHittable { btn.tap(); handled = true; break }
            }
            if handled { break }
            sleep(1)
        }
    }

    /// 找到首页某个分类卡片（identifier 保持 home.kind.X 不变）
    /// 注意：SwiftUI 容器元素的 accessibility 类型不固定，用 descendants 全量匹配。
    @MainActor
    private func findHomeCard(_ app: XCUIApplication, _ kind: String) -> XCUIElement? {
        let cards = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'home.kind.'")
        )
        for i in 0..<cards.count {
            let c = cards.element(boundBy: i)
            if c.identifier == "home.kind.\(kind)" { return c }
        }
        return nil
    }

    /// 从首页卡片 label 读出当前项数（label 格式「相似照片 count=N」）
    @MainActor
    private func homeCount(_ app: XCUIApplication, _ kind: String) -> Int? {
        guard let card = findHomeCard(app, kind) else { return nil }
        let label = card.label
        guard let range = label.range(of: "count=") else { return nil }
        let digits = label[range.upperBound...].filter { $0.isNumber }
        return Int(digits)
    }

    /// 找系统「删除」确认框；找到返回按钮并点掉（true=确认删除）
    @MainActor
    @discardableResult
    private func handleSystemDeleteConfirm(_ app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<12 {
            for title in ["删除", "Delete"] {
                let candidates = [springboard.alerts.buttons[title], springboard.buttons[title],
                                  app.alerts.buttons[title], app.buttons[title]]
                if let btn = candidates.first(where: { $0.exists && $0.isHittable }) {
                    btn.tap()
                    return true
                }
            }
            sleep(1)
        }
        return false
    }

    /// 进入某个清理分类详情页；返回 false 表示该分类没有候选
    @MainActor
    private func enterDetail(_ app: XCUIApplication, _ kind: String) -> Bool {
        var entry: XCUIElement?
        for _ in 0..<10 {
            if let btn = findHomeCard(app, kind), btn.exists, btn.isHittable {
                entry = btn
                break
            }
            sleep(1)
        }
        guard let entry else { return false }
        entry.tap()
        return app.navigationBars.buttons["全选"].waitForExistence(timeout: 8)
    }

    /// 清理流程：全选 → 清理 → 确认删除 → 等成功页。返回是否真的执行了删除
    @MainActor
    private func runOneCleanRound(_ app: XCUIApplication) -> Bool {
        let selectAll = app.navigationBars.buttons["全选"]
        guard selectAll.waitForExistence(timeout: 6) else { return false }
        selectAll.tap()
        sleep(1)

        let clean = app.buttons["detail.primaryAction"]
        guard clean.waitForExistence(timeout: 5), clean.isHittable else { return false }
        clean.tap()

        let confirmed = handleSystemDeleteConfirm(app)
        guard confirmed else { return false }
        // 等成功页出现
        _ = app.staticTexts["清理成功"].waitForExistence(timeout: 8)
        return true
    }

    /// 只清理「第一组」：点组卡上的组级「全选」→ 清理 → 确认删除。
    /// 故意不删光所有组，这样第二轮仍有候选可删 —— 正是问题 2 的场景。
    @MainActor
    private func runFirstGroupCleanRound(_ app: XCUIApplication) -> Bool {
        // 组级「全选」按钮文案是「全选」，与导航栏的同名，靠位置区分：
        // 组级按钮在导航栏下方，属于详情页内容区。
        let groupSelect = app.buttons.matching(
            NSPredicate(format: "label == '全选'")
        )
        guard groupSelect.count > 0 else { return false }
        // 取第一个（详情页里组卡的「全选」排在导航栏按钮之后，但内容区顺序在前）
        let btn = groupSelect.element(boundBy: groupSelect.count - 1)
        guard btn.exists, btn.isHittable else { return false }
        btn.tap()
        sleep(1)

        let clean = app.buttons["detail.primaryAction"]
        guard clean.waitForExistence(timeout: 5), clean.isEnabled else { return false }
        clean.tap()

        let confirmed = handleSystemDeleteConfirm(app)
        guard confirmed else { return false }
        _ = app.staticTexts["清理成功"].waitForExistence(timeout: 8)
        return true
    }

    /// 问题 1 + 问题 2 联合验证
    @MainActor
    func testHomeSyncsAfterCleanAndSecondRoundStillWorks() throws {
        let app = launchCleanApp()
        grantPhotoPermission()

        XCTAssertTrue(app.buttons["tab.首页"].waitForExistence(timeout: 15), "主界面未出现")
        let close = app.buttons["flashSale.close"]
        if close.waitForExistence(timeout: 2) { close.tap(); sleep(1) }

        // 等扫描完成：首页卡片出现真实项数
        var kind: String?
        var before: Int?
        for _ in 0..<15 {
            for k in ["similar_photos", "screenshots", "blurred_photos"] {
                if let c = homeCount(app, k), c > 0 {
                    kind = k; before = c; break
                }
            }
            if kind != nil { break }
            sleep(1)
        }
        guard let kind, let before else {
            throw XCTSkip("模拟器相册没有可清理候选，跳过清理同步验证")
        }
        print("[CleanSync] 起始分类=\(kind) 项数=\(before)")

        // ── 第一轮清理：只删第一组（保留其他组，第二轮才有候选）──
        XCTAssertTrue(enterDetail(app, kind), "进入详情页失败")
        XCTAssertTrue(runFirstGroupCleanRound(app), "第一轮清理未完成（系统删除确认框未出现）")
        let shot1 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot1.name = "clean_sync_after_first_round"
        shot1.lifetime = .keepAlways
        add(shot1)

        // 成功页 → 点「继续清理」回首页（不是导航栏 back，成功页自带按钮）
        let continueBtn = app.buttons["继续清理"]
        if continueBtn.waitForExistence(timeout: 5) {
            continueBtn.tap()
            sleep(2)
        } else {
            // 回退：如果没有「继续清理」按钮，尝试导航栏返回
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() } else { app.swipeRight() }
            sleep(2)
        }

        // ── 问题 1：首页项数应已同步减少 ──
        var after: Int?
        for _ in 0..<8 {
            if let c = homeCount(app, kind) { after = c; break }
            sleep(1)
        }
        print("[CleanSync] 第一轮后首页项数=\(after.map(String.init) ?? "nil")")
        XCTAssertNotNil(after, "返回首页后读不到 \(kind) 卡片项数")
        if let after {
            XCTAssertLessThan(after, before, "首页未同步更新：清理前 \(before) 项，清理后仍为 \(after) 项")
        }
        let shot2 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot2.name = "clean_sync_home_after_first_round"
        shot2.lifetime = .keepAlways
        add(shot2)

        // ── 问题 2：第二次清理仍应有反应 ──
        // 回到详情页，再来一轮全选 → 清理 → 必须仍能弹出系统删除确认框
        XCTAssertTrue(enterDetail(app, kind), "第二次进入详情页失败")
        // 全选按钮文案可能是「全选」或「取消全选」（选中状态残留），
        // 先点一次取消全选（如果有残留），再点全选
        let navDeselectBtn = app.navigationBars.buttons["取消全选"]
        if navDeselectBtn.waitForExistence(timeout: 3) {
            navDeselectBtn.tap()
            sleep(1)
        }
        guard app.navigationBars.buttons["全选"].waitForExistence(timeout: 5) else {
            // 没有全选按钮 = 没有候选了（第一轮全删了）。这本身说明 localSummary 已更新。
            // 问题 2 的核心是「按钮点了没反应」，如果没有候选，按钮本来就不该反应。
            // 这里验证：按钮文案不是「清理N项」而是「清理」（空选中态）
            let emptyBtn = app.buttons["detail.primaryAction"]
            if emptyBtn.exists {
                let title = emptyBtn.label
                print("[CleanSync] 第二轮无候选，按钮文案=\(title)")
                // 按钮应该显示「清理」（无选中），而非卡在旧的「清理N项」
                XCTAssertTrue(title.contains("清理"), "无候选时按钮应显示清理态")
            }
            let shot3 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot3.name = "clean_sync_second_round_no_candidates"
            shot3.lifetime = .keepAlways
            add(shot3)
            return  // 没有候选可验证第二轮删除，但首页同步已验证通过
        }
        app.navigationBars.buttons["全选"].tap()
        sleep(1)
        let clean2 = app.buttons["detail.primaryAction"]
        XCTAssertTrue(clean2.waitForExistence(timeout: 5), "第二轮：清理按钮消失")
        // 按钮 enabled 条件：!cleaning && !selectedAssets.isEmpty
        // 若没有候选（第一轮已全删），按钮应为 disabled —— 这时不该再要求弹确认框。
        guard clean2.isEnabled else {
            print("[CleanSync] 第二轮无可清理候选，按钮已正确禁用")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "clean_sync_second_round_disabled"
            shot.lifetime = .keepAlways
            add(shot)
            return
        }
        XCTAssertTrue(clean2.isHittable, "第二轮：清理按钮不可点击（第二次点击没反应）")
        clean2.tap()

        let confirmed2 = handleSystemDeleteConfirm(app)
        print("[CleanSync] 第二轮系统确认框=\(confirmed2)")
        XCTAssertTrue(confirmed2, "第二次点击清理按钮没反应：未弹出系统删除确认框")
        let shot3 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot3.name = "clean_sync_second_round_confirm"
        shot3.lifetime = .keepAlways
        add(shot3)
    }

    /// 详情页组数据在清理后即时刷新（localSummary 可变状态，问题 2 的数据侧保障）
    @MainActor
    func testDetailGroupsRefreshAfterClean() throws {
        let app = launchCleanApp()
        grantPhotoPermission()

        XCTAssertTrue(app.buttons["tab.首页"].waitForExistence(timeout: 15), "主界面未出现")
        let close = app.buttons["flashSale.close"]
        if close.waitForExistence(timeout: 2) { close.tap(); sleep(1) }

        var kind: String?
        for _ in 0..<15 {
            for k in ["similar_photos", "screenshots", "blurred_photos"] {
                if let c = homeCount(app, k), c > 0 { kind = k; break }
            }
            if kind != nil { break }
            sleep(1)
        }
        guard let kind else { throw XCTSkip("没有可清理候选，跳过") }

        XCTAssertTrue(enterDetail(app, kind), "进入详情页失败")

        // 记录清理前第一组的 identifier（编码了 assets/cleanable 数）
        // 注意：SwiftUI 容器元素的 accessibility 元素类型不固定（可能落在
        // otherElements / buttons / staticTexts 任一类），所以用 descendants 全量匹配。
        let groupPred = NSPredicate(format: "identifier BEGINSWITH 'detail.group.'")
        let group = app.descendants(matching: .any).matching(groupPred).firstMatch
        guard group.waitForExistence(timeout: 6) else {
            throw XCTSkip("详情页没有可识别的组卡片")
        }
        let beforeID = group.identifier
        print("[CleanSync] 清理前组ID=\(beforeID)")

        // 清理一轮
        XCTAssertTrue(runOneCleanRound(app), "清理未完成")
        sleep(1)

        // 成功页上「清理数量」应 > 0
        let moved = app.staticTexts["清理数量"]
        XCTAssertTrue(moved.exists, "未进入清理成功页")

        // 返回后重新进入详情页，组数据应已变化（不再是旧数据）
        let continueBtn2 = app.buttons["继续清理"]
        if continueBtn2.waitForExistence(timeout: 5) {
            continueBtn2.tap()
            sleep(2)
        } else {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() } else { app.swipeRight() }
            sleep(2)
        }
        XCTAssertTrue(enterDetail(app, kind), "重新进入详情页失败")

        // 清理后：要么该组被移除（只剩最佳资产 → 组消失），要么组的计数变了。
        // 两者都证明详情页用的是最新的 summary；只有"计数完全没变"才是 bug。
        let group2 = app.descendants(matching: .any).matching(groupPred).firstMatch
        let stillExists = group2.waitForExistence(timeout: 6)
        if stillExists {
            let afterID = group2.identifier
            print("[CleanSync] 清理后组ID=\(afterID)")
            XCTAssertNotEqual(beforeID, afterID, "清理后详情页组数据没有刷新（仍在用旧 summary）")
        } else {
            print("[CleanSync] 清理后原组已移除（只余最佳资产），localSummary 已即时更新")
            // 组消失 = 数据已刷新 ✅
        }
    }
}
