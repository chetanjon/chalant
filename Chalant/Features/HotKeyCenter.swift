import AppKit
import Carbon.HIToolbox
import os

/// System-wide shortcuts, through Carbon's `RegisterEventHotKey`.
///
/// The obvious alternative, `NSEvent.addGlobalMonitorForEvents`, would
/// put an Accessibility permission prompt in front of a convenience
/// feature and hand the app the ability to read every keystroke the
/// user types anywhere. Carbon's hot key API asks for neither: the
/// system matches the combination and calls back only on that one, so
/// Chalant never sees a key it was not given. It is old, it is C, and
/// it is the right trade.
@MainActor
final class HotKeyCenter {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "hotkeys")

    /// What a shortcut can be pointed at. Deliberately short: every
    /// entry here is a door into the island, and a list of twenty
    /// bindings is a thing nobody configures.
    enum Action: String, CaseIterable, Identifiable {
        case toggleIsland
        case talk
        case ask
        case clipboard
        case shelf
        case notes
        case shortcuts
        case focus
        case openSettings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .toggleIsland: return "Open or close the island"
            case .talk: return "Start listening"
            case .ask: return "Ask something"
            case .clipboard: return "Open the clipboard"
            case .shelf: return "Open the shelf"
            case .notes: return "Open notes"
            case .shortcuts: return "Open shortcuts"
            case .focus: return "Open focus and timers"
            case .openSettings: return "Open settings"
            }
        }

        var defaultsKey: String { "hotkey.\(rawValue)" }

        /// The panel this shortcut opens, for the ones that open one.
        /// Kept here rather than as a closure each in the app delegate:
        /// they are one behaviour with a different destination, and
        /// spelling it out nine times invites nine slightly different
        /// versions of it.
        var tab: NotchViewModel.Tab? {
            switch self {
            case .ask: return .ask
            case .clipboard: return .clipboard
            case .shelf: return .shelf
            case .notes: return .notes
            case .shortcuts: return .links
            case .focus: return .focus
            case .toggleIsland, .talk, .openSettings: return nil
            }
        }
    }

    /// A combination, in Carbon's own units so nothing is converted at
    /// the moment it matters. `keyCode` is a virtual key code, which is
    /// layout-independent: the shortcut stays on the same physical key
    /// when the user switches to another keyboard layout.
    struct Combo: Equatable {
        var keyCode: UInt32
        /// Carbon modifier mask (`cmdKey`, `optionKey`, …).
        var modifiers: UInt32

        /// Stored as one string so a binding is a single defaults key
        /// and a half-written pair can never be read back.
        var storage: String { "\(keyCode):\(modifiers)" }

        init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        init?(storage: String) {
            let parts = storage.split(separator: ":")
            guard parts.count == 2,
                  let code = UInt32(parts[0]), let mods = UInt32(parts[1])
            else { return nil }
            self.keyCode = code
            self.modifiers = mods
        }

        /// A shortcut with no modifier would swallow a bare keystroke
        /// system-wide — typing "t" anywhere would open the island.
        /// Shift alone is no better: it is half of ordinary typing.
        var isSafe: Bool {
            modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        }

        static func from(event: NSEvent) -> Combo {
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
            return Combo(keyCode: UInt32(event.keyCode), modifiers: mods)
        }

        /// "⌥⌘Space", in the order macOS writes modifiers.
        var display: String {
            var text = ""
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            return text + Self.keyName(keyCode)
        }

        /// Named keys first, because a bare virtual code renders as
        /// nothing readable for space, return and the arrows.
        static func keyName(_ code: UInt32) -> String {
            switch Int(code) {
            case kVK_Space: return "Space"
            case kVK_Return: return "Return"
            case kVK_Tab: return "Tab"
            case kVK_Escape: return "Esc"
            case kVK_Delete: return "Delete"
            case kVK_LeftArrow: return "←"
            case kVK_RightArrow: return "→"
            case kVK_UpArrow: return "↑"
            case kVK_DownArrow: return "↓"
            default: break
            }
            if let literal = characterFor(keyCode: code) {
                return literal.uppercased()
            }
            return "Key \(code)"
        }

        /// Asks the active layout what the key produces, so a shortcut
        /// reads as the letter actually printed on the user's keyboard
        /// rather than the US one.
        private static func characterFor(keyCode: UInt32) -> String? {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress
                else { return -1 }
                return UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys, characters.count, &length, &characters
                )
            }
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    static let shared = HotKeyCenter()

    /// What each action does, handed over by whoever owns the island.
    var handlers: [Action: () -> Void] = [:]

    private var registered: [Action: EventHotKeyRef] = [:]
    /// Carbon identifies a fired hot key by a number, so this is the way
    /// back from that number to the action it belongs to.
    private var actionsByID: [UInt32: Action] = [:]
    private var installedHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    // MARK: Bindings

    static func combo(for action: Action) -> Combo? {
        UserDefaults.standard.string(forKey: action.defaultsKey).flatMap(Combo.init(storage:))
    }

    /// Persists and re-registers in one step: a stored binding the
    /// system does not know about is the failure this feature is most
    /// likely to have, so the two never move apart.
    func setCombo(_ combo: Combo?, for action: Action) {
        if let combo, combo.isSafe {
            UserDefaults.standard.set(combo.storage, forKey: action.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        reload()
    }

    // MARK: Registration

    /// Drops every registration and re-reads the lot. Called on launch
    /// and after any change; there are three of these, so rebuilding
    /// all of them is cheaper than tracking which one moved.
    func reload() {
        installHandlerIfNeeded()
        for (_, ref) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        actionsByID.removeAll()

        for action in Action.allCases {
            guard let combo = Self.combo(for: action), combo.isSafe else { continue }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(
                combo.keyCode, combo.modifiers, hotKeyID,
                GetApplicationEventTarget(), 0, &ref
            )
            // Another app already owns the combination, or the system
            // reserved it. Nothing to do but leave it unbound; the
            // settings row still shows what the user chose.
            guard status == noErr, let ref else {
                Self.log.error(
                    "hotkey \(action.rawValue, privacy: .public) refused, status \(status)")
                continue
            }
            registered[action] = ref
            actionsByID[id] = action
        }
    }

    private static let signature: OSType = 0x43_48_4C_54  // 'CHLT'

    private func installHandlerIfNeeded() {
        guard installedHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                guard status == noErr, id.signature == HotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers on the main thread, but the isolation
                // is not visible to the compiler through a C callback.
                let fired = id.id
                Task { @MainActor in HotKeyCenter.shared.fire(id: fired) }
                return noErr
            },
            1, &spec, nil, &installedHandler
        )
    }

    private func fire(id: UInt32) {
        guard let action = actionsByID[id] else { return }
        handlers[action]?()
    }
}
