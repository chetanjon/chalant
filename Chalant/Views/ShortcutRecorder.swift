import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One recordable shortcut: press the button, then press the keys.
///
/// Capture is a local event monitor rather than a first-responder
/// NSView. The dashboard window is key while this is on screen, which
/// is exactly when a local monitor sees keys, and it keeps the whole
/// control in SwiftUI instead of bridging a view just to read a
/// keyDown.
struct ShortcutRow: View {
    let action: HotKeyCenter.Action

    @State private var combo: HotKeyCenter.Combo?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SettingRow(label: action.title) {
                HStack(spacing: Theme.Space.s) {
                    Button(action: toggleRecording) {
                        Text(buttonTitle)
                            .font(Theme.Fonts.captionMono)
                            .foregroundStyle(recording ? accent : Theme.textPrimary)
                            .frame(minWidth: 96)
                            .padding(.vertical, 3)
                            .padding(.horizontal, Theme.Space.m)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.thumb)
                                    .fill(Theme.field)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.Radius.thumb)
                                            .strokeBorder(
                                                recording ? accent : Color.clear, lineWidth: 1
                                            )
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(
                        "\(action.title) shortcut, \(combo?.display ?? "not set")"
                    )
                    // Only offered when there is something to clear, so
                    // the row is not permanently wearing a dead control.
                    if combo != nil, !recording {
                        HoverGlyphButton(
                            symbol: "xmark", label: "Clear this shortcut",
                            scale: .xs, tint: Theme.textTertiary
                        ) {
                            set(nil)
                        }
                        .help("Clear this shortcut")
                    }
                }
            }
            if rejected {
                Text("Add ⌘, ⌥ or ⌃ — a shortcut without one would fire while you type.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
        .onAppear { combo = HotKeyCenter.combo(for: action) }
        // A monitor left installed would keep swallowing keys after the
        // window closes, which reads as the keyboard dying.
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if recording { return "Press keys…" }
        return combo?.display ?? "Not set"
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        rejected = false
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            // Swallowed: while recording, keys are the input to this
            // control and must not also reach whatever is behind it.
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Escape backs out without changing anything; delete clears,
        // matching how every other shortcut field on the platform behaves.
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) && event.modifierFlags.isDisjoint(with: [
            .command, .option, .control,
        ]) {
            set(nil)
            stopRecording()
            return
        }
        let candidate = HotKeyCenter.Combo.from(event: event)
        guard candidate.isSafe else {
            // Stay in recording so the next press can fix it rather
            // than making the user click the button again.
            rejected = true
            return
        }
        set(candidate)
        stopRecording()
    }

    private func set(_ new: HotKeyCenter.Combo?) {
        rejected = false
        combo = new
        HotKeyCenter.shared.setCombo(new, for: action)
    }
}

/// The shortcuts section: every action, one row each.
struct KeyboardSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "Shortcuts") {
                ForEach(
                    Array(HotKeyCenter.Action.allCases.filter(\.isVisible).enumerated()),
                    id: \.element.id
                ) {
                    index, action in
                    if index > 0 { SettingDivider() }
                    ShortcutRow(action: action)
                }
            }

            SettingCard(title: "About shortcuts") {
                SettingNote(
                    "These work anywhere, whatever app you are in. Chalant asks the system to watch "
                    + "for the exact combination you choose, so it never sees anything else you type."
                )
                SettingDivider()
                SettingNote(
                    "If a shortcut does nothing, another app has probably already claimed it. "
                    + "Pick a different one."
                )
            }
        }
    }
}
