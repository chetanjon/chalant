import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralSection: View {
    @ObservedObject var updates: UpdateChecker
    var onReplayTour: () -> Void

    @AppStorage(UpdateChecker.settingKey) private var updateCheckOn = true
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage(NotchViewModel.rememberLastTabKey) private var rememberLastTab = false
    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage("openDelay") private var openDelay = 0.18
    @AppStorage("collapseDelay") private var collapseDelay = 0.05
    @AppStorage(VoiceController.pinnedUIDKey) private var voiceInputUID = ""

    @State private var launchAtLogin = false
    /// The mics on offer right now, refreshed each time this section
    /// appears; (name, uid) pairs for the Microphone picker.
    @State private var inputDevices: [(name: String, uid: String)] = []

    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "Startup") {
                SettingToggle(label: "Start at login", isOn: Binding(
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
                SettingDivider()
                SettingToggle(label: "Check for new versions", isOn: $updateCheckOn)
                SettingNote("Once a day, quietly. Chalant never installs anything without you asking.")
                SettingDivider()
                SettingToggle(label: "Show in Dock", isOn: Binding(
                    get: { showInDock },
                    set: { wanted in
                        showInDock = wanted
                        // Applied here rather than watched from the app
                        // delegate: this is the only place it changes,
                        // and the switch should land the moment it moves.
                        NSApp.setActivationPolicy(wanted ? .regular : .accessory)
                    }
                ))
                SettingNote("Off, Chalant lives only in the menu bar and the notch.")
            }

            SettingCard(title: "Opening the island") {
                SettingToggle(label: "Remember last tab", isOn: $rememberLastTab)
                SettingNote(
                    "On, the island reopens on whatever you were last looking at. Off, it always "
                    + "reopens on your day."
                )
            }

            SettingCard(title: "Opening") {
                SettingToggle(label: "Open on hover", isOn: $expandOnHover)
                SettingDivider()
                SettingPicker(
                    label: "Open",
                    selection: $openDelay,
                    options: [("Instant", 0.0), ("Quick", 0.12), ("Calm", 0.18), ("Relaxed", 0.3)],
                    width: 236
                )
                SettingDivider()
                SettingPicker(
                    label: "Close",
                    selection: $collapseDelay,
                    options: [("Instant", 0.05), ("Quick", 0.35), ("Relaxed", 0.8)],
                    // Matches the Open row above it: two right-aligned
                    // controls of different widths leave a ragged left
                    // edge between rows that are read as a pair.
                    width: 236
                )
            }

            SettingCard(title: "Voice") {
                SettingRow(label: "Microphone") {
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
                    .accessibilityLabel("Microphone")
                }
                SettingNote("Automatic starts with the Mac's own mic and hops if it hears nothing.")
            }

            SettingCard(title: "Tour") {
                // A real push button, not accent-tinted text: with the
                // silver accent the plain style rendered as an ordinary
                // label and nothing said it could be clicked.
                Button("Show the welcome tour again", action: onReplayTour)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(accent)
                SettingNote("The four cards you saw the first time Chalant opened.")
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            var devices = SystemVolume.inputDevices()
                .filter { !$0.uid.isEmpty }
                .map { (name: $0.name, uid: $0.uid) }
            // A pinned mic that is not attached right now still needs a
            // menu entry, or the picker renders blank and the pin
            // becomes invisible instead of clearable.
            if !voiceInputUID.isEmpty,
               !devices.contains(where: { $0.uid == voiceInputUID }) {
                devices.append((name: "Not connected", uid: voiceInputUID))
            }
            inputDevices = devices
        }
    }
}

// MARK: - Sessions

