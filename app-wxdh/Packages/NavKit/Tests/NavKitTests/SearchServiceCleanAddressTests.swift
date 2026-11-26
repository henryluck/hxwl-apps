import CoreLocation
import MapKit
import XCTest
@testable import NavKit

/// NAV-09 地址清洗回归：线上崩溃（点「充电桩」→ searchNearby → place → cleanAddress）
/// 栈为 _StringGuts.validateCharacterIndex → String.index(after:) →
/// ClosedRange.relative(to:) in conformance String。
/// 根因：地址以「省/市/区」结尾时，闭区间 `startIndex...range.upperBound`
/// 的 upperBound == endIndex，Swift 内部对 endIndex 调 index(after:) 越界。
final class SearchServiceCleanAddressTests: XCTestCase {

    // MARK: - 崩溃回归：命中字符位于串尾（半开区间才安全）

    @MainActor
    func testTrailingProvinceDoesNotCrash() {
        let raw = "中国广东省"
        let result = SearchService.cleanAddress(raw, city: "广州市", district: "天河区")
        // 全部被当前缀剥掉时回退原始地址，但绝不能崩溃
        XCTAssertEqual(result, raw)
    }

    @MainActor
    func testTrailingCityDoesNotCrash() {
        let raw = "中国广东省广州市"
        XCTAssertEqual(SearchService.cleanAddress(raw, city: "广州市", district: "天河区"), raw)
    }

    @MainActor
    func testTrailingDistrictDoesNotCrash() {
        // MapKit 充电桩 POI 常见「只到区县、没有街道门牌」的 title
        let raw = "中国广东省广州市天河区"
        XCTAssertEqual(SearchService.cleanAddress(raw, city: "广州市", district: "天河区"), raw)
    }

    @MainActor
    func testAllDelimitersAtEndInSequence() {
        // 省/市/区 依次被剥到空串，每一步 upperBound 都会等于当时的 endIndex
        XCTAssertEqual(SearchService.cleanAddress("广东省广州市区", city: "", district: ""),
                       "广东省广州市区")
    }

    // MARK: - 正常清洗（同时校验 off-by-one：闭区间会多吞一个字符）

    @MainActor
    func testFullAddressKeepsStreet() {
        XCTAssertEqual(
            SearchService.cleanAddress("中国广东省广州市天河区天河路100号",
                                       city: "广州市", district: "天河区"),
            "天河路100号")
    }

    @MainActor
    func testFieldMatchedCityAndDistrictPrefixRemoved() {
        XCTAssertEqual(
            SearchService.cleanAddress("深圳市南山区科技南路1号",
                                       city: "深圳市", district: "南山区"),
            "科技南路1号")
    }

    @MainActor
    func testPlainStreetUnchanged() {
        XCTAssertEqual(SearchService.cleanAddress("天河路100号", city: "", district: ""),
                       "天河路100号")
        XCTAssertEqual(SearchService.cleanAddress("", city: "广州市", district: "天河区"), "")
    }

    @MainActor
    func testLongHeadIsNotTrimmed() {
        // 命中字符过远（>8 字）时不按行政前缀处理，避免把正文街道吃掉
        XCTAssertEqual(SearchService.cleanAddress("一二三四五六七八九省后面", city: "", district: ""),
                       "一二三四五六七八九省后面")
    }

    @MainActor
    func testEmojiAfterDelimiterIsSafe() {
        // Character 与 Unicode 标量索引不同，removeSubrange 用真实 String.Index 才安全
        XCTAssertEqual(SearchService.cleanAddress("中国广东省🚗", city: "广州市", district: "天河区"),
                       "🚗")
    }

    // MARK: - 崩溃栈完整链路：MKMapItem → place(from:) → cleanAddress

    @MainActor
    func testPlaceMappingWithDistrictOnlyAddressDoesNotCrash() {
        // 线上栈：WeatherRegionPicker.search → SearchService.search →
        // Collection.map → place(from:source:category:) → cleanAddress。
        // 构造一个「地址只到区县」的充电桩 POI（MapKit 常见返回），验证整条映射不崩。
        let placemark = MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: 23.1291, longitude: 113.2644),
            addressDictionary: ["Thoroughfare": "天河区",
                                "Locality": "广州市",
                                "SubLocality": "天河区"])
        let item = MKMapItem(placemark: placemark)
        item.name = "特来电充电站"

        let place = SearchService.place(from: item, source: .mapSearch, category: "充电桩")
        XCTAssertEqual(place.name, "特来电充电站")
        XCTAssertEqual(place.category, "充电桩")
        // 清洗后为空时回退原始 title，地址栏必须有内容
        XCTAssertFalse(place.address.isEmpty)
    }
}
