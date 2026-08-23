import Foundation

/// Which microphone to listen to, and when to stop believing in one.
///
/// The requirement (founder, 2026-08-12): "the mic should always work even
/// when lid closed or open or wired or not or wireless etc etc."
///
/// What made it one: with the lid closed, the built-in microphone delivers
/// **exactly** `0.0` across 240,000 frames while the Mac speaks aloud, and it
/// is still the system default. A wired earphone mic was plugged in the whole
/// time, reading 0.094 on room noise alone, and nothing ever tried it. The app
/// captured 59 buffers of nothing and showed "Listening…" the entire time.
///
/// CLAUDE.md line 1575 prefers the built-in mic, and on quality it is right:
/// Bluetooth mics are worse, add latency, and downgrade system audio while
/// active. But preference cannot be the last word, because a preferred device
/// that delivers silence is not a microphone. **Evidence outranks preference,
/// and this type is where that is decided.**
///
/// The threshold comes from the parent Chalant project, measured rather than
/// assumed: a live mic in a quiet room still reads about 0.01 of floor tone,
/// while a dead one reads 0.00 exactly. So any sound at all, down to the
/// smallest representable sample, vetoes the verdict.
public enum InputChoice {

    /// One attachable input, with only the facts the choice turns on.
    public struct Device: Sendable, Equatable {
        /// The stable identity. Names are duplicated and localised; the UID is
        /// what can be remembered across launches and compared safely.
        public let uid: String
        public let name: String
        /// The Mac's own microphone. Transport alone cannot tell you this:
        /// the headphone jack ALSO reports the built-in transport (seen live
        /// in the parent project as a dead "External Microphone" that is
        /// really `BuiltInHeadphoneInputDevice`), so the UID is the truth.
        public let isBuiltInMic: Bool
        /// The headphone jack. Usually an empty socket, which is why it trails
        /// everything, and which is also why it must be able to win outright
        /// the moment it proves it can hear.
        public let isJack: Bool
        public let isSystemDefault: Bool
        /// A phone or tablet offering itself over Continuity (CoreAudio
        /// transport 'ccwd'/'ccwl'). It becomes the system default the
        /// moment it appears and vanishes when the phone sleeps or leaves:
        /// on 2026-08-23 the founder's iPhone did exactly that as "Cj
        /// Microphone" and every hold after it heard nothing. Identified by
        /// transport, never by name: a phone's mic is named after its owner.
        public let isPhoneLink: Bool

        public init(
            uid: String, name: String, isBuiltInMic: Bool = false,
            isJack: Bool = false, isSystemDefault: Bool = false,
            isPhoneLink: Bool = false
        ) {
            self.uid = uid
            self.name = name
            self.isBuiltInMic = isBuiltInMic
            self.isJack = isJack
            self.isSystemDefault = isSystemDefault
            self.isPhoneLink = isPhoneLink
        }
    }

    /// The order to try inputs in. Every device appears exactly once.
    ///
    /// Preference decides the order; evidence overrules it. Anything in
    /// `silent` is sent to the back whatever else it had going for it,
    /// including having been pinned by the user, because a device that has
    /// been proven to deliver nothing cannot be the answer to "why can't it
    /// hear me".
    public static func order(
        _ devices: [Device], pinnedUID: String?, silent: Set<String>
    ) -> [Device] {
        var ordered: [Device] = []
        func add(_ device: Device?) {
            guard let device, !ordered.contains(where: { $0.uid == device.uid }) else { return }
            ordered.append(device)
        }

        // A phone's Continuity mic is exiled from AUTOMATIC choice exactly
        // like the conferencing loopbacks: it follows the phone, not the
        // person at the Mac. A pin still wins below.
        let heard = devices.filter {
            !silent.contains($0.uid) && !isKnownVirtual(name: $0.name) && !$0.isPhoneLink
        }

        // The user's own choice, while it is still delivering audio. A pin
        // is an instruction, so a pinned virtual device is honored; only
        // AUTOMATIC choices refuse them.
        if let pinnedUID {
            add(devices.first { $0.uid == pinnedUID && !silent.contains($0.uid) })
        }
        // Quality preference (CLAUDE.md 1575), among devices still believed
        // alive: the Mac's own mic, then the system default if it is a real
        // external input, then anything that is not the jack, then the jack.
        add(heard.first { $0.isBuiltInMic })
        add(heard.first { $0.isSystemDefault && !$0.isJack })
        heard.filter { !$0.isJack }.forEach { add($0) }
        heard.forEach { add($0) }
        // Everything proven silent, in its original order, last.
        devices.forEach { add($0) }
        return ordered
    }

    /// Inputs that exist for routing app audio, not for hearing a person:
    /// conferencing loopbacks and virtual cables. Automatic selection must
    /// never land on one: on 2026-08-20 a dead built-in mic hopped to
    /// "Microsoft Teams Audio" and spent two more silent seconds there
    /// before finding the real microphone. A user who PINS one still gets
    /// it, because a pin is an instruction.
    public static func isKnownVirtual(name: String) -> Bool {
        let lowered = name.lowercased()
        let virtual = [
            "teams audio", "zoomaudiodevice", "zoom audio", "blackhole",
            "loopback", "soundflower", "vb-cable", "krisp",
        ]
        return virtual.contains { lowered.contains($0) }
    }

    /// Whether a device has stopped being a microphone.
    ///
    /// Exactly zero, and sustained. A quiet room is not a dead mic, and
    /// hopping away from a good input because nobody happened to be speaking
    /// would be its own bug.
    public static func isDead(
        peak: Float, silentFor seconds: TimeInterval, threshold: TimeInterval = 2.0
    ) -> Bool {
        peak == 0 && seconds >= threshold
    }
}