/// What Chalant has found running. This is the full list, where the
/// island's strip is deliberately only the three that want attention —
/// a window has the room to show the quiet ones too.
struct SessionsSection: View {
    @ObservedObject var sessions: SessionStore
    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "Running now") {
                if sessions.sessions.isEmpty {
                    Text("No sessions found.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                    SettingNote(
                        "Start Claude Code in any terminal and it appears here within a few seconds. "
                        + "There is nothing to install."
                    )
                } else {
                    ForEach(Array(sessions.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { SettingDivider() }
                        row(session)
                    }
                }
            }

            SettingCard(title: "How this works") {
                SettingNote(
                    "Chalant reads what these tools already write — Claude Code under "
                    + "~/.claude/projects, Cursor under ~/.cursor/chats. There is nothing to "
                    + "install, nothing is sent anywhere, and sessions already running when "
                    + "Chalant launched show up too."
                )
                SettingDivider()
                SettingNote(
                    "A session that has gone quiet for five minutes reads as last seen rather than "
                    + "running: a file that stopped changing is not proof a session ended."
                )
                SettingDivider()
                SettingNote(
                    "Codex is missing because it keeps no session records on disk. It would need to "
                    + "tell Chalant directly, the way the chalant command already does."
                )
            }

            hookCard
        }
    }

    /// Live install state for `scripts/chalant-hook`'s Stop event, read
    /// fresh from `~/.claude/settings.json` every time this appears.
    /// Discovery alone can only say a session's file went quiet; the
    /// Stop hook is what says a session is actually waiting for you,
    /// and what lets a queued message reach one at all
    /// (notch-messaging-plan-2026-08-01.md, W-E).
    private var hookCard: some View {
        let status = HookInstall.status()
        return SettingCard(title: "The Stop hook") {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: status.symbol)
                    .font(Theme.Fonts.icon(.s))
                    .foregroundStyle(status == .installed ? Theme.textSecondary : accent)
                Text(status.label)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            switch status {
            case .installed:
                SettingNote(
                    "Claude Code hands this app a Stop event on every session: a pill the moment "
                    + "one wants you, and the way a queued message reaches it."
                )
            case .missing:
                SettingNote(
                    "Chalant never writes ~/.claude/settings.json for you. Paste this under "
                    + "\"hooks\", merging with anything already there:"
                )
                hookSnippet
            case .unreadable:
                SettingNote(
                    "~/.claude/settings.json did not parse. Check it for a stray comma before "
                    + "assuming the hook itself is missing — that is a different problem with the "
                    + "same symptom."
                )
                hookSnippet
            }
        }
    }

    private var hookSnippetText: String {
        let path = HookInstall.bundledScriptPath ?? "/path/to/scripts/chalant-hook"
        return """
        {
          "hooks": {
            "Notification": [
              { "hooks": [ { "type": "command", "command": "\(path)" } ] }
            ],
            "Stop": [
              { "hooks": [ { "type": "command", "command": "\(path)" } ] }
            ]
          }
        }
        """
    }

    private var hookSnippet: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(hookSnippetText)
                .font(Theme.Fonts.captionMono)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.surface))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hookSnippetText, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(accent)
        }
    }

    private func row(_ session: SessionStore.Session) -> some View {
        HStack(spacing: Theme.Space.m) {
            // Glyph as well as tint, so state survives greyscale.
            AgentMark(agent: session.agent, size: 12, state: session.state)
                .foregroundStyle(Theme.textTertiary)
            Image(systemName: Self.symbol(session.state))
                .font(Theme.Fonts.icon(.s))
                .foregroundStyle(session.state == .needsInput ? accent : Theme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.cwd)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.m)
            if let branch = session.branch, !branch.isEmpty {
                Text(branch)
                    .font(Theme.Fonts.microMono)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            // The state is the column a reader scans; it is not a mark.
            Text(Self.label(session.state))
                .font(Theme.Fonts.micro)
                .foregroundStyle(session.state == .needsInput ? accent : Theme.textTertiary)
            Text(RelativeAge.short(session.updatedAt))
                .font(Theme.Fonts.microMono)
                .foregroundStyle(Theme.textGhost)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.cwd), \(Self.label(session.state))")
    }

    private static func symbol(_ state: SessionStore.State) -> String {
        switch state {
        case .needsInput: return "exclamationmark.circle.fill"
        case .working: return "circle.dashed"
        case .idle: return "pause.circle"
        case .stale: return "clock"
        case .done: return "checkmark.circle"
        case .failed: return "xmark.circle"
        }
    }

    private static func label(_ state: SessionStore.State) -> String {
        switch state {
        case .needsInput: return "Waiting for you"
        case .working: return "Working"
        case .idle: return "Waiting for input"
        case .stale: return "Last seen"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

// MARK: - What shows

struct WhatShowsSection: View {
    let events: EventKitService

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
    @AppStorage(EventKitService.reminderListKey) private var reminderListID = ""

    /// Writable reminder lists, refreshed each time this section appears.
    @State private var reminderLists: [(title: String, id: String)] = []

    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "Blocks") {
                SettingToggle(label: "Media", isOn: $showMedia)
                SettingDivider()
                SettingToggle(label: "Ambience", isOn: $showAmbience)
                SettingDivider()
                SettingToggle(label: "Calendar today", isOn: $showCalendar)
                SettingDivider()
                SettingToggle(label: "Reminders", isOn: $showReminders)
                if !reminderLists.isEmpty {
                    SettingRow(label: "Save reminders to") {
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
                        .accessibilityLabel("Save reminders to")
                    }
                }
            }

            SettingCard(title: "Tools") {
                SettingToggle(label: "Shortcuts", isOn: $toolGo)
                SettingDivider()
                SettingToggle(label: "Clipboard", isOn: $toolClips)
                SettingDivider()
                SettingToggle(label: "Shelf", isOn: $toolShelf)
                SettingDivider()
                SettingToggle(label: "Notes", isOn: $toolNotes)
                SettingDivider()
                SettingToggle(label: "Focus & timers", isOn: $toolFocus)
                SettingDivider()
                SettingToggle(label: "Chat", isOn: $toolChat)
                if toolChat {
                    SettingPicker(
                        label: "Service",
                        selection: $chatService,
                        options: [("Claude", "claude"), ("ChatGPT", "chatgpt"), ("Gemini", "gemini")]
                    )
                    SettingNote(
                        "Your own account, in a small built-in browser. Chalant is not affiliated "
                        + "with Anthropic, OpenAI, or Google."
                    )
                }
            }
        }
        .onAppear {
            var lists = events.availableReminderLists()
            if !reminderListID.isEmpty,
               !lists.contains(where: { $0.id == reminderListID }) {
                lists.append((title: "Missing list", id: reminderListID))
            }
            reminderLists = lists
        }
    }
}

