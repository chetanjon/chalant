import XCTest

@testable import Chalant

@MainActor
final class WeatherTests: XCTestCase {
    func testTheSkyWordsCoverTheWMOTable() {
        XCTAssertEqual(WeatherController.skyWord(code: 0), "Clear")
        XCTAssertEqual(WeatherController.skyWord(code: 2), "Partly cloudy")
        XCTAssertEqual(WeatherController.skyWord(code: 3), "Cloudy")
        XCTAssertEqual(WeatherController.skyWord(code: 45), "Fog")
        XCTAssertEqual(WeatherController.skyWord(code: 61), "Rain")
        XCTAssertEqual(WeatherController.skyWord(code: 71), "Snow")
        XCTAssertEqual(WeatherController.skyWord(code: 81), "Showers")
        XCTAssertEqual(WeatherController.skyWord(code: 95), "Storm")
        XCTAssertEqual(WeatherController.skyWord(code: 999), "Sky")
    }

    func testDecodeReadsOpenMeteoCurrent() {
        let json = #"{"current":{"temperature_2m":41.3,"weather_code":2}}"#
        let decoded = WeatherController.decode(Data(json.utf8))
        XCTAssertEqual(decoded?.temperature, 41.3)
        XCTAssertEqual(decoded?.code, 2)
        XCTAssertNil(WeatherController.decode(Data("{}".utf8)))
    }

    func testAReadingGoesStaleAfterThreeHours() {
        let fresh = WeatherController.Reading(
            temperature: 30, code: 0, at: Date(timeIntervalSinceNow: -60))
        let stale = WeatherController.Reading(
            temperature: 30, code: 0, at: Date(timeIntervalSinceNow: -3.5 * 3600))
        XCTAssertNotNil(WeatherController.usableReading(fresh, now: Date()))
        XCTAssertNil(WeatherController.usableReading(stale, now: Date()))
        XCTAssertNil(WeatherController.usableReading(nil, now: Date()))
    }

    func testTheLineReadsLikeTheMockup() {
        let reading = WeatherController.Reading(temperature: 41.3, code: 0, at: Date())
        XCTAssertEqual(WeatherController.line(reading, celsius: false), "106° Clear")
        XCTAssertEqual(WeatherController.line(reading, celsius: true), "41° Clear")
    }

    func testUnitFollowsTheLocale() {
        XCTAssertFalse(WeatherController.wantsCelsius(locale: Locale(identifier: "en_US")))
        XCTAssertTrue(WeatherController.wantsCelsius(locale: Locale(identifier: "en_GB")))
    }
}
