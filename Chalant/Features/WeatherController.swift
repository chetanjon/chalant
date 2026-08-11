import AppKit
import CoreLocation
import Foundation
import os

/// File-scope so the URLSession callback (not on the main actor) can
/// speak too. Console is the only place weather ever complains; the
/// line itself stays silent by design.
private let log = Logger(subsystem: "com.cj.chalant", category: "weather")

/// The weather line beside the date on Today. Keyless (Open-Meteo needs
/// no account, no API key) and approximate on purpose: CoreLocation's
/// fix is rounded to two decimal places before it ever leaves the Mac,
/// which is about a kilometre of fuzz, plenty for "is it raining" and
/// nowhere near enough to be an address.
///
/// A denial, a dead network, or a location the system never resolves
/// all fail the same honest way: the line just does not appear. Nothing
/// here throws up an error state, because a weather glyph is a nicety,
/// not a block the founder is owed an apology for missing.
@MainActor
final class WeatherController: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// One fetched reading. Stored in Celsius always, the one canonical
    /// unit; `line(_:celsius:)` converts to Fahrenheit itself so there
    /// is exactly one place that ever does the math.
    struct Reading: Codable, Equatable {
        var temperature: Double
        var code: Int
        var at: Date
    }

    @Published private(set) var reading: Reading?

    private let manager = CLLocationManager()
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// True once `start()` has run, so a location update or a wake
    /// notice arriving before then (or after the toggle was flipped
    /// off) has nothing to act on.
    private var started = false

    private static let cacheKey = "chalant.weather.reading"
    /// A reading older than this is not shown, even though it is still
    /// sitting in the cache; `usableReading` is the one gate every
    /// reader (the view, a future fetch) goes through.
    private static let staleAfter: TimeInterval = 3 * 3600
    private static let refreshInterval: TimeInterval = 30 * 60

    override init() {
        super.init()
        manager.delegate = self
        reading = Self.loadCache()
    }

    deinit {
        refreshTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - Lifecycle

    /// Gated by the caller on `showsWeather`: starting is what turns
    /// the fetch on, not just the line's visibility. `stop()` is the
    /// other half, so a toggled-off block never quietly asks
    /// CoreLocation for anything.
    func start() {
        guard !started else { return }
        started = true
        requestIfAuthorized()
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.refreshInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.requestIfAuthorized() }
        }
        timer.tolerance = 60
        refreshTimer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.requestIfAuthorized() }
        }
    }

    /// Off means quiet, not hidden: the timer and the wake observer
    /// come down and `started` resets, so nothing asks CoreLocation
    /// for anything until a fresh `start()`. Resetting `started` is
    /// also what makes the toggle a real second chance at the system
    /// prompt: flipping it back on re-runs the ask from a genuine
    /// user action.
    func stop() {
        started = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    /// Notdetermined asks; already-authorized just fetches. Denied,
    /// restricted, or any other status does nothing at all, the same
    /// silent fallthrough every other path here uses.
    private func requestIfAuthorized() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // The ask that actually works on macOS: the "always"
            // variant is documented (CLLocationManager.h) to do
            // NOTHING unless both iOS-style *WhenInUse* keys are in
            // Info.plist, and a when-in-use grant surfaces as
            // .authorized/.authorizedAlways here anyway, which the
            // cases below already accept.
            log.info("location not determined, asking")
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            manager.requestLocation()
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // The toggle governs the fetch, so an unstarted controller ignores its manager.
        guard started else { return }
        log.info("location authorization now \(manager.authorizationStatus.rawValue)")
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The toggle governs the fetch, so an unstarted controller ignores its manager.
        guard started else { return }
        guard let coordinate = locations.last?.coordinate else { return }
        fetch(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent in the UI: whatever the cache already holds keeps
        // showing until it goes stale on its own (`usableReading` at
        // read time). Console still hears about it.
        log.error("location failed: \(error.localizedDescription)")
    }

    // MARK: - Network

    private func fetch(latitude: Double, longitude: Double) {
        let lat = (latitude * 100).rounded() / 100
        let lon = (longitude * 100).rounded() / 100
        guard let url = URL(
            string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
                + "&current=temperature_2m,weather_code"
        ) else { return }
        // A completion, not async/await: the request must never hold
        // up anything on the main thread, and hopping back to
        // MainActor by hand inside the callback is the whole point of
        // that shape here.
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data, let decoded = Self.decode(data) else {
                log.error("fetch dropped: \(error?.localizedDescription ?? "undecodable reply", privacy: .public)")
                return
            }
            Task { @MainActor in
                guard let self else { return }
                let fresh = Reading(temperature: decoded.temperature, code: decoded.code, at: Date())
                self.reading = fresh
                Self.saveCache(fresh)
            }
        }.resume()
    }

    // MARK: - Cache

    private static func loadCache() -> Reading? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Reading.self, from: data)
    }

    private static func saveCache(_ reading: Reading) {
        guard let data = try? JSONEncoder().encode(reading) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    // MARK: - Statics (pinned by WeatherTests)

    /// One rule in one place (the `EventKitService.showsCalendar`
    /// pattern): unset means ON, an explicit false is honoured, and
    /// the two `@AppStorage("showWeather")` declarations carry the
    /// same default.
    static func showsWeather(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "showWeather") == nil || defaults.bool(forKey: "showWeather")
    }

    /// The WMO table again, as glyphs, so the icon agrees with the
    /// word: rain reads as rain, not a sun over a downpour. The case
    /// ranges mirror `skyWord` exactly; an unrecognized code falls
    /// back to the sun the same way it falls back to "Sky".
    static func skyGlyph(code: Int) -> String {
        switch code {
        case 0: return "sun.max"
        case 1, 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...67: return "cloud.rain"
        case 71...77: return "cloud.snow"
        case 80...82: return "cloud.rain"
        case 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt"
        default: return "sun.max"
        }
    }

    /// The WMO weather-code table, collapsed to the words the glance
    /// needs. An unrecognized code (a future Open-Meteo addition) still
    /// reads as something, "Sky", rather than a blank or a number.
    static func skyWord(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow"
        case 95...99: return "Storm"
        default: return "Sky"
        }
    }

    /// Open-Meteo's `current` block, nested exactly as the API ships
    /// it. Private: nothing outside `decode` needs the wire shape.
    private struct OpenMeteoResponse: Codable {
        struct Current: Codable {
            let temperature: Double
            let code: Int

            private enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
                case code = "weather_code"
            }
        }
        let current: Current
    }

    /// The request omits `temperature_unit`, so Open-Meteo always
    /// answers in Celsius; that is the one unit ever decoded or
    /// stored. Malformed or missing `current` reads as nil, not a
    /// crash or a zeroed reading.
    static func decode(_ data: Data) -> (temperature: Double, code: Int)? {
        guard let response = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        else { return nil }
        return (response.current.temperature, response.current.code)
    }

    /// A reading past its window is treated as though there is none,
    /// at the moment it is read rather than the moment it goes stale:
    /// nothing here needs to run on a schedule just to blank a line.
    static func usableReading(_ reading: Reading?, now: Date) -> Reading? {
        guard let reading, now.timeIntervalSince(reading.at) < staleAfter else { return nil }
        return reading
    }

    /// "106° Clear": whole degrees, converted to Fahrenheit here (not
    /// at decode time) so Celsius stays the one stored unit and a
    /// locale flip never needs a re-fetch.
    static func line(_ reading: Reading, celsius: Bool) -> String {
        let value = celsius ? reading.temperature : reading.temperature * 9 / 5 + 32
        return "\(Int(value.rounded()))\u{00B0} \(skyWord(code: reading.code))"
    }

    /// Celsius everywhere except the US measurement system; the UK
    /// keeps Celsius for weather even though it keeps miles for
    /// distance, which `Locale.measurementSystem` already encodes as
    /// `.uk`, distinct from `.us`.
    static func wantsCelsius(locale: Locale) -> Bool {
        locale.measurementSystem != .us
    }
}