// MARK: - Island

struct IslandSection: View {
    @ObservedObject var music: MusicController

    @AppStorage("islandMaterial") private var islandMaterial = "ink"
    @AppStorage("glassClarity") private var glassClarity = "balanced"
    @AppStorage("glowOn") private var glowOn = true
    @AppStorage("idleEdgeOn") private var idleEdgeOn = true
    @AppStorage("autoHideIsland") private var autoHideIsland = false
    @AppStorage("motionFeel") private var motionFeel = "serene"
    @AppStorage("glideLongTitles") private var glideLongTitles = false
    @AppStorage("accentMode") private var accentMode = "silver"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "Look") {
                SettingPicker(
                    label: "Material",
                    selection: $islandMaterial,
                    options: [("Ink", "ink"), ("Glass", "glass")]
                )
                SettingNote(
                    "Glass opens the island as liquid glass. Closed, it stays ink and melts "
                    + "into the notch."
                )
                if islandMaterial == "glass" {
                    SettingPicker(
                        label: "Clarity",
                        selection: $glassClarity,
                        options: [("Veiled", "veiled"), ("Balanced", "balanced"), ("Clear", "clear")]
                    )
                }
                SettingDivider()
                SettingToggle(label: "Accent rim on the pill", isOn: $glowOn)
                SettingNote("The coloured border that breathes while music or a session runs.")
                SettingDivider()
                SettingToggle(label: "Show edge when idle", isOn: $idleEdgeOn)
                SettingNote(
                    "On a notchless display this is the resting sliver on the menu bar line. "
                    + "Off hides the island entirely until you hover the top edge."
                )
                SettingDivider()
                SettingToggle(label: "Hide until I reach for it", isOn: $autoHideIsland)
                SettingNote(
                    "The island stays out of sight and comes back when the pointer reaches "
                    + "the top of the screen where it lives. Anything it needs to tell you "
                    + "still appears."
                )
            }

            SettingCard(title: "Motion") {
                SettingPicker(
                    label: "Feel",
                    selection: $motionFeel,
                    options: [
                        ("Still", "still"), ("Serene", "serene"),
                        ("Balanced", "balanced"), ("Lively", "lively"),
                    ],
                    width: 236
                )
                SettingNote("Motion follows the system Reduce Motion setting, whatever is chosen here.")
                SettingDivider()
                SettingToggle(label: "Glide long titles", isOn: $glideLongTitles)
                SettingNote(
                    "Off, a long name is trimmed at the end and holds still. On, it slides to show "
                    + "the rest, which is cramped in a narrow notch."
                )
            }

            SettingCard(title: "Accent") {
                HStack(spacing: Theme.Space.l) {
                    swatch("album", music.accent, label: "Album")
                    swatch("silver", Theme.accentFallback, label: "Silver")
                    swatch("blue", Theme.accentBlue, label: "Blue")
                    swatch("mint", Theme.accentMint, label: "Mint")
                    swatch("rose", Theme.accentRose, label: "Rose")
                    Spacer()
                }
                SettingNote("Album follows the artwork of whatever is playing.")
            }
        }
    }

    private func swatch(_ mode: String, _ color: Color, label: String) -> some View {
        SettingsSwatch(color: color, label: label, selected: accentMode == mode) {
            accentMode = mode
        }
    }
}

