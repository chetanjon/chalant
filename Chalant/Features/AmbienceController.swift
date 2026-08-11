import SwiftUI

extension NoiseEngine.NoiseColor {
    /// What the chips offer. White noise is out of the lineup (kept
    /// in the engine so old settings don't break).
    static var chipChoices: [NoiseEngine.NoiseColor] {
        [.brown, .pink, .rain, .fire, .cafe]
    }

    var displayName: String {
        switch self {
        case .brown: return "Brown"
        case .white: return "White"
        case .pink: return "Pink"
        case .rain: return "Rain"
        case .fire: return "Fire"
        case .cafe: return "Café"
        }
    }

    /// The collapsed glance's mark for a playing soundscape (the
    /// island wing while nothing louder owns the space).
    var symbol: String {
        switch self {
        case .brown: return "water.waves"
        case .white: return "waveform"
        case .pink: return "waveform.path"
        case .rain: return "cloud.rain.fill"
        // Not `flame.fill`: that one is the focus streak counter's, and
        // a streak means something different from a crackling fireplace
        // track. A fireplace is a scene, not a flame.
        case .fire: return "fireplace.fill"
        // Not `cup.and.saucer.fill`: that one is Keep Awake's, the
        // coffee-cup-as-caffeine trope. This is the scene, not the cup.
        case .cafe: return "takeoutbag.and.cup.and.straw.fill"
        }
    }
}

/// What ambience needs from a sound source, and nothing beyond it.
///
/// A protocol for one reason. The focus/ambience coupling rules are
/// about which object calls which method, and a real `NoiseEngine`
/// drags a real audio device into proving them. A machine with no
/// output, which is every CI runner, cannot start one: it reports the
/// failure through `onSilence`, and `active` is cleared on a later
/// main-actor hop. That raced `testAFocusSessionLeavesTheUsersOwnNoise`
/// into failing with no code changing at all, red at 0ea7534 and green
/// at 6910efa with a docs-only commit between them (2026-08-02).
///
/// The seam is the fix. Whether audio hardware exists is a fact about
/// the machine, and it was being allowed to decide a question about
/// this app's own wiring.
protocol AmbienceSource: AnyObject {
    var onSilence: ((String) -> Void)? { get set }
    func start(_ color: NoiseEngine.NoiseColor)
    func stop()
    func pause()
    func resume()
    func setVolume(_ volume: Float)
}

extension NoiseEngine: AmbienceSource {}

/// The one owner of ambient sound. The chips row, focus sessions, and
/// voice commands all speak to this, so "what's playing" has exactly
/// one answer, and the collapsed island can show it.
@MainActor
final class AmbienceController: ObservableObject {
    /// The soundscape currently sounding (nil = silence). Pauses
    /// during focus breaks keep this set, the sound comes back.
    @Published private(set) var active: NoiseEngine.NoiseColor?

    /// Why the last ask made no sound, held until the next one. A lit
    /// chip over silence is a lie the user cannot debug.
    @Published private(set) var failure: String?

    /// Remembered across launches: every other dial in the app is,
    /// and a volume set once should not reset to 0.7 every morning.
    @Published var volume: Double {
        didSet {
            engine.setVolume(Float(volume))
            defaults.set(volume, forKey: Self.volumeKey)
        }
    }

    let engine: AmbienceSource
    private let defaults: UserDefaults
    private static let volumeKey = "ambienceVolume"

    /// Defaults to a real engine, so every caller in the app is
    /// unchanged and only a test ever passes anything else. Same for
    /// the defaults suite (the repo law: a test never touches
    /// `.standard`).
    init(engine: AmbienceSource = NoiseEngine(), defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.volumeKey) as? Double
        self.volume = saved.map { min(max($0, 0), 1) } ?? 0.7
        engine.onSilence = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                self.active = nil
                self.failure = reason
            }
        }
        // An init assignment fires no didSet, so the restored level is
        // handed to the engine by hand; without this a saved 0.3 would
        // play at the engine's own default until the first drag.
        engine.setVolume(Float(volume))
    }

    /// Chip behavior: tap to play, tap the playing one to stop.
    func toggle(_ color: NoiseEngine.NoiseColor) {
        if active == color {
            stop()
        } else {
            play(color)
        }
    }

    func play(_ color: NoiseEngine.NoiseColor) {
        failure = nil
        active = color
        engine.start(color)
    }

    func stop() {
        failure = nil
        active = nil
        engine.stop()
    }

    /// Soft pause (focus breaks): sound fades out, `active` stays.
    func pause() {
        engine.pause()
    }

    func resume() {
        guard active != nil else { return }
        engine.resume()
    }
}
