import ServiceManagement
import SwiftUI

/// Settings in the island's own voice: each section is a quiet card,
/// rows separated by hairlines instead of floating in a bare scroll.
struct SettingsPane: View {
    @ObservedObject var music: MusicController
    @ObservedObject var updates: UpdateChecker
    /// For the reminders destination picker.
    let events: EventKitService
    /// Jump target for debug-driven screenshots: a section title,
    /// lowercased. Cleared once honored.
    @Binding var scrollTarget: String?
    /// Reopens the first-run tour.
    var onReplayTour: (() -> Void)?

    @AppStorage(UpdateChecker.settingKey) private var updateCheckOn = true

    @State private var launchAtLogin = false
    /// The mics on offer right now, refreshed each time the pane
    /// opens; (name, uid) pairs for the Microphone picker.
    @State private var inputDevices: [(name: String, uid: String)] = []
    /// Writable reminder lists, refreshed each time the pane opens.
    @State private var reminderLists: [(title: String, id: String)] = []
    @AppStorage(EventKitService.reminderListKey) private var reminderListID = ""

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
    @AppStorage("toolChat") private var toolChat = true
    @AppStorage(ChatController.serviceKey) private var chatService = "claude"

    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage(VoiceController.pinnedUIDKey) private var voiceInputUID = ""
    @AppStorage("openDelay") private var openDelay = 0.18
    @AppStorage("collapseDelay") private var collapseDelay = 0.05
    @AppStorage("motionFeel") private var motionFeel = "serene"
    @AppStorage("islandMaterial") private var islandMaterial = "ink"
    @AppStorage("glassClarity") private var glassClarity = "balanced"
    @AppStorage("glowOn") private var glowOn = true
    @AppStorage("idleEdgeOn") private var idleEdgeOn = true
    @AppStorage("accentMode") private var accentMode = "silver"
    @AppStorage("glanceMusic") private var glanceMusic = true
    @AppStorage("playingSignal") private var playingSignal = "wave"
    @AppStorage("glanceSession") private var glanceSession = true
    @AppStorage("glanceNextEvent") private var glanceNextEvent = true
    @AppStorage("glanceIdle") private var glanceIdle = "none"

    @Environment(\.moaiAccent) private var accent

    var body: some View {
        ScrollViewReader { proxy in
            scrollBody
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .top)
                    scrollTarget = nil
                }
                .onAppear {
                    guard let target = scrollTarget else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(target, anchor: .top)
                        scrollTarget = nil
                    }
                }
        }
    }

    private var scrollBody: some View {
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
                    if !reminderLists.isEmpty {
                        row("Save reminders to") {
                            Picker("", selection: $reminderListID) {
                                Text("Automatic").tag("")
                                ForEach(reminderLists, id: \.id) { list in
                                    Text(list.title).tag(list.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(accent)
                            .fixedSize()
                        }
                    }
                    divider
                    toggleRow("Shortcuts", $toolGo)
                    divider
                    toggleRow("Clipboard", $toolClips)
                    divider
                    toggleRow("Shelf", $toolShelf)
                    divider
                    toggleRow("Notes", $toolNotes)
                    divider
                    toggleRow("Focus & timers", $toolFocus)
                    divider
                    toggleRow("Chat", $toolChat)
                    if toolChat {
                        row("Service") {
                            picker($chatService, [
                                ("Claude", "claude"), ("ChatGPT", "chatgpt"),
                                ("Gemini", "gemini"),
                            ])
                        }
                        Text("Your own account, in a small built-in browser. Moai is not affiliated with Anthropic, OpenAI, or Google.")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textHint)
                    }
                }
                section("Island", reveal: 1) {
                    row("Microphone") {
                        Picker("", selection: $voiceInputUID) {
                            Text("Automatic").tag("")
                            ForEach(inputDevices, id: \.uid) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(accent)
                        .fixedSize()
                    }
                    Text("Automatic starts with the Mac's own mic and hops if it hears nothing.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
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
                            ("Instant", 0.0), ("Quick", 0.12),
                            ("Calm", 0.18), ("Relaxed", 0.3),
                        ], width: 236)
                    }
                    divider
                    row("Close") {
                        picker($collapseDelay, [
                            ("Instant", 0.05), ("Quick", 0.35), ("Relaxed", 0.8),
                        ])
                    }
                }
                section("Glance", reveal: 2) {
                    row("While playing") {
                        picker($playingSignal, [
                            ("Wave", "wave"), ("Quiet", "quiet"),
                        ])
                    }
                    Text("Wave dances beside the notch; Quiet leaves only the breathing rim.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                    divider
                    toggleRow("Countdown beside the notch", $glanceSession)
                    Text("Off, a running focus or timer keeps the pill bare; the rim alone says something is going.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                    divider
                    toggleRow("Clear the glance while playing", $glanceMusic)
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
                    row("Material") {
                        picker($islandMaterial, [
                            ("Ink", "ink"), ("Glass", "glass"),
                        ])
                    }
                    Text("Glass opens the island as liquid glass. Closed, it stays ink and melts into the notch.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                    if islandMaterial == "glass" {
                        row("Clarity") {
                            picker($glassClarity, [
                                ("Veiled", "veiled"), ("Balanced", "balanced"),
                                ("Clear", "clear"),
                            ])
                        }
                    }
                    divider
                    toggleRow("Accent rim on the pill", $glowOn)
                    Text("The colored border that breathes while music or a session runs. Off is off.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
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
                footer
            }
            .padding(.bottom, Theme.Space.m)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            var devices = SystemVolume.inputDevices()
                .filter { !$0.uid.isEmpty }
                .map { (name: $0.name, uid: $0.uid) }
            // A pinned mic that is not attached right now still needs
            // a menu entry, or the picker renders blank and the pin
            // becomes invisible instead of clearable.
            if !voiceInputUID.isEmpty,
               !devices.contains(where: { $0.uid == voiceInputUID }) {
                devices.append((name: "Not connected", uid: voiceInputUID))
            }
            inputDevices = devices
            var lists = events.availableReminderLists()
            if !reminderListID.isEmpty,
               !lists.contains(where: { $0.id == reminderListID }) {
                lists.append((title: "Missing list", id: reminderListID))
            }
            reminderLists = lists
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
        // Scroll anchor for debug-driven screenshots: "island", "life".
        .id(title.lowercased())
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