// MARK: - Glance

struct GlanceSection: View {
    @AppStorage(MusicController.playingSignalKey) private var playingSignal
        = MusicController.playingSignalDefault
    @AppStorage("glanceMusic") private var glanceMusic = true
    @AppStorage("glanceSession") private var glanceSession = true
    @AppStorage("glanceBattery") private var glanceBattery = false
    @AppStorage("collapsedSong") private var collapsedSong = true
    @AppStorage("glanceAgents") private var glanceAgents = true
    @AppStorage("glanceNextEvent") private var glanceNextEvent = true
    @AppStorage("showCalendar") private var showCalendar = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "Beside the notch") {
                SettingPicker(
                    label: "While playing",
                    selection: $playingSignal,
                    options: [("Wave", "wave"), ("Quiet", "quiet")]
                )
                SettingNote(
                    "Quiet leaves only the breathing rim, the default. Wave dances beside the notch "
                    + "for those who want it."
                )
                SettingDivider()
                SettingToggle(label: "Session mark beside the notch", isOn: $glanceSession)
                SettingNote(
                    "The small ring or stopwatch glyph while something runs. Off keeps the pill bare; "
                    + "the rim alone says something is going."
                )
                SettingDivider()
                SettingToggle(label: "What's playing, on the island", isOn: $collapsedSong)
                SettingNote(
                    "The song's name beside the resting island, on displays without a notch. A "
                    + "MacBook keeps the bare pill so it still matches the hardware."
                )
                SettingDivider()
                SettingToggle(label: "Agents running", isOn: $glanceAgents)
                SettingNote(
                    "A mark beside the notch while Claude Code or Cursor sessions are going. It "
                    + "breathes while they work and holds still, in the accent, the moment one is "
                    + "waiting on you."
                )
                SettingDivider()
                SettingToggle(label: "Battery", isOn: $glanceBattery)
                SettingNote(
                    "The charge, last in line: it only takes the space when nothing else beside the "
                    + "notch has anything to say. It turns red below 20%."
                )
            }

            SettingCard(title: "What interrupts") {
                SettingToggle(label: "Clear the glance while playing", isOn: $glanceMusic)
                SettingDivider()
                SettingToggle(label: "Event coming up", isOn: $glanceNextEvent)
                if !showCalendar {
                    SettingNote("Needs the Calendar today block on, under What shows.")
                }
            }
        }
    }
}

// MARK: - About

struct AboutSection: View {
    @ObservedObject var updates: UpdateChecker
    var onInstallUpdate: () -> Void

    @Environment(\.chalantAccent) private var accent

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "Version") {
                SettingRow(label: "Chalant") {
                    Text(version)
                        .font(Theme.Fonts.captionMono)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let latest = updates.latest {
                    SettingDivider()
                    Button(action: onInstallUpdate) {
                        Text("Chalant \(latest) is out. Install it.")
                            .font(Theme.Fonts.body)
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            SettingCard(title: "Privacy") {
                SettingNote(
                    "Everything Chalant reads stays on this Mac: what is playing, your day, your "
                    + "sessions. Nothing is sent anywhere."
                )
                SettingDivider()
                SettingNote(
                    "Speech is transcribed by macOS itself, and the recording is deleted the moment "
                    + "the phrase is understood."
                )
                SettingDivider()
                SettingNote(
                    "Chat opens your own accounts in a small built-in browser. Chalant is not "
                    + "affiliated with the services it opens."
                )
            }
        }
    }
}
