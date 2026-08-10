import AppKit
import SwiftUI

/// Settings, moved out of the island into a window of their own.
///
/// The island is a glance surface: it is the wrong place to read a
/// list of thirty switches through a 300pt porthole. Everything here
/// is `@AppStorage`, so this window and the island read the same
/// UserDefaults keys and stay in step with no shared view model and no
/// bindings threaded between them.
///
/// There is exactly one door per job (Design law): when a setting
/// moved here it left the island, it does not live in both.
enum DashboardSection: String, CaseIterable, Identifiable {
    case general
    case sessions
    case whatShows
    case island
    case displays
    case layout
    case glance
    case keyboard
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .sessions: return "Sessions"
        case .whatShows: return "What shows"
        case .island: return "Island"
        case .displays: return "Displays"
        case .layout: return "Arrangement"
        case .glance: return "Glance"
        case .keyboard: return "Keyboard"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sessions: return "chevron.left.forwardslash.chevron.right"
        case .whatShows: return "square.stack"
        // The island's own shape, not a generic window: "Pick an
        // app..." in Shortcuts is the one that opens a window.
        case .island: return "capsule"
        case .displays: return "display.2"
        case .layout: return "rectangle.3.group"
        case .glance: return "eye"
        case .keyboard: return "keyboard"
        case .about: return "info.circle"
        }
    }

    /// The sections the sidebar actually lists. A dark-shipped
    /// feature's section goes with it (FeatureFlags): a settings page
    /// full of arm buttons for a surface that does not exist would be
    /// the one door the hide forgot.
    static var visibleCases: [DashboardSection] {
        allCases.filter { $0 != .sessions || FeatureFlags.sessionsVisible }
    }

    /// Matches the tail of "debug settings <name>" and the old in-island
    /// scroll anchors, so the screenshot harness keeps working after the
    /// pane it used to drive stopped existing. Searches only the
    /// visible sections, so nothing can steer to a hidden one by name.
    static func named(_ name: String) -> DashboardSection? {
        let wanted = name.lowercased()
        return visibleCases.first {
            $0.rawValue.lowercased() == wanted || $0.title.lowercased() == wanted
        }
    }
}

/// Which section the window is showing. A reference type so the window
/// controller can steer an already-open window to a section instead of
/// rebuilding the view.
@MainActor
final class DashboardSelection: ObservableObject {
    @Published var section: DashboardSection? = .general
}

// MARK: - The window

