import Foundation

/// The key you hold to talk.
///
/// **Left Option was hard-coded, and the cost was measured rather than
/// imagined.** `Option+←` and `Option+→` move by word, `Option+Delete` deletes
/// one, and `Option+e` starts an accent: all of them are a left-Option press,
/// so all of them opened the dictation light, woke the microphone, warmed a
/// language model, and paused whatever the user was listening to. The
/// activation state machine cancels those now, and this type is the other
/// half: if the collisions are still a nuisance, move the gesture.
///
/// **Bare modifiers only, deliberately.** A modifier never produces
/// keyDown/keyUp, only `.flagsChanged`, and press-and-hold is read off the
/// device-dependent bit for that specific physical key. Offering ordinary
/// keys as well would mean a second detection path watching `.keyDown` for
/// the gesture itself, which is a much larger thing to trust than a tap that
/// only ever reads modifier state and a keycode. `HotKeyCenter` cannot serve
/// this either: it is Carbon `RegisterEventHotKey`, which fires on a press
/// rather than reporting a hold, and its `Combo.isSafe` refuses a bare
/// modifier outright.
///
/// Pure, Foundation only, tested in `DictationShortcutTests`.
public struct DictationShortcut: Sendable, Hashable, CaseIterable {

    /// The physical key's virtual keycode, as `.flagsChanged` reports it.
    public let keyCode: UInt16
    /// The device-dependent modifier bit that is set while THIS key is down.
    ///
    /// The general masks (`.maskAlternate`, `.maskCommand`) cannot tell the
    /// two Option keys apart, which is why these are the device bits from
    /// `IOLLEvent.h` rather than `CGEventFlags`.
    public let flag: UInt64
    /// What Settings calls it.
    public let label: String

    public init(keyCode: UInt16, flag: UInt64, label: String) {
        self.keyCode = keyCode
        self.flag = flag
        self.label = label
    }

    // MARK: - The offered keys

    /// `kVK_Option` with `NX_DEVICELALTKEYMASK`.
    ///
    /// The default, and it stays the default: the founder's keyboard has no
    /// right Option key at all, so moving the default there would make
    /// dictation unreachable for the person who uses it most.
    public static let leftOption = DictationShortcut(
        keyCode: 58, flag: 0x0000_0020, label: "Left Option")
    /// `kVK_RightOption` with `NX_DEVICERALTKEYMASK`. The quietest choice on a
    /// full-size keyboard: almost nothing binds it.
    public static let rightOption = DictationShortcut(
        keyCode: 61, flag: 0x0000_0040, label: "Right Option")
    /// `kVK_RightCommand` with `NX_DEVICERCMDKEYMASK`.
    public static let rightCommand = DictationShortcut(
        keyCode: 54, flag: 0x0000_0010, label: "Right Command")
    /// `kVK_RightControl` with `NX_DEVICERCTLKEYMASK`.
    public static let rightControl = DictationShortcut(
        keyCode: 62, flag: 0x0000_2000, label: "Right Control")
    /// `kVK_Function` with `NX_SECONDARYFNMASK`. No device-dependent bit
    /// exists for Fn, so this is the general one; there is only one Fn key,
    /// so nothing is being confused with anything.
    public static let function = DictationShortcut(
        keyCode: 63, flag: 0x0080_0000, label: "Fn")

    public static let allCases: [DictationShortcut] = [
        .leftOption, .rightOption, .rightCommand, .rightControl, .function,
    ]

    public static let `default` = DictationShortcut.leftOption

    // MARK: - Storage

    /// `"keyCode:flag"`, the same shape `HotKeyCenter.Combo.storage` uses, so
    /// a person reading their own defaults finds one convention rather than
    /// two. A half-written pair can never be read back.
    public var storage: String { "\(keyCode):\(flag)" }

    /// Reads a stored pair back, and only ever returns a key this build
    /// offers.
    ///
    /// **Matched against the offered list rather than trusted.** A stored
    /// pair that no longer corresponds to any real key would install a tap
    /// that never fires, which is indistinguishable from a permissions
    /// problem and is exactly the failure this project has already spent a
    /// day on.
    public static func from(storage: String) -> DictationShortcut? {
        let parts = storage.split(separator: ":")
        guard parts.count == 2, let keyCode = UInt16(parts[0]), let flag = UInt64(parts[1])
        else { return nil }
        return allCases.first { $0.keyCode == keyCode && $0.flag == flag }
    }

    /// Whether a `.flagsChanged` event is this key going down.
    ///
    /// Takes the keycode and the raw flags rather than the event, so the
    /// decision is pure and a test can drive it without a Mac in any state.
    public func isDown(keyCode: UInt16, rawFlags: UInt64) -> Bool? {
        guard keyCode == self.keyCode else { return nil }
        return rawFlags & flag != 0
    }
}
