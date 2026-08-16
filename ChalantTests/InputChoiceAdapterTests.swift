import AudioToolbox
import ChalantDictationCore
import XCTest

@testable import Chalant

/// The join between Chalant's platform device type and the pure ordering in
/// Core, which dictation shares.
///
/// This exists because the merge's whole argument was that the same
/// dead-microphone bug got fixed twice, once per codebase, since each had its
/// own device ordering. There is one ordering now, and this is the seam it is
/// reached through, so the seam is what has to be right.
final class InputChoiceAdapterTests: XCTestCase {

    private func device(uid: String, name: String, transport: UInt32) -> SystemVolume.InputDevice {
        SystemVolume.InputDevice(id: 0, uid: uid, name: name, transport: transport)
    }

    private var builtInTransport: UInt32 { kAudioDeviceTransportTypeBuiltIn }
    private var usbTransport: UInt32 { kAudioDeviceTransportTypeUSB }

    /// The Mac's own microphone survives the crossing intact.
    func testTheBuiltInMicIsCarriedAcross() {
        let mapped = device(
            uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone",
            transport: builtInTransport
        ).asInputChoice(isSystemDefault: true)

        XCTAssertTrue(mapped.isBuiltInMic)
        XCTAssertFalse(mapped.isJack)
        XCTAssertTrue(mapped.isSystemDefault)
        XCTAssertEqual(mapped.uid, "BuiltInMicrophoneDevice")
    }

    /// The trap, and it is not hypothetical: the headphone jack reports the
    /// BUILT-IN transport, so transport alone calls an empty socket the Mac's
    /// own microphone. It was seen live as a dead "External Microphone" that
    /// was really BuiltInHeadphoneInputDevice. If this mapping ever gets it
    /// wrong, the ordering puts a dead socket first and the app hears nothing.
    func testTheHeadphoneJackIsNotTheBuiltInMic() {
        let mapped = device(
            uid: "BuiltInHeadphoneInputDevice", name: "External Microphone",
            transport: builtInTransport
        ).asInputChoice(isSystemDefault: false)

        XCTAssertFalse(mapped.isBuiltInMic, "an empty socket is not a microphone")
        XCTAssertTrue(mapped.isJack)
    }

    func testARealExternalIsNeitherBuiltInNorJack() {
        let mapped = device(uid: "USB-Yeti", name: "Blue Yeti", transport: usbTransport)
            .asInputChoice(isSystemDefault: true)

        XCTAssertFalse(mapped.isBuiltInMic)
        XCTAssertFalse(mapped.isJack)
        XCTAssertTrue(mapped.isSystemDefault)
    }

    /// End to end through the shared ordering: a device the user pinned still
    /// loses its place once it has been caught delivering exact silence.
    ///
    /// This is the lid-closed case that cost an evening. The built-in mic is
    /// the system default and the preferred device, and with the lid shut it
    /// returns exactly 0.0 while a wired earphone mic sitting right there
    /// hears fine. Preference cannot be the last word.
    func testAPinnedDeviceProvenSilentGoesToTheBack() {
        let devices = [
            device(uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone",
                   transport: builtInTransport),
            device(uid: "BuiltInHeadphoneInputDevice", name: "External Microphone",
                   transport: builtInTransport),
        ]
        let mapped = devices.map { $0.asInputChoice(isSystemDefault: $0.uid == "BuiltInMicrophoneDevice") }

        let healthy = InputChoice.order(mapped, pinnedUID: "BuiltInMicrophoneDevice", silent: [])
        XCTAssertEqual(healthy.first?.uid, "BuiltInMicrophoneDevice",
                       "with no evidence against it, the pin wins")

        let deaf = InputChoice.order(
            mapped, pinnedUID: "BuiltInMicrophoneDevice", silent: ["BuiltInMicrophoneDevice"])
        XCTAssertEqual(deaf.first?.uid, "BuiltInHeadphoneInputDevice",
                       "proven silent means proven silent, pinned or not")
        XCTAssertEqual(deaf.last?.uid, "BuiltInMicrophoneDevice")
    }

    /// The watchdog's deadline and its verdict have to agree. They were two
    /// separate numbers once, which is how a threshold drifts away from the
    /// delay that feeds it.
    func testTheWatchdogVerdictMatchesItsOwnDeadline() {
        XCTAssertTrue(
            InputChoice.isDead(peak: 0, silentFor: VoiceController.watchdogDelay,
                               threshold: VoiceController.watchdogDelay))
        XCTAssertFalse(
            InputChoice.isDead(peak: 0.01, silentFor: VoiceController.watchdogDelay,
                               threshold: VoiceController.watchdogDelay),
            "a quiet room is not a dead microphone")
    }
}
