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
                if let latest = updates.latest {
                    SettingDivider()
                    // A real push button beside the state it acts on,
                    // not tinted text: same lesson as the tour button
                    // below (nothing said plain text could be clicked).
                    Button("Install Chalant \(latest)", action: onInstallUpdate)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .tint(accent)
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

            SettingCard(title: "Opening the island") {
                SettingToggle(label: "Open when an agent finishes", isOn: $openOnFinish)
                SettingNote(
                    "The island opens on the session that just finished, showing what it said "
                    + "with the reply box under it. It stays out of the way while you are "
                    + "dictating or already typing in it."
                )
                SettingDivider()
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
    /// Not `@ObservedObject`: this view only calls into it (the test
    /// button below) and never renders its published state.
    let activities: ActivityStore
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
    /// What the last Arm/Disarm actually did, held so the card can say
    /// so instead of the button going quiet and the user wondering.
    @State private var armOutcome: HookInstall.ArmOutcome?

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
            SettingNote("Compact drops the folder and branch line, so more sessions fit without scrolling.")
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
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
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

            approvalCard

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
                SettingNote(
                    "Chalant never writes \(agent.configPath) for you. Paste this in, merging "
                    + "the arrays with whatever is already there:"
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
    /// Only consulted for `stats.battery != nil`, to leave the
    /// Battery toggle out of a settings window on a Mac that can
    /// never grow one: a switch nobody's hardware can act on is a
    /// dead control, the same call made for the tab itself
    /// (ExpandedView.swift).
    @ObservedObject var stats: SystemStatsController

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
    @AppStorage("toolSessions") private var toolSessions = true
    @AppStorage("toolBattery") private var toolBattery = true
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
                SettingToggle(label: "Sessions", isOn: $toolSessions)
                if stats.battery != nil {
                    SettingDivider()
                    SettingToggle(label: "Battery", isOn: $toolBattery)
                }
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
