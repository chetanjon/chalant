import AppKit
import Carbon.HIToolbox

/// A single global hotkey that summons the island's voice session
/// from anywhere: tap to listen, tap again to run. Carbon's hotkey
/// API needs no accessibility permission and consumes the keystroke,
/// so nothing leaks into the frontmost app.
@MainActor
final class HotkeySummon {
    /// Choices offered in Settings, stored in "summonKey".
    enum Key: String, CaseIterable {
        case off
        case optSpace
        case ctrlSpace
        case cmdShiftSpace

        var carbonModifiers: UInt32? {
            switch self {
            case .off: return nil
            case .optSpace: return UInt32(optionKey)
            case .ctrlSpace: return UInt32(controlKey)
            case .cmdShiftSpace: return UInt32(cmdKey | shiftKey)
            }
        }

        /// The symbol string shown in hints ("⌥␣" reads poorly; use
        /// the key names people say).
        var display: String {
            switch self {
            case .off: return ""
            case .optSpace: return "Option-Space"
            case .ctrlSpace: return "Control-Space"
            case .cmdShiftSpace: return "Command-Shift-Space"
            }
        }
    }

    static let settingKey = "summonKey"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var defaultsObserver: NSObjectProtocol?
    private let onSummon: () -> Void

    static var current: Key {
        Key(rawValue: UserDefaults.standard.string(forKey: settingKey) ?? "optSpace") ?? .optSpace
    }

    init(onSummon: @escaping () -> Void) {
        self.onSummon = onSummon
        installHandler()
        register(Self.current)
        // Settings writes the raw value; re-register on any change.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.register(Self.current)
            }
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let summon = Unmanaged<HotkeySummon>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in summon.onSummon() }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )
    }

    private var registered: Key?

    private func register(_ key: Key) {
        guard key != registered else { return }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registered = key
        guard let modifiers = key.carbonModifiers else { return }
        let id = EventHotKeyID(signature: OSType(0x4D4F_4149), id: 1) // "MOAI"
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("Moai summon: hotkey \(key.rawValue) refused, status \(status)")
        } else {
            NSLog("Moai summon: hotkey \(key.rawValue) registered")
        }
        #if DEBUG
        // Autonomous verification breadcrumb; unified log lines from
        // NSLog interpolation are privacy-redacted and unreadable.
        try? "summon \(key.rawValue) status \(status)\n".write(
            to: URL(fileURLWithPath: "/tmp/moai-summon-debug.txt"),
            atomically: true, encoding: .utf8
        )
        #endif
    }
}
