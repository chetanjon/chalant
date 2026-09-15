import Testing

@testable import ChalantDictationCore

/// The key you hold, and what a stored one is allowed to be.
@Suite("DictationShortcut")
struct DictationShortcutTests {

    /// The default does not move. The founder's own keyboard has no right
    /// Option key at all, so a "quieter default" over there would make
    /// dictation unreachable for the person who uses it most.
    @Test("the default is left Option")
    func defaultIsLeftOption() {
        #expect(DictationShortcut.default == DictationShortcut.leftOption)
        #expect(DictationShortcut.default.keyCode == 58)
        #expect(DictationShortcut.default.flag == 0x0000_0020)
    }

    @Test("storage round-trips, in the same shape the other shortcuts use")
    func storageRoundTrips() {
        for shortcut in DictationShortcut.allCases {
            #expect(DictationShortcut.from(storage: shortcut.storage) == shortcut)
        }
        #expect(DictationShortcut.leftOption.storage == "58:32")
    }

    /// **A stored pair is matched against the offered keys, never trusted.**
    /// A pair that corresponds to no real key would install a tap that never
    /// fires, which is indistinguishable from a permissions problem: this
    /// project has already spent a day on exactly that failure once.
    @Test("a pair that is not an offered key is refused")
    func unknownPairsAreRefused() {
        #expect(DictationShortcut.from(storage: "99:1") == nil)
        #expect(DictationShortcut.from(storage: "58:1") == nil)
        #expect(DictationShortcut.from(storage: "") == nil)
        #expect(DictationShortcut.from(storage: "58") == nil)
        #expect(DictationShortcut.from(storage: "58:32:32") == nil)
        #expect(DictationShortcut.from(storage: "left:option") == nil)
    }

    /// The two Option keys must never be confused. The general
    /// `.maskAlternate` bit cannot tell them apart, which is why these are
    /// the device-dependent bits.
    @Test("the two Option keys are told apart by keycode and by bit")
    func optionKeysAreDistinct() {
        #expect(DictationShortcut.leftOption.keyCode != DictationShortcut.rightOption.keyCode)
        #expect(DictationShortcut.leftOption.flag != DictationShortcut.rightOption.flag)
        #expect(DictationShortcut.leftOption.isDown(keyCode: 61, rawFlags: 0x40) == nil)
        #expect(DictationShortcut.rightOption.isDown(keyCode: 61, rawFlags: 0x40) == true)
    }

    @Test("a flags event for our key reads as down, up, or not ours")
    func readsTheEvent() {
        let key = DictationShortcut.leftOption
        #expect(key.isDown(keyCode: 58, rawFlags: 0x0000_0020) == true)
        #expect(key.isDown(keyCode: 58, rawFlags: 0) == false)
        // Held together with something else: still down.
        #expect(key.isDown(keyCode: 58, rawFlags: 0x0000_0020 | 0x0000_0008) == true)
        // Another key changed; not our business.
        #expect(key.isDown(keyCode: 55, rawFlags: 0x0000_0020) == nil)
    }

    /// Every offered key is reachable and named. A key the picker cannot
    /// show is a key nobody can leave.
    @Test("every offered key has a name and a distinct identity")
    func everyKeyIsUsable() {
        #expect(DictationShortcut.allCases.count == 5)
        #expect(DictationShortcut.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(Set(DictationShortcut.allCases.map(\.storage)).count == DictationShortcut.allCases.count)
    }
}
