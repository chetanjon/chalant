import Testing

@testable import ChalantDictationCore

/// Which microphone to listen to, and when to give up on one.
///
/// The founder's requirement, 2026-08-12: "the mic should always work even
/// when lid closed or open or wired or not or wireless etc etc."
///
/// What made that a requirement, measured the same night: with the laptop lid
/// closed, the built-in microphone delivers **exactly** `0.0` across 240,000
/// frames while the Mac is speaking aloud, and it was still the system
/// default. A wired earphone mic was plugged in the whole time, reading 0.094
/// on room noise alone, and nothing ever tried it.
///
/// So preference alone cannot decide this. CLAUDE.md line 1575 says prefer
/// built-in, and that is right on quality (Bluetooth mics are worse and add
/// latency), but a preferred device that delivers silence has to lose to one
/// that works. Evidence outranks preference.
///
/// The 0.0 threshold is not a guess. The parent Chalant project measured it:
/// a live mic in a quiet room still reads about 0.01 of floor tone, while a
/// dead one reads 0.00 exactly, so any sound at all vetoes the verdict.
@Suite("InputChoice")
struct InputChoiceTests {

    private func device(
        _ name: String, uid: String? = nil, builtInMic: Bool = false,
        jack: Bool = false, isDefault: Bool = false
    ) -> InputChoice.Device {
        InputChoice.Device(
            uid: uid ?? name, name: name, isBuiltInMic: builtInMic,
            isJack: jack, isSystemDefault: isDefault)
    }

    /// Tonight's machine, exactly as it was found.
    private var tonight: [InputChoice.Device] {
        [
            device("External Microphone", uid: "BuiltInHeadphoneInputDevice", jack: true),
            device("MacBook Air Microphone", uid: "BuiltInMicrophoneDevice",
                   builtInMic: true, isDefault: true),
            device("Microsoft Teams Audio", uid: "TeamsVirtual"),
        ]
    }

    @Test("with nothing known to be dead, the built-in mic leads")
    func builtInLeadsWhenNothingIsKnown() {
        let order = InputChoice.order(tonight, pinnedUID: nil, silent: [])
        #expect(order.first?.isBuiltInMic == true)
    }

    /// 2026-08-20, the founder's afternoon: the dead built-in hopped to
    /// "Microsoft Teams Audio" and spent two more silent seconds on a device
    /// that exists for routing app audio, not for hearing a person. An
    /// automatic choice never lands on a virtual input; a PIN still does,
    /// because a pin is an instruction.
    @Test("virtual devices are never chosen automatically, but a pin wins")
    func virtualDevicesSinkUnlessPinned() {
        let order = InputChoice.order(
            tonight, pinnedUID: nil, silent: ["BuiltInMicrophoneDevice"])
        #expect(order.first?.name == "External Microphone")
        #expect(InputChoice.isKnownVirtual(name: "Microsoft Teams Audio"))
        #expect(!InputChoice.isKnownVirtual(name: "MacBook Air Microphone"))
        let pinned = InputChoice.order(tonight, pinnedUID: "TeamsVirtual", silent: [])
        #expect(pinned.first?.uid == "TeamsVirtual")
    }

    /// THE REQUIREMENT. Once the built-in is known to deliver nothing it must
    /// stop leading and go to the back, however preferred it used to be.
    ///
    /// Deliberately NOT asserting which device inherits first place. The app
    /// cannot tell a plugged-in earphone from an empty socket by name, so the
    /// runner-up order is a preference; what makes the feature work is that a
    /// proven-silent device sinks and the hop continues until something
    /// hears. Asserting the jack here would be encoding tonight's desk into a
    /// test.
    @Test("a device known to be silent sinks below everything that hears")
    func silentDeviceSinks() {
        let order = InputChoice.order(
            tonight, pinnedUID: nil, silent: ["BuiltInMicrophoneDevice"])
        #expect(order.first?.isBuiltInMic == false)
        // Below every heard device; only the virtual routers, which were
        // never microphones at all, may sit lower (2026-08-20).
        let uids = order.map(\.uid)
        let silentAt = uids.firstIndex(of: "BuiltInMicrophoneDevice")!
        let heardAt = uids.firstIndex(of: "BuiltInHeadphoneInputDevice")!
        #expect(silentAt > heardAt)
    }

    /// The lid-closed case end to end: the only device that hears anything is
    /// the jack, which is normally queued last because on a Mac it is usually
    /// the dead one.
    @Test("the jack wins when it is the only ear that hears")
    func jackWinsWhenItIsAllThereIs() {
        let order = InputChoice.order(
            tonight, pinnedUID: nil,
            silent: ["BuiltInMicrophoneDevice", "TeamsVirtual"])
        #expect(order.first?.uid == "BuiltInHeadphoneInputDevice")
    }

