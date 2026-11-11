import XCTest
@testable import NavKit

/// 天气解析器：真实线上响应样本（和风 v1 新格式）+ v7 旧格式回归。
/// 线上样本取自 2026-11-11 /api/v1/forecast/{now,24h,7d} 实际返回。
final class NavWeatherParserTests: XCTestCase {

    // MARK: - 和风 v1（线上当前格式）

    private let v1Now: [String: Any] = [
        "validTime": "2026-11-11T09:15Z",
        "condition": ["text": "晴", "code": "100"],
        "temperature": ["value": 22.51, "unit": "°C"],
        "feelsLike": ["value": 21.22, "unit": "°C"],
        "humidity": 0.43,
        "wind": ["direction": ["degree": 345, "compass": "nnw"],
                 "speed": ["value": 2.83, "unit": "m/s"], "scale": 2],
    ]

    private let v1Hourly: [String: Any] = [
        "hours": [
            ["forecastTime": "2026-11-11T10:00Z",
             "condition": ["text": "晴间多云", "code": "103"],
             "temperature": ["value": 19.71, "unit": "°C"]],
            ["forecastTime": "2026-11-11T11:00Z",
             "condition": ["text": "晴间多云", "code": "103"],
             "temperature": ["value": 18.4, "unit": "°C"]],
        ]
    ]

    private let v1Daily: [String: Any] = [
        "days": [
            ["forecastStartTime": "2026-11-10T16:00Z",
             "forecastEndTime": "2026-11-11T16:00Z",
             "astro": ["sunrise": "2026-11-10T22:37Z", "sunset": "2026-11-11T09:43Z"],
             "temperatureMax": ["value": 22.7, "unit": "°C"],
             "temperatureMin": ["value": 12.16, "unit": "°C"],
             "daytime": ["condition": ["text": "晴间多云", "code": "103"]],
             "nighttime": ["condition": ["text": "晴间多云", "code": "103"]]],
        ]
    ]

    func testParsesQWeatherV1Current() throws {
        let snap = NavWeatherParser.snapshot(now: v1Now, hourly: nil, daily: nil)
        let current = try XCTUnwrap(snap?.current)
        XCTAssertEqual(current.temperature, 22.51, accuracy: 0.01)
        XCTAssertEqual(current.feelsLike, 21.22, accuracy: 0.01)
        XCTAssertEqual(current.humidity, 43, accuracy: 0.5)     // 0..1 比例 → 百分数
        XCTAssertEqual(current.windSpeed, 2.83 * 3.6, accuracy: 0.05)  // m/s → km/h
        XCTAssertEqual(current.code, 100)
        XCTAssertEqual(WeatherCode.text(current.code), "晴")
    }

    func testParsesQWeatherV1HourlyAndDaily() throws {
        let snap = try XCTUnwrap(NavWeatherParser.snapshot(now: v1Now, hourly: v1Hourly, daily: v1Daily))
        XCTAssertEqual(snap.hours.count, 2)
        XCTAssertEqual(snap.hours[0].temperature, 19.71, accuracy: 0.01)
        XCTAssertEqual(snap.hours[0].code, 103)

        XCTAssertEqual(snap.days.count, 1)
        let day = snap.days[0]
        XCTAssertEqual(day.max, 22.7, accuracy: 0.01)
        XCTAssertEqual(day.min, 12.16, accuracy: 0.01)
        XCTAssertEqual(day.code, 103)   // 白天现象码
        XCTAssertNotNil(snap.sunrise, "v1 astro.sunrise 应解析出日出")
        XCTAssertNotNil(snap.sunset, "v1 astro.sunset 应解析出日落")
    }

    // MARK: - 和风 v7（旧格式回归）

    func testParsesQWeatherV7LegacyFormat() throws {
        let v7Now: [String: Any] = [
            "obsTime": "2024-05-31T14:00+08:00",
            "temp": "28.0", "feelsLike": "30.0", "humidity": "65",
            "windSpeed": "12.0", "icon": "101",
        ]
        let v7Hourly: [String: Any] = [
            "hourly": [["fxTime": "2024-05-31T15:00+08:00", "temp": "29", "icon": "101"]]
        ]
        let v7Daily: [String: Any] = [
            "daily": [["fxDate": "2024-05-31", "tempMax": "32", "tempMin": "24",
                       "iconDay": "101", "sunrise": "05:12", "sunset": "19:05"]]
        ]
        let snap = try XCTUnwrap(NavWeatherParser.snapshot(now: v7Now, hourly: v7Hourly, daily: v7Daily))
        XCTAssertEqual(snap.current.temperature, 28.0, accuracy: 0.01)
        XCTAssertEqual(snap.current.humidity, 65, accuracy: 0.5)   // >1 百分数原样
        XCTAssertEqual(snap.current.windSpeed, 12.0, accuracy: 0.01)
        XCTAssertEqual(snap.current.code, 101)
        XCTAssertEqual(snap.hours.count, 1)
        XCTAssertEqual(snap.hours[0].temperature, 29, accuracy: 0.01)
        XCTAssertEqual(snap.days.count, 1)
        XCTAssertEqual(snap.days[0].max, 32, accuracy: 0.01)
        XCTAssertEqual(snap.days[0].min, 24, accuracy: 0.01)
        XCTAssertNotNil(snap.sunrise)
        XCTAssertNotNil(snap.sunset)
    }

    // MARK: - 兜底

    func testMissingTemperatureReturnsNil() {
        XCTAssertNil(NavWeatherParser.snapshot(now: ["validTime": "x"], hourly: nil, daily: nil))
        XCTAssertNil(NavWeatherParser.snapshot(now: nil, hourly: nil, daily: nil))
    }
}
