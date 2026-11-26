import XCTest
@testable import NavKit

/// 地址整理提取器：对照规则 v0.31.1 §1.3 可复核输入例
final class AddressExtractorTests: XCTestCase {

    func testLabeledAddressStripsNameAndPhone() {
        // 样例1：收件人+地址+电话 → 1 个候选，不带姓名电话
        let out = AddressExtractor.extractOutcome(from: "收件人：李先生；地址：天津市北辰区光荣道 26 号；电话：13800138000")
        XCTAssertEqual(out.candidates, ["天津市北辰区光荣道 26 号"])
    }

    func testCrossLineMerge() {
        // 样例2：行政区换行+道路门牌 → 合并 1 个候选
        let out = AddressExtractor.extractOutcome(from: "天津市北辰区\n光荣道 26 号")
        XCTAssertEqual(out.candidates, ["天津市北辰区 光荣道 26 号"])
    }

    func testTwoAddressesStaySeparate() {
        // 样例3：两个完整地址 → 2 个候选，原文顺序，不合并
        let out = AddressExtractor.extractOutcome(from: "天津站；天津市和平区南京路 20 号")
        XCTAssertEqual(out.candidates.count, 2)
        XCTAssertEqual(out.candidates[0], "天津站")
        XCTAssertEqual(out.candidates[1], "天津市和平区南京路 20 号")
    }

    func testChatterAndBareCategoryNoCandidate() {
        // 样例4：闲聊/纯类别/纯行政区 → 0 候选
        XCTAssertEqual(AddressExtractor.extract(from: "今天天气好，去公园散步"), [])
        XCTAssertEqual(AddressExtractor.extract(from: "公交站"), [])
        XCTAssertEqual(AddressExtractor.extract(from: "北京市海淀区"), [])
    }

    func testPhoneOrderLinkOnlyNoCandidate() {
        // 样例5：电话/订单号/链接/表情/全空格 → 0 候选
        XCTAssertEqual(AddressExtractor.extract(from: "13800138000"), [])
        XCTAssertEqual(AddressExtractor.extract(from: "订单号 998877665544"), [])
        XCTAssertEqual(AddressExtractor.extract(from: "https://example.com/xxx"), [])
        XCTAssertEqual(AddressExtractor.extract(from: "😊😊😊"), [])
        XCTAssertEqual(AddressExtractor.extract(from: "   "), [])
    }

    func testSixAddressesTruncateWithHint() {
        // 样例6：6 个不同有效地址 → 显示 5 个并标记超限
        let text = (1...6).map { "上海市浦东新区世纪大道 \($0)00 号" }.joined(separator: "\n")
        let out = AddressExtractor.extractOutcome(from: text)
        XCTAssertEqual(out.candidates.count, 5)
        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.totalFound, 6)
    }

    func testDuplicateNormalizedDedup() {
        // 归一去重：全角/首尾空白差异的相同地址只留一个
        let out = AddressExtractor.extractOutcome(from: "天津市北辰区光荣道26号\n　天津市北辰区光荣道２６号 ")
        XCTAssertEqual(out.candidates.count, 1)
    }

    func testNormalizeFullWidth() {
        XCTAssertEqual(AddressExtractor.normalize("２６号"), "26号")
        XCTAssertEqual(AddressExtractor.normalize("Ａｂｃ　ｄｅｆ"), "Abc def")
        XCTAssertEqual(AddressExtractor.normalize("  多个   空格  "), "多个 空格")
    }
}
