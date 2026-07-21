import ServiceManagement
import SwiftUI

/// Settings in the island's own voice: each section is a quiet card,
/// rows separated by hairlines instead of floating in a bare scroll.
struct SettingsPane: View {
    @ObservedObject var music: MusicController
    @ObservedObject var updates: UpdateChecker
    /// Reopens the first-run tour.
    var onReplayTour: (() -> Void)?

    @AppStorage(UpdateChecker.settingKey) private var updateCheckOn = true

    @State private var launchAtLogin = false
    @State private var apiKeys: [AIProvider: String] = [:]

    // Which blocks the island shows. Media/ambience/tools ship on; your
    // day is opt-in.
    @AppStorage("showMedia") private var showMedia = true
    @AppStorage("showAmbience") private var showAmbience = true
    @AppStorage("showCalendar") private var showCalendar = false
    @AppStorage("showReminders") private var showReminders = false
    @AppStorage("toolGo") private var toolGo = true
    @AppStorage("toolClips") private var toolClips = true
    @AppStorage("toolShelf") private var toolShelf = true
    @AppStorage("toolNotes") private var toolNotes = true
    @AppStorage("toolFocus") private var toolFocus = true

    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage(HotkeySummon.settingKey) private var summonKey = "optSpace"
    @AppStorage("openDelay") private var openDelay = 0.12
    @AppStorage("collapseDelay") private var collapseDelay = 0.05
    @AppStorage("motionFeel") private var motionFeel = "serene"
    @AppStorage("glowOn") private var glowOn = true
    @AppStorage("idleEdgeOn") private var idleEdgeOn = true
    @AppStorage("accentMode") private var accentMode = "silver"
    @AppStorage("glanceMusic") private var glanceMusic = true
    @AppStorage("glanceSession") private var glanceSession = true
    @AppStorage("glanceNextEvent") private var glanceNextEvent = true
    @AppStorage("glanceIdle") private var glanceIdle = "none"

