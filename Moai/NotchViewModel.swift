import AppKit
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    enum IslandState {
        case collapsed
        case listening
        case expanded
    }

    enum Tab {
        case ask
        case clipboard
        case shelf
        case links
    }

    /// Utility panes slide over the content as a single drawer:
    /// only one can be open, and collapsing always closes it.
    enum Pane {
        case none
        case focus
        case settings
    }

    @Published var state: IslandState = .collapsed
    @Published var isHovering = false
    @Published var tab: Tab = .ask
    @Published var pane: Pane = .none

    /// Pointer position across the island, 0...1, published by the
    /// window controller's hover poll — quantized so casual movement
    /// costs a few re-renders per second, not twenty. nil = no light.
    @Published var pointerUnit: CGFloat?

    /// Which way the next tab switch should slide, set by TabRow just
    /// before the tab changes so both land in the same transaction.
    var tabSlideDirection: CGFloat = 1

    /// Draft text in the Do box. Lives here so clipboard and shelf
    /// actions can hand content to the Do surface.
    @Published var draftPrompt = ""

    /// Result surface state, shared by typed and spoken input.
    @Published var answer = ""
    @Published var errorText = ""
    @Published var isWorking = false

    /// Content attached to the next question (a file or a clip).
    @Published var pendingContext: (name: String, text: String)?

    // Feature stores
    let music = MusicController()
    let clipboard = ClipboardStore()
    let shelf = ShelfStore()
    let notes = NotesStore()
    let events = EventKitService()
    let timer = CountdownController()
    let focus = FocusController()
    let voice = VoiceController()
    let stats = SystemStatsController()
    let shortcuts = ShortcutStore()
    private(set) lazy var engine = ActionEngine(model: self)

    /// Default pill for notch-less displays, so Moai works on any Mac.
    static let defaultNotchSize = CGSize(width: 196, height: 34)

    /// Expanded island size for a stored size preset. Shared by the
    /// view (rendering) and the window controller (hover zones).
    static func expandedSize(for preset: String) -> CGSize {
        switch preset {
        case "cozy": return CGSize(width: 630, height: 370)
        case "large": return CGSize(width: 700, height: 420)
        default: return CGSize(width: 560, height: 320)
        }
    }

    /// Physical notch size measured by NotchWindowController.
    var notchSize = NotchViewModel.defaultNotchSize

    /// Set by the window controller so the panel can grab key focus.
    var onExpandChange: ((Bool) -> Void)?

    init() {
        // Before any view can read the key: legacy plaintext storage
        // moves into the Keychain once.
        KeychainStore.migrateFromDefaults(key: "anthropicKey", account: "anthropicKey")
    }

    func start() {
        music.start()
        clipboard.start()
        stats.start()
        // Theme.Feel reads the system Reduce Motion flag at render
        // time; nudge the tree when it flips so the change is live.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    func expand() {
        guard state != .expanded else { return }
        state = .expanded
        onExpandChange?(true)
    }

    func collapse() {
        guard state == .expanded else { return }
        state = .collapsed
        // Model-held pane state doesn't reset with the view tree the
        // way @State did — the island must always reopen to content.
        pane = .none
        onExpandChange?(false)
    }

    // MARK: - Hover opens the island

    private var hoverCollapseWork: DispatchWorkItem?

    func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            hoverCollapseWork?.cancel()
            hoverCollapseWork = nil
            let expandOnHover = UserDefaults.standard
                .object(forKey: "expandOnHover") as? Bool ?? true
            if state == .collapsed, expandOnHover { expand() }
        } else if state == .expanded {
            scheduleHoverCollapse()
        }
    }

    /// Collapse as soon as the cursor leaves, unless the user is
    /// mid-something: typing a draft, waiting on an answer, or holding
    /// an attachment. The tiny default delay is a debounce so the island
    /// doesn't thrash when the pointer skims its edge.
    private func scheduleHoverCollapse() {
        let delay = UserDefaults.standard
            .object(forKey: "collapseDelay") as? Double ?? 0.05
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.state == .expanded, !self.isHovering,
                  !self.isWorking, self.draftPrompt.isEmpty,
                  self.pendingContext == nil, self.pane == .none else { return }
            self.collapse()
        }
        hoverCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Voice, hold to talk

    func beginListening() {
        guard state == .collapsed else { return }
        state = .listening
        voice.begin()
    }

    /// Mic button in the expanded island: tap to talk, tap to run.
    func toggleListening() {
        if state == .listening {
            endListening()
        } else {
            state = .listening
            voice.begin()
        }
    }

    func endListening() {
        guard state == .listening else { return }
        // Leave listening immediately — finalization can take a second
        // and lingering in the listening UI reads as "release didn't
        // work". Dots show while the transcript settles.
        tab = .ask
        state = .expanded
        onExpandChange?(true)
        isWorking = true
        voice.end { [weak self] text in
            guard let self else { return }
            self.isWorking = false
            let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if spoken.isEmpty {
                self.answer = self.voice.failure
                    ?? "Heard nothing. Hold a beat longer next time."
            } else {
                self.submit(spoken)
            }
        }
    }

    /// Discard the recording without running anything.
    func cancelListening() {
        guard state == .listening else { return }
        voice.cancel()
        state = .collapsed
    }

    /// Attach text (from a clip or file) and jump to the Do surface.
    func askAbout(name: String, text: String) {
        pendingContext = (name, text)
        tab = .ask
        expand()
    }

    // MARK: - One path for every input

    func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        errorText = ""

        Task {
            // Local verbs first: instant, offline, keyless.
            if let local = await engine.handle(text) {
                answer = local
                return
            }

            // Beyond local verbs, the optional key takes over.
            let key = KeychainStore.read("anthropicKey") ?? ""
            guard !key.isEmpty else {
                answer = "That one needs the optional key. Reminders, notes, timers, focus, and music all work without it. Gear icon, top right."
                return
            }

            var fullPrompt = text
            if let context = pendingContext {
                fullPrompt = """
                Attached content from "\(context.name)":
                \(context.text)

                Question: \(text)
                """
                pendingContext = nil
            }

            answer = ""
            isWorking = true
            do {
                for try await delta in ClaudeService.stream(prompt: fullPrompt, apiKey: key) {
                    answer += delta
                }
            } catch {
                errorText = error.localizedDescription
            }
            isWorking = false
        }
    }
}
