import XCTest

@testable import Chalant

@MainActor
final class WeatherTests: XCTestCase {
    func testTheSkyWordsCoverTheWMOTable() {
        XCTAssertEqual(WeatherController.skyWord(code: 0), "Clear")
        // WMO 1 is "mainly clear" and 2 is "partly cloudy". They shipped
        // sharing a word, so a mainly-clear Phoenix afternoon read as
        // "Partly cloudy" while the station said Mostly Clear (founder,
        // 2026-08-12). 1 was the only code this test never covered.
        XCTAssertEqual(WeatherController.skyWord(code: 1), "Mainly clear")
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

    /// The icon agrees with the word: a storm never wears a sun. Same
    /// representative codes as the word test, plus the fallback.
    func testTheSkyGlyphsAgreeWithTheWords() {
        XCTAssertEqual(WeatherController.skyGlyph(code: 0), "sun.max")
        XCTAssertEqual(WeatherController.skyGlyph(code: 2), "cloud.sun")
        XCTAssertEqual(WeatherController.skyGlyph(code: 3), "cloud")
        XCTAssertEqual(WeatherController.skyGlyph(code: 45), "cloud.fog")
        XCTAssertEqual(WeatherController.skyGlyph(code: 61), "cloud.rain")
        XCTAssertEqual(WeatherController.skyGlyph(code: 71), "cloud.snow")
        XCTAssertEqual(WeatherController.skyGlyph(code: 81), "cloud.rain")
        XCTAssertEqual(WeatherController.skyGlyph(code: 86), "cloud.snow")
        XCTAssertEqual(WeatherController.skyGlyph(code: 95), "cloud.bolt")
        XCTAssertEqual(WeatherController.skyGlyph(code: 999), "sun.max")
    }

    /// Weather ships ON like the day's sources do: the permission
    /// prompt is the real gate, and a second invisible one would only
    /// hide the line the grant was for. An explicit false is honoured.
    func testWeatherIsOnUntilSomebodyTurnsItOff() {
        let suite = "chalant.tests.weather.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertTrue(WeatherController.showsWeather(in: defaults), "unset means on")
        defaults.set(false, forKey: "showWeather")
        XCTAssertFalse(WeatherController.showsWeather(in: defaults))
        defaults.set(true, forKey: "showWeather")
        XCTAssertTrue(WeatherController.showsWeather(in: defaults))
        defaults.removePersistentDomain(forName: suite)
    }
}