    /// The jack claims the built-in transport, so it cannot be identified by
    /// transport alone. Absent evidence it still queues last, because on most
    /// Macs it is an empty socket.
    @Test("the jack trails every real device until evidence says otherwise")
    func jackTrailsByDefault() {
        let order = InputChoice.order(tonight, pinnedUID: nil, silent: [])
        // Behind the built-in; only the virtual routers sit lower.
        let uids = order.map(\.uid)
        let jackAt = uids.firstIndex(of: "BuiltInHeadphoneInputDevice")!
        let builtInAt = uids.firstIndex(of: "BuiltInMicrophoneDevice")!
        #expect(jackAt > builtInAt)
        #expect(InputChoice.isKnownVirtual(name: order.last?.name ?? ""))
    }

    @Test("a pinned device leads, because the user said so")
    func pinnedLeads() {
        let order = InputChoice.order(tonight, pinnedUID: "TeamsVirtual", silent: [])
        #expect(order.first?.uid == "TeamsVirtual")
    }

    /// Even a pin cannot outrank evidence. A pinned device that delivers
    /// nothing would strand the user exactly as tonight stranded them, with
    /// the added insult that they chose it once and cannot see why it stopped.
    @Test("a pinned device that is silent still sinks")
    func pinnedButSilentSinks() {
        let order = InputChoice.order(
            tonight, pinnedUID: "TeamsVirtual", silent: ["TeamsVirtual"])
        #expect(order.first?.uid != "TeamsVirtual")
        #expect(order.last?.uid == "TeamsVirtual")
    }

    @Test("every device appears exactly once, whatever the rules")
    func noDeviceIsLostOrDuplicated() {
        for silent in [[], ["BuiltInMicrophoneDevice"], ["BuiltInMicrophoneDevice", "TeamsVirtual"]] {
            let order = InputChoice.order(tonight, pinnedUID: "TeamsVirtual", silent: Set(silent))
            #expect(order.count == tonight.count)
            #expect(Set(order.map(\.uid)).count == tonight.count)
        }
    }

    @Test("no devices at all is empty, not a crash")
    func emptyIsEmpty() {
        #expect(InputChoice.order([], pinnedUID: "x", silent: ["y"]).isEmpty)
    }

    // MARK: - When to call a microphone dead

    /// Exactly zero, and only exactly zero. A quiet room is not a dead mic.
    @Test("silence is exactly zero, sustained")
    func silenceIsExactlyZeroSustained() {
        #expect(InputChoice.isDead(peak: 0, silentFor: 2.5))
        #expect(!InputChoice.isDead(peak: 0, silentFor: 0.5))
        // Measured floor tone of a live mic in a quiet room.
        #expect(!InputChoice.isDead(peak: 0.01, silentFor: 60))
        // The earphone mic, on room noise alone, on the night this was written.
        #expect(!InputChoice.isDead(peak: 0.093, silentFor: 60))
    }

    @Test("the smallest sample there is still vetoes the verdict")
    func anySoundVetoes() {
        #expect(!InputChoice.isDead(peak: .leastNonzeroMagnitude, silentFor: 3600))
    }

    /// 2026-08-23: the founder's iPhone offered itself over Continuity as
    /// "Cj Microphone", became the system default, won the automatic
    /// choice, then vanished and left the ear deaf. A phone is never an
    /// automatic answer to "which microphone"; a pin still is.
    @Test("a phone's Continuity mic is never chosen automatically, but a pin wins")
    func phoneLinkSinksUnlessPinned() {
        let phone = InputChoice.Device(
            uid: "continuity-1", name: "Cj Microphone", isSystemDefault: true, isPhoneLink: true)
        let builtIn = InputChoice.Device(
            uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone", isBuiltInMic: true)
        let ordered = InputChoice.order([phone, builtIn], pinnedUID: nil, silent: [])
        #expect(ordered.first?.uid == builtIn.uid)
        #expect(ordered.last?.uid == phone.uid)
        let pinned = InputChoice.order([phone, builtIn], pinnedUID: "continuity-1", silent: [])
        #expect(pinned.first?.uid == phone.uid)
        // A phone that is also the only device still comes last on paper but
        // is the one that gets tried: everything appears exactly once.
        #expect(InputChoice.order([phone], pinnedUID: nil, silent: []).count == 1)
    }
}