    @Environment(\.moaiAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                section("What shows", reveal: 0) {
                    toggleRow("Media", $showMedia)
                    divider
                    toggleRow("Ambience", $showAmbience)
                    divider
                    toggleRow("Calendar today", $showCalendar)
                    divider
                    toggleRow("Reminders", $showReminders)
                    divider
                    toggleRow("Shortcuts", $toolGo)
                    divider
                    toggleRow("Clipboard", $toolClips)
                    divider
                    toggleRow("Files", $toolShelf)
                    divider
                    toggleRow("Notes", $toolNotes)
                    divider
                    toggleRow("Focus & timers", $toolFocus)
                }
                section("Island", reveal: 1) {
                    row("Summon voice") {
                        picker($summonKey, [
                            ("⌥Space", "optSpace"), ("⌃Space", "ctrlSpace"),
                            ("⇧⌘Space", "cmdShiftSpace"), ("Off", "off"),
                        ], width: 236)
                    }
                    divider
                    toggleRow("Open on hover", $expandOnHover)
                    divider
                    toggleRow("Show edge when idle", $idleEdgeOn)
                    divider
                    toggleRow("Check for new versions", $updateCheckOn)
                    divider
                    toggleRow("Start at login", Binding(
                        get: { launchAtLogin },
                        set: { enabled in
                            launchAtLogin = enabled
                            if enabled {
                                try? SMAppService.mainApp.register()
                            } else {
                                try? SMAppService.mainApp.unregister()
                            }
                        }
                    ))
                    divider
                    row("Open") {
                        picker($openDelay, [
                            ("Instant", 0.0), ("Quick", 0.12), ("Relaxed", 0.3),
                        ])
                    }
                    divider
                    row("Close") {
                        picker($collapseDelay, [
                            ("Instant", 0.05), ("Quick", 0.35), ("Relaxed", 0.8),
                        ])
                    }
                }
                section("Glance", reveal: 2) {
                    toggleRow("Song name while playing", $glanceMusic)
                    divider
                    toggleRow("Session phase", $glanceSession)
                    divider
                    toggleRow("Event coming up", $glanceNextEvent)
                    if !showCalendar {
                        Text("Needs the Calendar today block on.")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textHint)
                    }
                    divider
                    row("When idle") {
                        picker($glanceIdle, [
                            ("Clock", "clock"), ("Day", "day"),
                            ("Streak", "streak"), ("Nothing", "none"),
                        ])
                    }
                }
                section("Life", reveal: 3) {
                    row("Feel") {
                        picker($motionFeel, [
                            ("Still", "still"), ("Serene", "serene"),
                            ("Balanced", "balanced"), ("Lively", "lively"),
                        ], width: 236)
                    }
                    divider
                    toggleRow("Glow with music", $glowOn)
                }
                section("Accent", reveal: 4) {
                    HStack(spacing: Theme.Space.l) {
                        swatch("album", music.accent, label: "Album")
                        swatch("silver", Theme.accentFallback, label: "Silver")
                        swatch("blue", Theme.accentBlue, label: "Blue")
                        swatch("mint", Theme.accentMint, label: "Mint")
                        swatch("rose", Theme.accentRose, label: "Rose")
                        Spacer()
                    }
                }
                section("Cloud AI (optional)", reveal: 5) {
                    let keyed = AIProvider.allCases.filter(\.needsKey)
                    ForEach(keyed, id: \.self) { provider in
                        keyField(for: provider)
                        if provider != keyed.last {
                            divider
                        }
                    }
                    Text("Only for questions the local verbs can't answer. The Mac's own model handles those with no key. Keys stay on this Mac.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                }
                footer
            }
            .padding(.bottom, Theme.Space.m)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            for provider in AIProvider.allCases where provider.needsKey {
                apiKeys[provider] = KeychainStore.read(provider.keychainAccount) ?? ""
            }
        }
        .onDisappear { saveKeys() }
    }

    private func keyField(for provider: AIProvider) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(provider.displayName)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            SecureField(
                provider.keyPlaceholder,
                text: Binding(
                    get: { apiKeys[provider] ?? "" },
                    set: { apiKeys[provider] = $0 }
                )
            )
            .onSubmit { saveKeys() }
            .textFieldStyle(.plain)
            .font(Theme.Fonts.bodyMono)
            .padding(Theme.Space.m)
            .moaiField()
        }
    }

    private func saveKeys() {
        for provider in AIProvider.allCases where provider.needsKey {
            KeychainStore.write(apiKeys[provider] ?? "", account: provider.keychainAccount)
        }
    }

    // MARK: Building blocks

    private func section(
        _ title: String,
        reveal: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: title)
                .padding(.leading, Theme.Space.xs)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                content()
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .moaiCard()
        }
        .staggeredReveal(reveal)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairlineFaint)
            .frame(height: 1)
    }

    private func row(
        _ label: String,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack {
            Text(label)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            control()
        }
    }

    private func toggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        row(label) {
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(accent)
        }
    }

    private func picker<Value: Hashable>(
        _ selection: Binding<Value>,
        _ options: [(String, Value)],
        width: CGFloat = 190
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.1) { option in
                Text(option.0).tag(option.1)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: width)
    }

    private func swatch(_ mode: String, _ color: Color, label: String) -> some View {
        SettingsSwatch(
            color: color,
            label: label,
            selected: accentMode == mode
        ) {
            accentMode = mode
        }
    }

    private var footer: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return VStack(alignment: .leading, spacing: 2) {
            Text("Moai\(version.map { " \($0)" } ?? "")")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
            if let latest = updates.latest {
                Button {
                    NSWorkspace.shared.open(UpdateChecker.downloadPage)
                } label: {
                    Text("Moai \(latest) is out. Get it.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
            Text("Motion follows the system Reduce Motion setting.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textGhost)
            if let onReplayTour {
                Button("Show the welcome tour again", action: onReplayTour)
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .padding(.leading, Theme.Space.xs)
        .padding(.top, Theme.Space.xs)
    }
}

/// One accent choice: a swatch that lifts on hover and rings when
/// selected.
private struct SettingsSwatch: View {
    let color: Color
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.snug) {
                Circle()
                    .fill(color)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                selected ? Theme.textPrimary : Color.white.opacity(0.12),
                                lineWidth: selected ? 2 : 1
                            )
                    )
                    .scaleEffect(hovered && !selected ? 1.08 : 1)
                Text(label)
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(
                        selected ? Theme.textSecondary
                            : hovered ? Theme.textSecondary : Theme.textTertiary
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}
