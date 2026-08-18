import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralSection: View {
    @ObservedObject var updates: UpdateChecker
    var onReplayTour: () -> Void
    var onInstallUpdate: () -> Void

    @AppStorage(UpdateChecker.settingKey) private var updateCheckOn = true
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage(NotchViewModel.openOnFinishKey) private var openOnFinish = true
    @AppStorage(NotchViewModel.rememberLastTabKey) private var rememberLastTab = false
    @AppStorage("expandOnHover") private var expandOnHover = true
    @AppStorage("openDelay") private var openDelay = 0.18
    @AppStorage("collapseDelay") private var collapseDelay = 0.05
    @AppStorage(VoiceController.pinnedUIDKey) private var voiceInputUID = ""
    @AppStorage(Dictation.enabledKey) private var dictationOn = false
    @AppStorage(CorpusCapture.enabledKey) private var captureCorpus = false
    // On, now that `LearnedTermsList` exists to show what it learned and undo
    // it. Until this screen was built the default was off, because §0.15's
    // "inspectable and reversible" is a precondition for learning silently,
    // not a nicety to add afterwards.
    @AppStorage(CorrectionObserver.enabledKey) private var learnCorrections = true
    // On, per the 2026-08-14 decision. Costs ~1s per utterance; see `Cleanup`.
    @AppStorage(Cleanup.enabledKey) private var cleanup = false

    @State private var launchAtLogin = false
    /// The mics on offer right now, refreshed each time this section
    /// appears; (name, uid) pairs for the Microphone picker.
    @State private var inputDevices: [(name: String, uid: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.settingsGroup) {
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
                if let latest = updates.latest {
                    SettingDivider()
                    // A real push button beside the state it acts on,
                    // not tinted text: same lesson as the tour button
                    // below (nothing said plain text could be clicked).
                    Button("Install Chalant \(latest)", action: onInstallUpdate)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .tint(Theme.controlTint)
                }
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
                SettingDivider()
                // The finish announcement is a sessions behaviour, so
                // its switch dark-ships with the surface (FeatureFlags).
                if FeatureFlags.sessionsVisible {
                    SettingToggle(label: "Open when an agent finishes", isOn: $openOnFinish)
                    SettingNote(
                        "The island opens on the session that just finished, showing what it said "
                        + "with the reply box under it. It stays out of the way while you are "
                        + "dictating or already typing in it."
                    )
                    SettingDivider()
                }
                SettingToggle(label: "Remember last tab", isOn: $rememberLastTab)
                SettingNote(
                    "On, the island reopens on whatever you were last looking at. Off, it always "
                    + "reopens on your day."
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
                    .tint(Theme.controlTint)
                    .fixedSize()
                    .accessibilityLabel("Microphone")
                }
                SettingNote("Automatic starts with the Mac's own mic and hops if it hears nothing.")
            }

            // A different job from the card above: that one turns speech into
            // island commands, this turns speech into text wherever you were
            // already typing. Its own card so the two are never confused.
            SettingCard(title: "Dictation") {
                if Dictation.isSupported {
                    SettingToggle(label: "Hold to dictate", isOn: Binding(
                        get: { dictationOn },
                        set: { on in
                            dictationOn = on
                            // Act now rather than at next launch. Turning it on
                            // is also what raises the Input Monitoring and
                            // Accessibility asks, which is why it is off until
                            // somebody chooses it.
                            if on { Dictation.shared.start() } else { Dictation.shared.stop() }
                        }))
                    // Read off VoiceDoor, never written here, for the same
                    // reason the tour's line is: the app must not describe a
                    // gesture in one place and ship another.
                    SettingNote(VoiceDoor.dictationLine(available: true) ?? "")
                    SettingNote(
                        "The first time you turn this on, macOS asks for Input Monitoring and "
                        + "Accessibility. It needs both: one to notice the key, one to place the text."
                    )
                    SettingDivider()
                    // A switch because this is not simply better: it trades
                    // roughly a second for a tidier sentence, and that is a
                    // trade someone is entitled to decline.
                    SettingToggle(label: "Tidy what I said", isOn: $cleanup)
                    SettingNote(
                        "Removes the ums and false starts and fixes punctuation, on this Mac. "
                        + "It adds about a second before your words appear. Names, numbers and "
                        + "every \"not\" are checked afterwards, and anything it changed that it "
                        + "should not have is thrown away."
                    )

                    SettingDivider()
                    // Law 6 says defaults over switches, and this is the same
                    // exception the recordings toggle below claims: it watches
                    // what you type after Chalant writes for you, so it says so
                    // out loud rather than doing it quietly.
                    SettingToggle(label: "Learn my names", isOn: $learnCorrections)
                    SettingNote(
                        "When you fix a word Chalant got wrong, it notices. Fix the same one "
                        + "twice and it stops getting it wrong. Only the pair of words is kept, "
                        + "never the sentence, and everything it learns is listed below."
                    )
                    // Part 0 §0.15: a learned pair the user cannot see or
                    // delete would rewrite one of their words on every future
                    // utterance with no way out. This list is what makes the
                    // switch above safe to leave on.
                    LearnedTermsList()

                    SettingDivider()
                    // Everywhere else this app goes out of its way NOT to keep
                    // what you said. This does the opposite, so it gets a
                    // switch you can see rather than a hidden default.
                    SettingToggle(label: "Keep recordings to improve accuracy", isOn: $captureCorpus)
                    SettingNote(
                        "Off. Turn it on and Chalant saves the audio and text of everything you "
                        + "dictate to a folder on your Desktop, so the accuracy can be measured "
                        + "against your real voice. Nothing is uploaded. Turn it off and it stops; "
                        + "delete the folder and it is gone."
                    )
                } else {
                    SettingNote("Dictation needs macOS 26. The rest of Chalant does not.")
                }
            }

            SettingCard(title: "Tour") {
                // A real push button, not accent-tinted text: with the
                // silver accent the plain style rendered as an ordinary
                // label and nothing said it could be clicked.
                Button("Show the welcome tour again", action: onReplayTour)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(Theme.controlTint)
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
    /// Not `@ObservedObject`: this view only calls into it (the test
    /// button below) and never renders its published state.
    let activities: ActivityStore
    /// Rendered here, so it is observed: the grant list and the audit
    /// both change while this page is open.
    @ObservedObject var policy: PolicyStore
    @Environment(\.chalantAccent) private var accent

    @AppStorage(SessionStore.approvalRulesKey) private var approvalRulesRaw = ""
    @State private var draftRule = ""

    // The room's dials. Defaults repeated from where the readers live,
    // never invented here: `SessionRoomSettings` and
    // `SessionStore.historyWindow` are the ones that decide.
    @AppStorage(SessionStore.historyWindowKey) private var historyWindow = "default"
    @AppStorage(SessionRoomSettings.toolActivityKey) private var showsToolActivity = true
    @AppStorage(SessionRoomSettings.densityKey) private var rowDensity = SessionRoomSettings.defaultDensity
    @AppStorage(SessionRemote.straightToTerminalKey) private var straightToTerminal = false
    @AppStorage(SessionRemote.startsInKey) private var startsIn = "terminal"
    /// What the last Arm/Disarm actually did, held so the card can say
    /// so instead of the button going quiet and the user wondering.
    @State private var armOutcome: HookInstall.ArmOutcome?
    /// The same, for the phone switch. Its own state so one card's
    /// result never appears under the other.
    @State private var phoneOutcome: HookInstall.ArmOutcome?
    /// And again for the prompt switch, for the same reason: one card's
    /// result must never appear under another's.
    @State private var promptOutcome: HookInstall.ArmOutcome?
    /// And for the other two agents, kept apart for the same reason.
    @State private var otherAgentOutcome: HookInstall.ArmOutcome?

    /// Read from the stored string rather than through
    /// `SessionStore.approvalRules()`, so editing a rule redraws this
    /// list. The parsing is the same; only the reactivity differs.
    private var rules: [String] {
        approvalRulesRaw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func add(_ rule: String) {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !rules.contains(trimmed) else { return }
        approvalRulesRaw = (rules + [trimmed]).joined(separator: "\n")
    }

    private func remove(_ rule: String) {
        approvalRulesRaw = rules.filter { $0 != rule }.joined(separator: "\n")
    }

    /// Your agents, on your phone.
    ///
    /// The founder asked what the best way is to control agents from the
    /// Claude iPhone app. It is this: Claude Code 2.1.223 ships Remote
    /// Control, and one setting at user scope puts every session on this
    /// machine in the Claude app, permission prompts included. Their own
    /// settings already had the push half switched on
    /// (`agentPushNotifEnabled`, `inputNeededNotifEnabled`) with nothing
    /// to reach.
    ///
    /// So this card is a switch, not a phone app, a push relay or a chat
    /// bridge. Each of those would be Chalant rebuilding, worse,
    /// something already inside the tool it watches.
    private var phoneCard: some View {
        let on = HookInstall.reachesYourPhone()
        return SettingCard(title: "Pick a session up on your phone") {
            SettingNote(
                "Claude Code can put a session on your phone: the Claude app sees what it is "
                + "doing, answers its questions, and approves what it asks for. This switch is "
                + "Claude Code's own setting, not something Chalant invented, and it applies to "
                + "every session you start from now on, wherever you start it."
            )
            HStack(spacing: Theme.Space.m) {
                Image(systemName: on ? "checkmark.circle.fill" : "iphone")
                    .font(Theme.Fonts.icon(.m))
                    .foregroundStyle(on ? Theme.positive : Theme.textTertiary)
                Text(on
                     ? "On. New sessions can be picked up in the Claude app."
                     : "Off. Sessions on this Mac stay on this Mac.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.m)
                if on {
                    Button("Turn it off") { phoneOutcome = HookInstall.disarmRemoteControl() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Turn it on") { phoneOutcome = HookInstall.armRemoteControl() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(accent)
                }
            }
            if let phoneOutcome {
                switch phoneOutcome {
                case .armed(let backup):
                    SettingNote(
                        (on ? "Written. " : "Turned back off. ")
                        + (backup.map { "Your old settings file is at \($0)." }
                           ?? "There was no settings file to back up.")
                        + " Sessions already running keep the settings they started with.")
                case .alreadyArmed:
                    SettingNote("It was already set that way. Nothing was written.")
                case .refused(let why):
                    Text(why)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SettingNote(
                    "This writes remoteControlAtStartup into ~/.claude/settings.json, keeping "
                    + "everything else in the file and copying the old one aside first. A "
                    + "session already on your phone shows an Open on your phone button in the "
                    + "room."
                )
            }
        }
    }

    /// Rules, and the honest state of whether they are armed.
    ///
    /// The two halves are shown together because either alone is a
    /// half-truth. Rules with no `PreToolUse` hook sit there looking
    /// like a policy and hold nothing; the hook with no rules is a
    /// round trip that always answers "not interested". Only both is
    /// the feature.
    private var approvalCard: some View {
        let armed = HookInstall.holdsToolCalls()
        return SettingCard(title: "Hold for approval") {
            SettingNote(
                "When an agent is about to do one of these, Chalant stops it and asks you on the "
                + "island. Everything else runs as usual. If Chalant is not running, or you do "
                + "not answer, the agent falls back to asking in its own terminal."
            )
            if rules.isEmpty {
                Text("Nothing is held.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(rules, id: \.self) { rule in
                    HStack(spacing: Theme.Space.m) {
                        Text(rule)
                            .font(Theme.Fonts.captionMono)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        HoverGlyphButton(
                            symbol: "xmark", label: "Stop holding \(rule)",
                            scale: .s, tint: Theme.textTertiary
                        ) { remove(rule) }
                    }
                }
            }
            SettingDivider()
            HStack(spacing: Theme.Space.s) {
                TextField("Bash(rm *)", text: $draftRule)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.captionMono)
                    .onSubmit { add(draftRule); draftRule = "" }
                    .padding(Theme.Space.m)
                    .chalantField()
                Button("Add") { add(draftRule); draftRule = "" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
                    .disabled(draftRule.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            SettingNote(
                "A tool name on its own holds every call to it, which for Bash is dozens a "
                + "minute. A pattern holds only what it names: Bash(rm *) is the deletes and "
                + "nothing else. Same shape as Claude Code's own permission rules, and * is the "
                + "only special character."
            )
            let unused = SessionStore.suggestedApprovalRules.filter { !rules.contains($0) }
            if !unused.isEmpty {
                Text("Suggested")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                WrappingRules(rules: unused) { add($0) }
            }
            SettingNote(
                "The way out of a broad rule is Always allow on the card itself, which "
                + "makes a standing permission below, so a rule as broad as Bash stays "
                + "livable."
            )
            SettingDivider()
            armRow(armed: armed)
            if !rules.isEmpty, !armed {
                SettingNote(
                    "Or do it by hand. Holding a call needs one more hook than posting a "
                    + "pill does, because PreToolUse is the only event whose answer can stop a "
                    + "command from running. Merge this into ~/.claude/settings.json."
                )
                holdSnippet
            }
        }
    }

    /// The one button that turns rules into a feature.
    ///
    /// Until this existed, arming meant pasting JSON into
    /// ~/.claude/settings.json by hand, and the founder had rules
    /// configured for a day without one of them ever firing. A feature
    /// whose setup step nobody completes is not a shipped feature.
    ///
    /// The whole safety story is said out loud rather than promised:
    /// what it adds, that the old file is copied aside first, and that
    /// it can be taken back out.
    @ViewBuilder
    private func armRow(armed: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: armed ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(Theme.Fonts.icon(.m))
                .foregroundStyle(armed ? Theme.positive : Theme.textTertiary)
            Text(armed
                 ? "Armed. Anything matching a rule above stops and asks you."
                 : "Not armed. These rules hold nothing until Chalant's PreToolUse hook is in place.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.m)
            if armed {
                Button("Disarm") { armOutcome = HookInstall.disarm() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Arm it") { armOutcome = HookInstall.arm() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
            }
        }
        if let armOutcome {
            switch armOutcome {
            case .armed(let backup):
                SettingNote(
                    (armed ? "Written. " : "Taken back out. ")
                    + (backup.map { "Your old settings file is at \($0)." }
                       ?? "There was no settings file to back up.")
                    + " Claude Code picks this up on its next session; ones already running keep "
                    + "the hooks they started with.")
            case .alreadyArmed:
                SettingNote("It was already there. Nothing was written.")
            case .refused(let why):
                Text(why)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !armed {
            SettingNote(
                "Arm it adds one PreToolUse hook to ~/.claude/settings.json, merging with the "
                + "hooks already there rather than replacing them, and copies the old file aside "
                + "first. Disarm takes only that one line back out.")
        }
    }

    /// Answering the prompt itself.
    ///
    /// A different switch from the rules above and worth keeping apart
    /// from them. The rules decide which calls to INTERRUPT, and turning
    /// them on means choosing to be asked about things nobody was asking
    /// you about. This one interrupts nothing: it takes the questions
    /// Claude Code was already going to ask and puts them where you can
    /// answer them.
    private var promptsCard: some View {
        let on = HookInstall.answersPrompts()
        return SettingCard(title: "Answer prompts and questions here") {
            SettingNote(
                "When Claude Code stops to ask permission, the question arrives on the island "
                + "with Allow and Deny on it, and answering settles it in the terminal too. "
                + "Nothing that was not already being asked about gets held up. The prompt "
                + "still appears in its own terminal either way, so this adds a second place "
                + "to answer rather than moving the question."
            )
            HStack(spacing: Theme.Space.m) {
                Image(systemName: on ? "checkmark.circle.fill" : "questionmark.circle")
                    .font(Theme.Fonts.icon(.m))
                    .foregroundStyle(on ? Theme.positive : Theme.textTertiary)
                Text(on
                     ? "On. New sessions hand their prompts and questions to Chalant."
                     : "Off. Prompts stay in the terminal they came from.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.m)
                if on {
                    Button("Turn off") { promptOutcome = HookInstall.disarmPrompts() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Turn on") { promptOutcome = HookInstall.armPrompts() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(accent)
                }
            }
            if let promptOutcome {
                switch promptOutcome {
                case .armed(let backup):
                    SettingNote(
                        (on ? "Written. " : "Taken back out. ")
                        + (backup.map { "Your old settings file is at \($0)." }
                           ?? "There was no settings file to back up.")
                        + " Claude Code picks this up on its next session; ones already running "
                        + "keep the hooks they started with.")
                case .alreadyArmed:
                    SettingNote("It was already there. Nothing was written.")
                case .refused(let why):
                    Text(why)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Cursor and Codex, through the shim that speaks for them.
    ///
    /// Neither runs HTTP hooks, so both go through a command in the
    /// bundle. And neither has Claude Code's second event, the one that
    /// fires only when a person is actually needed: they have "before
    /// this tool call" and nothing else. So the policy rules above do
    /// the deciding for these two, and only what those rules send to you
    /// becomes a card. Holding every shell command an agent runs is the
    /// unlivable version of this feature.
    private var otherAgentsCard: some View {
        let cursorOn = HookInstall.cursorAnswers()
        let codexOn = HookInstall.codexAnswers()
        return SettingCard(title: "Cursor and Codex") {
            SettingNote(
                "Their held calls land in the same queue as Claude Code's, on their own rows. "
                + "Chalant writes one entry into each tool's own hooks file, merging with what "
                + "is already there and copying the old file aside first."
            )
            agentRow(label: "Cursor", on: cursorOn,
                     detail: "Shell commands and MCP calls.",
                     arm: { HookInstall.armCursor() }, disarm: { HookInstall.disarmCursor() })
            SettingDivider()
            agentRow(label: "Codex", on: codexOn,
                     detail: "Tool calls. Untested end to end: there is no Codex on this Mac, "
                           + "so this one is built from its documentation rather than proven. "
                           + "It fails silent, so the worst case is Codex carrying on as before.",
                     arm: { HookInstall.armCodex() }, disarm: { HookInstall.disarmCodex() })
            if let outcome = otherAgentOutcome {
                switch outcome {
                case .armed(let backup):
                    SettingNote(backup.map { "Written. Your old file is at \($0)." }
                                ?? "Written. There was no file to back up.")
                case .alreadyArmed:
                    SettingNote("It was already there. Nothing was written.")
                case .refused(let why):
                    Text(why)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func agentRow(
        label: String, on: Bool, detail: String,
        arm: @escaping () -> HookInstall.ArmOutcome,
        disarm: @escaping () -> HookInstall.ArmOutcome
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                .font(Theme.Fonts.icon(.m))
                .foregroundStyle(on ? Theme.positive : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            Button(on ? "Turn off" : "Turn on") {
                otherAgentOutcome = on ? disarm() : arm()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// The tool that lets an agent ask you something on purpose.
    ///
    /// Not installed by this app, and that is the difference between it
    /// and the switch above. Registering an MCP server means editing
    /// `~/.claude.json`, a different file from the one the switch
    /// touches and a bigger thing to do on somebody's behalf without
    /// being asked for it. So this is a real path in a real command,
    /// and the person runs it.
    private var askToolCard: some View {
        SettingCard(title: "Let an agent ask you a question") {
            SettingNote(
                "Claude Code's own question dialog lives in the terminal it was asked in, and "
                + "nothing outside that process can answer it. This adds an ask_user tool that "
                + "goes through MCP elicitation instead, which arrives on the island with its "
                + "choices on it, or a box to write in. Answer it and the agent carries on. "
                + "Needs the switch above, which is what catches the question."
            )
            HStack(spacing: Theme.Space.m) {
                Text(HookInstall.askServerCommand)
                    .font(Theme.Fonts.captionMono)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HookInstall.askServerCommand, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// What you have handed over, and when it runs out.
    private var grantsCard: some View {
        let live = policy.live()
        return SettingCard(title: "Standing permissions") {
            SettingNote(
                "Made from an approval card. Allow … for makes one in that folder with an "
                + "end time; Always allow makes one everywhere with none. None of them can "
                + "allow the things Chalant always asks about, and every one is revocable "
                + "here."
            )
            if live.isEmpty {
                SettingNote("Nothing standing. Every call is decided as it comes.")
            } else {
                ForEach(live) { grant in
                    HStack(spacing: Theme.Space.m) {
                        Text(grant.pattern)
                            .font(Theme.Fonts.captionMono)
                            .foregroundStyle(Theme.textPrimary)
                        Text(grant.repo.isEmpty
                             ? "everywhere"
                             : "in \((grant.repo as NSString).lastPathComponent)")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: Theme.Space.m)
                        Text(grant.expires.map { Self.until($0) } ?? "until revoked")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textTertiary)
                        Button("Revoke") { policy.revoke(id: grant.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                Button("Revoke all") { policy.revokeAll() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    /// Everything settled without anybody being asked.
    ///
    /// The price of a gate that answers for you is an account of what it
    /// answered. Without this, "auto-allowed by policy" is something the
    /// app says about itself and nobody can check.
    private var auditCard: some View {
        SettingCard(title: "Decided for you") {
            SettingNote(
                "Every call Chalant settled on its own, newest first, since it started. Kept in "
                + "memory only: this is an account of what this run of the app has done."
            )
            if policy.audit.isEmpty {
                SettingNote("Nothing yet.")
            } else {
                ForEach(policy.audit.prefix(30)) { entry in
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: entry.allowed
                              ? "checkmark.circle.fill" : "hand.raised.fill")
                            .font(Theme.Fonts.icon(.s))
                            .foregroundStyle(entry.allowed ? Theme.positive : Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.detail.isEmpty ? entry.tool : entry.detail)
                                .font(Theme.Fonts.captionMono)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Text(entry.allowed
                                 ? "allowed · \(entry.rule)"
                                 : "sent to you · \(entry.rule)")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: Theme.Space.m)
                        Text(Self.clock.string(from: entry.at))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                if policy.audit.count > 30 {
                    SettingNote("\(policy.audit.count - 30) older ones not shown.")
                }
                Button("Clear") { policy.clearAudit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func until(_ date: Date, now: Date = Date()) -> String {
        let left = date.timeIntervalSince(now)
        guard left > 0 else { return "expired" }
        if left < 90 { return "\(Int(left.rounded(.down)))s left" }
        if left < 5400 { return "\(Int((left / 60).rounded(.down)))m left" }
        return "\(Int((left / 3600).rounded(.down)))h left"
    }

    /// The room's own dials.
    ///
    /// All of them live here rather than in the island, which carries no
    /// settings of its own and is not about to start: the room is a
    /// glance surface's grown-up sibling, not a window, and a gear in it
    /// would be the first step toward one. Every default below is chosen
    /// so that nobody has to open this card at all.
    private var roomCard: some View {
        SettingCard(title: "The sessions room") {
            SettingNote(
                "Press the Sessions shortcut, or click the arrow in the island's tool row, to "
                + "open every agent on this Mac beside the one you have picked."
            )
            if SessionRemote.isInstalled("com.googlecode.iterm2") {
                SettingPicker(
                    label: "Start new sessions in",
                    selection: $startsIn,
                    options: [("Terminal", "terminal"), ("iTerm", "iterm")],
                    width: 200
                )
            }
            SettingNote(
                "The + in the room's header opens a terminal in a folder you pick and runs "
                + "Claude Code in it. A session started that way can be driven from the island "
                + "straight away, which one started inside an editor's built-in terminal cannot."
            )
            SettingDivider()
            SettingToggle(label: "Send straight to the terminal", isOn: $straightToTerminal)
            SettingNote(
                "On, what you type goes into the running session now, the way typing into its "
                + "window does, and you do not wait for its next turn. Chalant finds the exact "
                + "tab by the terminal device that session is attached to, so it can only ever "
                + "land in that one window. Terminal and iTerm only: an editor's built-in "
                + "terminal cannot be named from outside, and typing blind into an editor would "
                + "land in whatever file is open, so those keep the queue."
            )
            SettingDivider()
            SettingPicker(
                label: "Keep finished sessions for",
                selection: $historyWindow,
                options: [("Off", "off"), ("1 hour", "hour"), ("2 hours", "default"), ("Today", "today")],
                width: 260
            )
            SettingNote(
                "Only sessions Chalant actually watched end, never old transcripts it found "
                + "lying on disk, and eight at most. Off keeps none of them rather than "
                + "hiding them."
            )
            SettingDivider()
            SettingToggle(label: "Show what agents are doing", isOn: $showsToolActivity)
            SettingNote(
                "Threads each tool call into the conversation as it happens. Off leaves only "
                + "the words, which is quieter and tells you nothing while a turn is running."
            )
            SettingDivider()
            SettingPicker(
                label: "Row height",
                selection: $rowDensity,
                options: [("Compact", "compact"), ("Comfortable", "comfortable")],
                width: 260
            )
            SettingNote("Compact drops the line saying what each agent is doing, so more "
                        + "sessions fit without scrolling.")
            SettingDivider()
            Text("Groups")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
            ForEach(SessionStore.Group.allCases) { group in
                groupToggle(group)
            }
        }
    }

    @ViewBuilder
    private func groupToggle(_ group: SessionStore.Group) -> some View {
        if group.canBeHidden {
            SettingToggle(label: group.title, isOn: groupBinding(group))
        } else {
            // Drawn, disabled, with the reason on it. A band whose whole
            // purpose is "something is blocked on you" being switchable
            // off is a way to make this app quietly fail at its one job,
            // and a row that is simply absent reads as an oversight
            // rather than as a decision.
            SettingRow(label: group.title) {
                Text("Always on")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textGhost)
            }
        }
    }

    /// Absent means on. Nobody has opened this card, and every band
    /// ships visible.
    private func groupBinding(_ group: SessionStore.Group) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: group.settingKey) as? Bool ?? true },
            set: { UserDefaults.standard.set($0, forKey: group.settingKey) }
        )
    }

    private var holdSnippet: some View {
        let text = HookInstall.holdSnippet
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(text)
                .font(Theme.Fonts.captionMono)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.surface))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(accent)
        }
    }

    var body: some View {
        // Read once per appearance rather than once per reference below:
        // these are live file reads, and the banner's placement and the
        // cards it decides to place must agree on the same answers.
        let statuses = Dictionary(
            uniqueKeysWithValues: HookInstall.Agent.allCases.map { ($0, HookInstall.status(agent: $0)) }
        )
        let allInstalled = statuses.values.allSatisfy { $0 == .installed }
        VStack(alignment: .leading, spacing: Theme.Space.settingsGroup) {
            // Not installed means a session can never announce itself
            // and a queued message can never arrive, with nothing on
            // screen saying why, so this leads the tab rather than
            // waiting at the bottom to be found (B9, founder
            // 2026-08-02: "if not installed put this at the top"). Any
            // one of the three missing is reason enough to lead: a
            // founder running Cursor and Claude Code both wants to
            // know Cursor is silent even while Claude Code is fine.
            if !allInstalled {
                hookCards(statuses)
            }

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

            phoneCard

            promptsCard

            askToolCard

            otherAgentsCard

            approvalCard

            grantsCard

            auditCard

            roomCard

            // Real path, not a faked pill (H4, founder 2026-08-02: "I
            // want to test the notification and everything"): posts an
            // actual needs-input activity, the same call a stopped
            // agent's hook makes, so it proves the door is open and the
            // glance actually flashes rather than asserting it does.
            SettingCard(title: "Test the notification path") {
                SettingNote(
                    "Fires a real needs-input pill the way a stopped agent's hook does: it "
                    + "should flash the glance and reach the collapsed island. Clears itself "
                    + "in a few seconds either way."
                )
                Button("Send a test notification") { sendTestNotification() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
            }

            SettingCard(title: "How this works") {
                SettingNote(
                    "Chalant reads what these tools already write: Claude Code under "
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
                    "Codex keeps no session records on disk, so it never appears above. Its hook "
                    + "card below is the only way it can tell Chalant anything."
                )
            }

            if allInstalled {
                hookCards(statuses)
            }
        }
    }

    /// Posts, then clears itself: a founder hit two of the assistant's
    /// own uncleaned test pills tonight, so this one takes itself down
    /// rather than leaving a row for anyone to dismiss by hand.
    /// `activities.resolveIfPending` (H5) never reaches this one, since
    /// it names no session for markGone to end.
    private func sendTestNotification() {
        let id = "chalant-test-\(UUID().uuidString.prefix(8))"
        activities.push(
            id: id,
            title: "Test notification (safe to ignore)",
            detail: "Checking the path a real needs-input pill takes.",
            state: .needsInput
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            activities.clear(id: id)
        }
    }

    /// One card per agent rather than three written out by hand: each
    /// agent's install state, note and snippet differ, but the shape
    /// they sit in does not.
    private func hookCards(_ statuses: [HookInstall.Agent: HookInstall.Status]) -> some View {
        ForEach(HookInstall.Agent.allCases) { agent in
            hookCard(agent, statuses[agent] ?? .missing)
        }
    }

    /// Live install state for `scripts/chalant-hook`. Discovery alone
    /// can only say a session's file went quiet; the hook is what says
    /// a session is actually waiting for you, and for Claude Code it
    /// is also what lets a queued message reach one at all
    /// (notch-messaging-plan-2026-08-01.md, W-E).
    private func hookCard(_ agent: HookInstall.Agent, _ status: HookInstall.Status) -> some View {
        SettingCard(title: "\(agent.label) hook") {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: status.symbol)
                    .font(Theme.Fonts.icon(.s))
                    // Installed reads as healthy, in colour, rather than
                    // the grey a passing check used to wear here. Grey
                    // says "nothing to report," not "this is fine."
                    .foregroundStyle(status == .installed ? Theme.positive : accent)
                Text(status.label)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            switch status {
            case .installed:
                SettingNote(installedNote(for: agent))
            case .missing:
                // This card is about the REPORTING hook, which is still
                // paste-it-yourself for all three. The card further down
                // writes Cursor's and Codex's files, and it is about a
                // different hook: the one that holds a call rather than
                // announces one. Saying "Chalant never writes this file"
                // here, six inches above a button that writes it, was
                // true when it was written and is now a contradiction
                // somebody would read as a bug in one card or the other.
                SettingNote(
                    "Paste this into \(agent.configPath), merging the arrays with whatever is "
                    + (agent == .claude
                       ? "already there. It is the pill and the message path, not the approval "
                         + "one: the switches below install that themselves."
                       : "already there. This is the pill, not the approval gate. Chalant can "
                         + "write the gate into this same file itself, under Cursor and Codex "
                         + "below.")
                )
                hookSnippet(for: agent)
            case .unreadable:
                SettingNote(
                    "\(agent.configPath) did not parse. Check it for a stray comma before "
                    + "assuming the hook itself is missing; that is a different problem with "
                    + "the same symptom."
                )
                hookSnippet(for: agent)
            }
        }
    }

    /// Claude Code's queued message reaches a running session; neither
    /// of the other two does yet (B8, cursor-codex-hooks-evidence-
    /// 2026-08-02.md: message injection is unproven for both), so only
    /// its note claims that.
    private func installedNote(for agent: HookInstall.Agent) -> String {
        switch agent {
        case .claude:
            return "Claude Code hands this app a Stop event on every session: a pill the moment "
                + "one wants you, and the way a queued message reaches it."
        case .cursor:
            return "Cursor posts a pill the moment a session finishes, or wants a permission you "
                + "would otherwise only see in its own window. Messaging isn't wired up for "
                + "Cursor sessions yet."
        case .codex:
            return "Codex posts a pill the moment a session finishes. Messaging isn't wired up "
                + "for Codex sessions yet."
        }
    }

    private func hookSnippet(for agent: HookInstall.Agent) -> some View {
        let text = HookInstall.snippet(for: agent)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(text)
                .font(Theme.Fonts.captionMono)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.surface))
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
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
                // Was the full `cwd`, which is the same forty characters
                // on every row for anyone who works in one place, and was
                // read once and never again. The room stopped spending
                // its line on that; this list was the other half of the
                // same habit, and the founder's own screen showed four
                // rows here reading nothing but a path and a mood word.
                Text(SessionActivity.railLine(for: session, disambiguating: false))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Space.m)
            // Where it lives, in the width the state word used to take.
            // Still worth a column here, unlike in the rail: this list is
            // every agent on the machine, so telling two repos apart is
            // the thing it is actually for.
            Text(Self.place(session))
                .font(Theme.Fonts.microMono)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Text(RelativeAge.short(session.stateSince))
                .font(Theme.Fonts.microMono)
                .foregroundStyle(Theme.textGhost)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.title), \(SessionActivity.line(for: session).text), \(Self.place(session))")
    }

    /// The folder, and the branch when there is one. The last component
    /// only: `/Users/someone/Developer/work/moai` and
    /// `/Users/someone/Developer/play/moai` are told apart by the branch
    /// beside them far more often than by a path this column has no room
    /// for anyway.
    private static func place(_ session: SessionStore.Session) -> String {
        let folder = session.cwd.split(separator: "/").last.map(String.init) ?? session.cwd
        guard let branch = session.branch, !branch.isEmpty else { return folder }
        return "\(folder) · \(branch)"
    }

    /// Filled for done and failed, matching `ActivityStore.State.symbol`:
    /// the same idea (a run that finished, one way or the other) wears
    /// the same weight everywhere it's shown, not a quieter unfilled
    /// pair here that just happened to read as this row mattering less.
    private static func symbol(_ state: SessionStore.State) -> String {
        switch state {
        case .needsInput: return "exclamationmark.circle.fill"
        case .working: return "circle.dashed"
        case .idle: return "pause.circle"
        case .stale: return "clock"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    // The state word column that used to live here is gone: "Waiting for
    // you", "Working", "Waiting for input" are the mood words the
    // founder called vague (2026-08-06), and every one of them has been
    // replaced by the row's own line saying the actual thing. The glyph
    // stays, because a mark is a mark and a claim is a claim.
}

// MARK: - What shows

struct WhatShowsSection: View {
    let events: EventKitService
    /// Only consulted for `stats.battery != nil`, to leave the
    /// Battery toggle out of a settings window on a Mac that can
    /// never grow one: a switch nobody's hardware can act on is a
    /// dead control, the same call made for the tab itself
    /// (ExpandedView.swift).
    @ObservedObject var stats: SystemStatsController
    @ObservedObject var weather: WeatherController
    /// Absorbed from the old Arrangement page: its cards render inline
    /// below, built by `ArrangementCards(layout:)`. `@ObservedObject`
    /// here, not just passed through, is what makes a drag or a preset
    /// tap redraw this page: `ArrangementCards` itself is a plain
    /// struct, not a `View`, so it triggers nothing on its own.
    @ObservedObject var layout: IslandLayoutStore

    @AppStorage("showMedia") private var showMedia = true
    @AppStorage("showAmbience") private var showAmbience = true
    @AppStorage("showCalendar") private var showCalendar = true
    @AppStorage("showReminders") private var showReminders = true
    @AppStorage("showWeather") private var showWeather = true
    @AppStorage("toolGo") private var toolGo = true
    @AppStorage("toolClips") private var toolClips = true
    @AppStorage("toolShelf") private var toolShelf = true
    @AppStorage("toolNotes") private var toolNotes = true
    @AppStorage("toolFocus") private var toolFocus = true
    @AppStorage("toolChat") private var toolChat = true
    @AppStorage("toolSessions") private var toolSessions = true
    @AppStorage("toolBattery") private var toolBattery = true
    @AppStorage(ChatController.serviceKey) private var chatService = "claude"
    @AppStorage(EventKitService.reminderListKey) private var reminderListID = ""

    // Moved from GlanceSection (What shows absorbs Glance): the two cards
    // below used to live on their own page, and `showCalendar` above
    // already covers the one property both pages read.
    @AppStorage(MusicController.playingSignalKey) private var playingSignal
        = MusicController.playingSignalDefault
    @AppStorage("glanceMusic") private var glanceMusic = true
    @AppStorage("glanceSession") private var glanceSession = true
    @AppStorage("glanceBattery") private var glanceBattery = false
    @AppStorage("collapsedSong") private var collapsedSong = true
    @AppStorage("glanceAgents") private var glanceAgents = true
    @AppStorage("glanceNextEvent") private var glanceNextEvent = true

    /// Writable reminder lists, refreshed each time this section appears.
    @State private var reminderLists: [(title: String, id: String)] = []

    var body: some View {
        // The old Arrangement page's two card groups, built fresh each
        // time this body runs so they always read the live layout.
        let cards = ArrangementCards(layout: layout)
        VStack(alignment: .leading, spacing: Theme.Space.settingsGroup) {
            SettingCard(title: "Show or hide") {
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
                        .tint(Theme.controlTint)
                        .fixedSize()
                        .accessibilityLabel("Save reminders to")
                    }
                }
                SettingDivider()
                SettingToggle(label: "Weather", isOn: $showWeather)
                SettingNote("A rough reading from Open-Meteo, no account or key needed.")
                SettingDivider()
                SettingToggle(label: "Shortcuts", isOn: $toolGo)
                SettingDivider()
                SettingToggle(label: "Clipboard", isOn: $toolClips)
                SettingDivider()
                SettingToggle(label: "Shelf", isOn: $toolShelf)
                SettingDivider()
                SettingToggle(label: "Notes", isOn: $toolNotes)
                SettingDivider()
                SettingToggle(label: "Focus & timers", isOn: $toolFocus)
                // Dark-shipped tools keep no switch: a row for a tab
                // that cannot appear is a promise the switcher breaks
                // (FeatureFlags).
                if FeatureFlags.sessionsVisible {
                    SettingDivider()
                    SettingToggle(label: "Sessions", isOn: $toolSessions)
                }
                if stats.battery != nil {
                    SettingDivider()
                    SettingToggle(label: "Battery", isOn: $toolBattery)
                }
                if FeatureFlags.chatVisible {
                    SettingDivider()
                    SettingToggle(label: "Chat", isOn: $toolChat)
                    if toolChat {
                        SettingPicker(
                            label: "Service",
                            selection: $chatService,
                            options: [("Claude", "claude"), ("ChatGPT", "chatgpt"),
                                      ("Gemini", "gemini")]
                        )
                        SettingNote(
                            "Your own account, in a small built-in browser. Chalant is not affiliated "
                            + "with Anthropic, OpenAI, or Google."
                        )
                    }
                }
            }

            // Absorbed from the old Arrangement page: what's on the
            // island, what's held back, saved presets, and the reset.
            cards.islandArrangement

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
                if FeatureFlags.sessionsVisible {
                    SettingToggle(label: "Agents running", isOn: $glanceAgents)
                    SettingNote(
                        "A mark beside the notch while Claude Code or Cursor sessions are going. It "
                        + "breathes while they work and holds still, in the accent, the moment one is "
                        + "waiting on you."
                    )
                    SettingDivider()
                }
                SettingToggle(label: "Battery", isOn: $glanceBattery)
                SettingNote(
                    "The charge, last in line: it only takes the space when nothing else beside the "
                    + "notch has anything to say. It turns red below 20%."
                )
            }

            // Also absorbed from the old Arrangement page: which one of
            // the cards above actually gets the collapsed island's one
            // slot, in order of precedence.
            cards.collapsedOrder

            SettingCard(title: "What interrupts") {
                SettingToggle(label: "Clear the glance while playing", isOn: $glanceMusic)
                SettingDivider()
                SettingToggle(label: "Event coming up", isOn: $glanceNextEvent)
                if !showCalendar {
                    SettingNote("Needs the Calendar today block on, above.")
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
        // The toggle is the controller's whole lifecycle: on starts it,
        // off stops it (timer, wake observer, location asks, all of it).
        // Off-then-on is also the one user action that can re-raise the
        // macOS location prompt while it is still undecided.
        .onChange(of: showWeather) { _, on in
            if on { weather.start() } else { weather.stop() }
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
        VStack(alignment: .leading, spacing: Theme.Space.settingsGroup) {
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
                // Not "on the pill": Pill is also the name of a display
                // style now, so that label read as a setting for one
                // kind of screen when it governs the resting island on
                // every screen.
                SettingToggle(label: "Accent rim while resting", isOn: $glowOn)
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

// MARK: - About

struct AboutSection: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.settingsGroup) {
            SettingCard(title: "Version") {
                SettingRow(label: "Chalant") {
                    Text(version)
                        .font(Theme.Fonts.captionMono)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            SettingCard(title: "Privacy") {
                SettingNote(
                    "Everything Chalant reads stays on this Mac: what is playing, your day"
                    + (FeatureFlags.sessionsVisible ? ", your sessions" : "")
                    + "."
                )
                SettingDivider()
                // The one honest exception to the note above: weather is
                // the only thing this app ever sends off the Mac, so it
                // gets its own line rather than sitting quietly folded
                // into a blanket "nothing is sent anywhere."
                SettingNote(
                    "Weather asks Open-Meteo for the sky above your approximate area. "
                    + "Nothing else Chalant reads leaves this Mac."
                )
                SettingDivider()
                SettingNote(
                    "Speech is transcribed by macOS itself, and the recording is deleted the moment "
                    + "the phrase is understood."
                )
                if FeatureFlags.chatVisible {
                    SettingDivider()
                    SettingNote(
                        "Chat opens your own accounts in a small built-in browser. Chalant is not "
                        + "affiliated with the services it opens."
                    )
                }
            }
        }
    }
}

/// Suggested rules laid out in rows that wrap.
///
/// Hand-wrapped rather than a `LazyVGrid`, because these are chips of
/// wildly different widths and a grid gives every one the width of the
/// longest, which left "Bash(rm *)" floating in the middle of a column
/// sized for "Bash(git reset --hard *)".
private struct WrappingRules: View {
    let rules: [String]
    let add: (String) -> Void
    @Environment(\.chalantAccent) private var accent

    /// Two per row. A measured flow layout is the right answer and a
    /// much bigger one; this panel is a fixed width and these strings
    /// are known, so the cheap version is honest here.
    private var rows: [[String]] {
        stride(from: 0, to: rules.count, by: 2).map {
            Array(rules[$0..<min($0 + 2, rules.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: Theme.Space.s) {
                    ForEach(row, id: \.self) { rule in
                        Button {
                            add(rule)
                        } label: {
                            HStack(spacing: Theme.Space.xs) {
                                Image(systemName: "plus")
                                    .font(Theme.Fonts.icon(.s))
                                Text(rule)
                                    .font(Theme.Fonts.captionMono)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(accent)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
