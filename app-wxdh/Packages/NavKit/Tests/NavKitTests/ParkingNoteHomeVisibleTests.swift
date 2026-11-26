import XCTest
@testable import NavKit

/// R-073 停车便签首页展示与删除（v0.32）
/// 覆盖 T-248/T-252/T-254/T-255/T-257/T-259 的数据层语义。
final class ParkingNoteHomeVisibleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.r073.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStores() -> NavStores {
        NavStores(defaults: defaults)
    }

    // MARK: - T-248/R-073-01：新建默认开启

    func testNewNoteDefaultsHomeVisibleOn() throws {
        let stores = makeStores()
        let note = NavStores.ParkingNote(note: "B2 层 07 号", imageData: nil, createdAt: Date())
        XCTAssertTrue(note.homeVisible, "新建记录的 homeVisible 默认开启（R-073-01/T-248）")
        XCTAssertTrue(stores.saveParking(note))
        XCTAssertEqual(stores.parking?.homeVisible, true)
    }

    // MARK: - T-259/R-073：旧记录缺字段迁移默认开启

    func testLegacyNoteWithoutFieldMigratesToVisible() throws {
        // v0.31 旧格式：无 homeVisible 键
        let legacy = """
        {"note":"旧便签","createdAt":693592800.0}
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: "nav.parking.v1")
        let stores = makeStores()
        XCTAssertEqual(stores.parking?.note, "旧便签", "备注迁移保持")
        XCTAssertNil(stores.parking?.imageData)
        XCTAssertEqual(stores.parking?.homeVisible, true, "旧记录缺 homeVisible → 迁移为开启（T-259）")
    }

    // MARK: - T-251/T-253/R-073-03：开关切换即时持久化

    func testToggleHomeVisiblePersistsAndReloads() throws {
        let stores = makeStores()
        XCTAssertTrue(stores.saveParking(NavStores.ParkingNote(note: "测试", imageData: nil, createdAt: Date())))
        // 关 → 首页卡消失（homeVisible=false 持久化）
        XCTAssertTrue(stores.setParkingHomeVisible(false))
        XCTAssertEqual(stores.parking?.homeVisible, false)
        // 重载（模拟重启，T-252）：隐藏状态保持、记录不丢
        let reloaded = makeStores()
        XCTAssertEqual(reloaded.parking?.homeVisible, false, "隐藏状态跨启动保持")
        XCTAssertEqual(reloaded.parking?.note, "测试", "关闭开关不删备注（仅展示字段）")
        // 开 → 立即恢复（T-253）
        XCTAssertTrue(reloaded.setParkingHomeVisible(true))
        XCTAssertEqual(reloaded.parking?.homeVisible, true)
    }

    // MARK: - T-254/R-073-03：持久化失败开关回退（数据层：返回 false 且状态不变）

    func testToggleFailureKeepsOldState() throws {
        let stores = makeStores()
        XCTAssertTrue(stores.saveParking(NavStores.ParkingNote(note: "原文", imageData: nil, createdAt: Date())))
        // 无记录时 toggle 返回 false（门控失败路径）
        let empty = makeStores()
        XCTAssertFalse(empty.setParkingHomeVisible(true), "无记录时开关操作应失败")
        // 原记录未被破坏
        XCTAssertEqual(stores.parking?.homeVisible, true)
    }

    // MARK: - T-255/R-073-04：隐藏状态编辑保存后仍隐藏

    func testEditWhileHiddenKeepsHidden() throws {
        let stores = makeStores()
        XCTAssertTrue(stores.saveParking(NavStores.ParkingNote(note: "旧文", imageData: nil,
                                                               createdAt: Date(), homeVisible: false)))
        // 编辑保存（表单回填旧开关值 false——视图层继承，数据层验证持久化结果）
        let updated = NavStores.ParkingNote(note: "新文", imageData: nil,
                                            createdAt: stores.parking?.createdAt, homeVisible: false)
        XCTAssertTrue(stores.saveParking(updated))
        XCTAssertEqual(stores.parking?.note, "新文")
        XCTAssertEqual(stores.parking?.homeVisible, false, "隐藏状态下编辑保存后首页仍隐藏")
    }

    // MARK: - T-256/T-257/R-073-05：删除无前置 + 新建重置默认开

    func testDeleteWithoutFoundCarAndReset() throws {
        let stores = makeStores()
        XCTAssertTrue(stores.saveParking(NavStores.ParkingNote(note: "未找到车也能删",
                                                               imageData: Data([0xFF]),
                                                               createdAt: Date())))
        // 未「找到车」状态直接删除（R-073-05：不再前置）
        XCTAssertTrue(stores.deleteParking())
        XCTAssertNil(stores.parking, "删除后记录清空")
        XCTAssertNil(defaults.data(forKey: "nav.parking.v1"), "持久化同步清除")
        // 删除后新建 → homeVisible 重置默认开（T-257）
        let fresh = NavStores.ParkingNote(note: "新便签", imageData: nil, createdAt: Date())
        XCTAssertTrue(fresh.homeVisible, "删除后新建重置为默认开启")
        XCTAssertTrue(stores.saveParking(fresh))
        XCTAssertEqual(stores.parking?.homeVisible, true)
    }
}