/// The dashboard lives in a plain `NSWindow` rather than a SwiftUI
/// `Window` scene: the menu bar item and the island's gear both open it
/// from AppKit, where `openWindow` is not reachable, and this app
/// already hosts every one of its surfaces this way.
@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let selection = DashboardSelection()

    init(model: NotchViewModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            // No fullSizeContentView: nothing here wants to draw behind
            // the title bar, and letting content start under it puts the
            // page title where the traffic lights already are.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chalant"
        window.titlebarAppearsTransparent = true
        // Deliberately NOT movable by its background. That convenience
        // makes AppKit start a window drag on mouse-down anywhere that
        // is not a control, which pre-empts a SwiftUI drag gesture on a
        // list row: the founder reported dragging an Arrangement row
        // and moving the whole window instead (2026-08-02), and the
        // feature was labelled coming soon rather than fixed.
        //
        // The window has a title bar, so it is still draggable the way
        // every other window is. And this is worth doing even if the
        // row drag needs more work: without it, a failed drag moves the
        // window, and with it a failed drag simply does nothing.
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(Theme.backdropBottom)
        // The island is dark by construction and this window is its
        // other half; the system light theme would make them look like
        // two different apps.
        window.appearance = NSAppearance(named: .darkAqua)
        // Closing must not deallocate the window: this is an accessory
        // app that keeps running headless, and the next "Settings…"
        // reopens this same controller.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("chalant.dashboard")
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: DashboardView(model: model, selection: selection)
        )
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Brings the window up and focuses it. An accessory app has no
    /// Dock icon to activate it, so without the explicit activate the
    /// user clicks "Settings…" and the window opens silently behind
    /// whatever they were looking at — which reads as nothing happening.
    func present(section: DashboardSection?) {
        if let section { selection.section = section }
        // Where it was last left may no longer exist. This was found
        // live: the saved frame was x=3390 on a screen that spanned
        // 2560–5120, and after the displays were rearranged the window
        // opened, took focus, and was nowhere on any of them. Nothing
        // says it went wrong — it reads as the app ignoring the click.
        if let window, !Self.isOnScreen(window.frame, screens: NSScreen.screens.map(\.frame)) {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Whether a remembered frame still lands somewhere reachable.
    ///
    /// Any intersection is not enough: a window peeking a few points
    /// onto a screen has its title bar off it, so it cannot be dragged
    /// back and is effectively lost. It has to be grabbable.
    static func isOnScreen(_ frame: NSRect, screens: [NSRect]) -> Bool {
        screens.contains { screen in
            let shared = screen.intersection(frame)
            return shared.width >= 120 && shared.height >= 60
        }
    }
}

// MARK: - The view

struct DashboardView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var selection: DashboardSelection

    @AppStorage("accentMode") private var accentMode = "silver"

    var body: some View {
        NavigationSplitView {
            // Explicit ForEach with a tag rather than
            // `List(data, selection:)`: that form keys selection off the
            // element's `id`, which would silently bind a String where
            // this binds a section, and both spellings compile.
            List(selection: $selection.section) {
                ForEach(DashboardSection.visibleCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .font(Theme.Fonts.body)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 240)
            .scrollContentBackground(.hidden)
            .background(Theme.backdropTop)
            // Pinned at the leading edge beside the traffic lights,
            // where Mail, Notes and Finder all keep it. Left to itself
            // the automatic one rides the sidebar's trailing edge, so
            // it sat right of the window title with the sidebar open
            // and jumped left when it shut, which reads as the control
            // wandering (founder, 2026-08-01, "at once its left and
            // once its right").
            //
            // The default has to be removed by name or there are two of
            // them: adding this item does not replace it. Photographed
            // with both on screen before this line existed.
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        NSApp.keyWindow?.firstResponder?.tryToPerform(
                            #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(Theme.Fonts.icon(.m))
                    }
                    .help("Hide or show the sidebar")
                    .accessibilityLabel("Toggle sidebar")
                }
            }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.backdrop)
        }
        // `.automatic` hands the divider to AppKit's own
        // NSSplitViewController, which lays it out against the
        // toolbar's default item set. Once that default sidebar toggle
        // was removed for a custom one pinned at the leading edge
        // (a299f64), the divider's own layout pass went stale on first
        // appearance: a stray hairline beside the sidebar that only
        // corrected itself once toggling the sidebar forced AppKit to
        // recompute (D2, founder 2026-08-02, "there is a weird line").
        // `.balanced` draws the divider in SwiftUI itself instead, so it
        // is never tied to that toolbar layout cache in the first place.
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.fixedAccent(for: accentMode) ?? model.music.accent)
        .environment(\.chalantAccent, Theme.fixedAccent(for: accentMode) ?? model.music.accent)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                // The title names the section the sidebar has selected,
                // so a screenshot of this window says what it is without
                // the sidebar in frame.
                Text((selection.section ?? .general).title)
                    .font(Theme.Fonts.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, Theme.Space.xs)
                switch selection.section {
                case .general, nil:
                    GeneralSection(
                        updates: model.updates,
                        onReplayTour: model.replayWelcome,
                        onInstallUpdate: { model.installUpdate?() }
                    )
                case .sessions:
                    // Unreachable while dark-shipped (the sidebar never
                    // lists it, named() never returns it), and harmless
                    // if somehow reached: hidden means General.
                    if FeatureFlags.sessionsVisible {
                        SessionsSection(sessions: model.sessions, activities: model.activities,
                                        policy: model.policy)
                    } else {
                        GeneralSection(
                            updates: model.updates,
                            onReplayTour: model.replayWelcome,
                            onInstallUpdate: { model.installUpdate?() }
                        )
                    }
                case .whatShows:
                    WhatShowsSection(events: model.events, stats: model.stats)
                case .island:
                    IslandSection(music: model.music)
                case .displays:
                    DisplaysSection(displays: model.displays)
                case .layout:
                    LayoutSection(layout: model.layout)
                case .glance:
                    GlanceSection()
                case .keyboard:
                    KeyboardSection()
                case .about:
                    AboutSection()
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xxl)
        }
    }
}

// MARK: - Shared rows

/// One titled card of settings rows. The same card the island's pane
/// used, promoted from a private helper now that six section views draw
/// with it instead of one.
struct SettingCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    /// One inset, read by both the title and the card's contents.
    ///
    /// The title names what is inside the card, so it belongs on the
    /// same vertical line. It used to sit at 4 while the rows sat at
    /// 12, which puts two competing left margins down a column of
    /// stacked settings groups and makes each card read as a detached
    /// box rather than the body of the thing above it. Held as one
    /// value so the two cannot drift apart again.
    private static var inset: CGFloat { Theme.Space.l }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: title)
                .padding(.leading, Self.inset)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                content
            }
            .padding(Self.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chalantCard()
        }
    }
}

/// Label on the left, control on the right.
struct SettingRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.l)
            control
        }
    }
}

struct SettingToggle: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.chalantAccent) private var accent

    var body: some View {
        SettingRow(label: label) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(accent)
                // The switch alone is the control; the row's text is its
                // name, and without this a screen reader announces an
                // unlabelled switch.
                .accessibilityLabel(label)
        }
    }
}

/// Segmented choice. Small option sets only — anything longer wants the
/// menu picker, which is why the reminder-list and microphone rows build
/// their own.
struct SettingPicker<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var width: CGFloat = 190

    var body: some View {
        SettingRow(label: label) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: width)
            .accessibilityLabel(label)
        }
    }
}

/// The sentence under a row that says what it actually does.
struct SettingNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.textHint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairlineFaint)
            .frame(height: 1)
    }
}

/// One accent choice: a swatch that lifts on hover and rings when
/// selected.
struct SettingsSwatch: View {
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
        // Colour alone cannot carry which one is chosen.
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
