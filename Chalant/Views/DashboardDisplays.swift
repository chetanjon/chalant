import AppKit
import SwiftUI

/// Per-screen island settings.
///
/// Screens are held as plain values, never as `NSScreen`: AppKit
/// recreates those objects at will and a held one goes stale silently,
/// so the list is rebuilt from the current screens each time and every
/// write goes through the stable UUID key.
struct DisplaysSection: View {
    @ObservedObject var displays: DisplayConfigStore

    /// One attached screen, flattened to what the pane needs.
    private struct Attached: Identifiable, Equatable {
        let id: String
        let name: String
        let pixels: String
        let hasHardwareNotch: Bool
        let isMain: Bool
        /// The measured cutout, so "Match the notch" can seed the
        /// sliders from what is actually there instead of jumping to
        /// the emulated 196x38 default the moment it is turned off
        /// (W-D, 2026-08-02).
        let cutout: CGSize?
    }

    @State private var attached: [Attached] = []
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.settingsGroup) {
            if attached.isEmpty {
                SettingCard(title: "Displays") {
                    Text("No displays reported a stable identity.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                    SettingNote(
                        "Chalant files these settings under each display's own identifier so they "
                        + "survive a reboot and a replug. A display that will not report one cannot "
                        + "be remembered."
                    )
                }
            } else {
                SettingCard(title: "Display") {
                    ForEach(Array(attached.enumerated()), id: \.element.id) { index, screen in
                        if index > 0 { SettingDivider() }
                        row(screen)
                    }
                }
                if let current {
                    settings(for: current)
                }
            }
        }
        .onAppear(perform: refresh)
        // Plugging or unplugging a display while this is open must
        // change the list, not leave a row pointing at nothing.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in refresh() }
    }

    private var current: Attached? {
        attached.first { $0.id == selection } ?? attached.first
    }

    // MARK: Picker

    private func row(_ screen: Attached) -> some View {
        let selected = current?.id == screen.id
        return Button {
            selection = screen.id
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: screen.hasHardwareNotch ? "laptopcomputer" : "display")
                    .font(Theme.Fonts.icon(.m))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(screen.name)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(rowCaption(screen))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: Theme.Space.m)
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// Says the one thing that actually decides how the island behaves
    /// on this screen. Two displays used to read "2560 x 1440 · main"
    /// and "3024 x 1964", which are the least useful facts about them:
    /// what matters is that one has a cutout to cling to and the other
    /// has nothing, and that is why their islands differ (founder,
    /// 2026-08-10, "there should be difference between monitor island
    /// and mac island in the settings"). The icon said it already, at
    /// the size of an icon.
    private func rowCaption(_ screen: Attached) -> String {
        var parts = [screen.pixels]
        parts.append(screen.hasHardwareNotch ? "has a notch" : "no notch")
        if screen.isMain { parts.append("main") }
        return parts.joined(separator: " · ")
    }

    // MARK: Settings for the selected screen

    @ViewBuilder
    private func settings(for screen: Attached) -> some View {
        let config = displays.config(forKey: screen.id)
        let resolved = DisplayConfigStore.resolve(
            config.style, hasHardwareNotch: screen.hasHardwareNotch)

        SettingCard(title: "Shape") {
            SettingPicker(
                label: "Style",
                selection: binding(screen, \.style),
                options: DisplayConfigStore.Style.allCases.map { ($0.title, $0) },
                width: 236
            )
            SettingNote(
                config.style == .auto
                    ? "Automatic follows the hardware, and picks \(resolved.title.lowercased()) here."
                    : styleNote(resolved)
            )
        }

        if resolved != .off {
            // Notch only. A pill sizes itself, so under Pill this card
            // held one sentence explaining that it had no controls: a
            // heading, a rule and a line of prose saying "nothing
            // here". That reads as clutter on a page the founder
            // already called busy, and the sentence belongs beside the
            // Style picker that causes it, which is where it lives now.
            if resolved == .notch {
                SettingCard(title: "Size") {
                // Width and Height write notchSize, which only the
                // notch render path reads (NotchWindowController.swift
                // apply(_:to:) -> NotchRootView.collapsedSize); a
                // pill's collapsed shape comes from what it is showing
                // instead. Offering these sliders under Pill was a
                // control that could not move anything, and the note
                // used to send people straight at it - "Choose Pill to
                // set a size by hand" was the one mode where it did
                // nothing (founder decision, 2026-08-01: drop the
                // sliders rather than wire them up, no migration).
                    if screen.hasHardwareNotch {
                        SettingToggle(
                            label: "Match the notch",
                            isOn: matchesHardwareBinding(screen))
                        if config.sizeFollowsHardware {
                            SettingNote(
                                "This display has its own notch, so Chalant measures it rather "
                                + "than guessing."
                            )
                        } else {
                            SettingDivider()
                            slider(
                                "Width", screen, \.width,
                                range: DisplayConfigStore.Config.widthRange, unit: "pt")
                            SettingDivider()
                            slider(
                                "Height", screen, \.height,
                                range: DisplayConfigStore.Config.heightRange, unit: "pt")
                        }
                    } else {
                        slider(
                            "Width", screen, \.width,
                            range: DisplayConfigStore.Config.widthRange, unit: "pt")
                        SettingDivider()
                        slider(
                            "Height", screen, \.height,
                            range: DisplayConfigStore.Config.heightRange, unit: "pt")
                    }
                }
            }

            SettingCard(title: "Shaping") {
                slider(
                    "Corner radius", screen, \.cornerRadius,
                    range: DisplayConfigStore.Config.cornerRange, unit: "pt")
                SettingDivider()
                slider(
                    "Inner padding", screen, \.contentPadding,
                    range: DisplayConfigStore.Config.paddingRange, unit: "pt")
                SettingNote("Room down each side of the island when it is open.")
                SettingDivider()
                slider(
                    "Expanded width", screen, \.expandedWidth,
                    range: DisplayConfigStore.Config.expandedWidthRange, unit: "pt")
                SettingDivider()
                slider(
                    "Minimum height", screen, \.expandedMinHeight,
                    range: DisplayConfigStore.Config.expandedMinHeightRange, unit: "pt")
                SettingNote("The island grows past this when what is open needs more room.")
            }
        }

        SettingCard(title: "Start over") {
            Button("Reset this display") {
                displays.reset(forKey: screen.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            SettingNote("Puts this display back to following the hardware.")
        }
    }

    private func styleNote(_ resolved: DisplayConfigStore.Style) -> String {
        switch resolved {
        case .notch: return "Wraps a notch, real or emulated, and keeps content clear of it."
        // The size sentence lives here, beside the choice that causes
        // it, rather than in a Size card with nothing else in it.
        case .pill:
            return "A free-floating bar with nothing to clear, so content runs full width. "
                + "It hugs whatever it is showing and sizes itself; choose Notch to set a size "
                + "by hand."
        case .off: return "No island on this display at all."
        case .auto: return ""
        }
    }

    // MARK: Plumbing

    private func binding<V>(
        _ screen: Attached, _ path: WritableKeyPath<DisplayConfigStore.Config, V>
    ) -> Binding<V> {
        Binding(
            get: { displays.config(forKey: screen.id)[keyPath: path] },
            set: { newValue in
                var config = displays.config(forKey: screen.id)
                config[keyPath: path] = newValue
                displays.set(config, forKey: screen.id)
            }
        )
    }

    /// "Match the notch", with one side effect a plain `binding` cannot
    /// carry: turning it off seeds `width`/`height` from what this
    /// screen actually measured, so the sliders that appear start at
    /// the real size instead of jumping to the emulated 196x38 default
    /// (W-D, 2026-08-02).
    private func matchesHardwareBinding(_ screen: Attached) -> Binding<Bool> {
        Binding(
            get: { displays.config(forKey: screen.id).sizeFollowsHardware },
            set: { newValue in
                var config = displays.config(forKey: screen.id)
                config.sizeFollowsHardware = newValue
                if !newValue, let cutout = screen.cutout {
                    config.width = cutout.width
                    config.height = cutout.height
                }
                displays.set(config, forKey: screen.id)
            }
        )
    }

    private func slider(
        _ label: String,
        _ screen: Attached,
        _ path: WritableKeyPath<DisplayConfigStore.Config, CGFloat>,
        range: ClosedRange<CGFloat>,
        unit: String
    ) -> some View {
        // The store speaks CGFloat and ThinSlider speaks Double, and a
        // Binding of one is not a Binding of the other however freely
        // the scalars convert, so the bridge is written out here.
        DisplaySlider(
            label: label,
            unit: unit,
            range: Double(range.lowerBound)...Double(range.upperBound),
            stored: Binding(
                get: { Double(displays.config(forKey: screen.id)[keyPath: path]) },
                set: { newValue in
                    var config = displays.config(forKey: screen.id)
                    config[keyPath: path] = CGFloat(newValue)
                    displays.set(config, forKey: screen.id)
                }
            )
        )
    }

    private func refresh() {
        attached = NSScreen.screens.compactMap { screen in
            guard let key = DisplayConfigStore.key(for: screen) else { return nil }
            return Attached(
                id: key,
                name: screen.localizedName,
                pixels: "\(Int(screen.frame.width)) × \(Int(screen.frame.height))",
                hasHardwareNotch: screen.safeAreaInsets.top > 0,
                isMain: screen == NSScreen.main,
                cutout: screen.cutout
            )
        }
        // A display that went away must not leave the pane showing
        // sliders that write nowhere.
        if let selection, !attached.contains(where: { $0.id == selection }) {
            self.selection = attached.first?.id
        }
    }
}

/// One Displays slider row. The drag moves only this view's local
/// preview; the store (a JSON encode, a defaults write, and a full
/// island rebuild through its onChange) hears ONE write, on release.
/// Before this, dragging "Expanded width" rebuilt every island window
/// on every frame.
private struct DisplaySlider: View {
    let label: String
    let unit: String
    let range: ClosedRange<Double>
    @Binding var stored: Double
    @State private var preview: Double?

    var body: some View {
        SettingRow(label: label) {
            HStack(spacing: Theme.Space.m) {
                ThinSlider(
                    value: Binding(
                        get: { preview ?? stored },
                        set: { preview = $0 }
                    ),
                    in: range,
                    label: label,
                    width: 180,
                    describe: { "\(Int($0))\(unit)" },
                    onCommit: { target in
                        stored = target
                        preview = nil
                    }
                )
                // The number, not just the knob: a slider alone cannot
                // be matched between two displays. It follows the drag
                // live even though the store hears only the release.
                Text("\(Int(preview ?? stored))\(unit)")
                    .font(Theme.Fonts.captionMono)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}
