import XCTest

@testable import Chalant

/// The dark-ship (founder, 2026-08-09): sessions and chat are hidden,
/// not removed. Engines, views and tests all stay; two booleans in
/// `FeatureFlags` bring the features back whole. These tests pin the
/// hidden state so no door leaks back without a deliberate flip.
@MainActor
final class FeatureFlagsTests: XCTestCase {

    /// Even with its settings switch on, a dark-shipped sessions tab is
    /// not somewhere the island may open onto.
    func testAHiddenSessionsTabIsNeverAvailable() {
        let defaults = Self.emptyDefaults()
        defaults.set(true, forKey: "toolSessions")
        XCTAssertFalse(NotchViewModel.isAvailable(.sessions, in: defaults))
    }

    /// Same law for the chat tab.
    func testAHiddenChatTabIsNeverAvailable() {
        let defaults = Self.emptyDefaults()
        defaults.set(true, forKey: "toolChat")
        XCTAssertFalse(NotchViewModel.isAvailable(.chat, in: defaults))
    }

    /// With every visible tool switched off, the front door falls back
    /// to Today rather than a hidden surface: a dark-shipped tab must
    /// never be the answer to "where does the island open".
    func testTheIslandNeverLandsOnAHiddenTab() {
        let defaults = Self.emptyDefaults()
        for tab in NotchViewModel.Tab.allCases
        where tab != .sessions && tab != .chat {
            if let key = tab.toolKey { defaults.set(false, forKey: key) }
        }
        XCTAssertEqual(NotchViewModel.landingTab(todayCanSee: false, in: defaults), .today)
    }

    /// A dark-shipped surface keeps no doors: its global hotkey is
    /// never registered and its shortcut row is never drawn.
    func testHiddenSurfacesKeepNoHotkeys() {
        XCTAssertFalse(HotKeyCenter.Action.sessions.isVisible)
        XCTAssertFalse(HotKeyCenter.Action.chat.isVisible)
        XCTAssertTrue(HotKeyCenter.Action.clipboard.isVisible)
    }

    /// The settings sidebar keeps no Sessions entry while dark-shipped,
    /// and the debug harness cannot steer to one by name either.
    func testTheSettingsSidebarKeepsNoHiddenSection() {
        XCTAssertFalse(DashboardSection.visibleCases.contains(.sessions))
        XCTAssertTrue(DashboardSection.visibleCases.contains(.general))
        XCTAssertNil(DashboardSection.named("sessions"))
    }

    /// The shipped state, pinned. Bringing a feature back is a
    /// deliberate act: flip the flag in FeatureFlags.swift and update
    /// this test in the same change, never by accident.
    func testTheDarkShipIsOn() {
        XCTAssertFalse(FeatureFlags.sessionsVisible)
        XCTAssertFalse(FeatureFlags.chatVisible)
    }

    /// While dark-shipped the store surfaces no cards, so every hold is
    /// refused on arrival and the server answers with silence at once:
    /// an upgrading user whose hooks are still armed gets their agent's
    /// own terminal prompt immediately, never a ten-minute wait on a
    /// card that cannot be drawn. The default stays true so the gate
    /// engine keeps its full test coverage; the app wires the flag in.
    func testADarkShippedStoreRefusesEveryHold() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant.tests.flags.\(UUID().uuidString)")
        let store = SessionStore(outboxDirectory: dir)
        store.surfacesCards = false
        XCTAssertFalse(store.holdForPrompt(
            sessionID: "s", id: "p1", tool: "Bash", detail: "rm -rf /tmp/x", patience: 5))
        XCTAssertFalse(store.holdForApproval(
            sessionID: "s", id: "a1", tool: "Bash", detail: "sudo ls", rules: ["Bash"]))
        XCTAssertFalse(store.holdForElicitation(
            sessionID: "s", askID: "q1",
            questions: [SessionStore.Ask.Question(
                header: "", question: "One?", options: ["a"], multiSelect: false, field: "f")],
            cwd: nil, server: "mcp"))
        XCTAssertTrue(store.sessions.isEmpty, "a refused hold invents no row")
    }

    private static func emptyDefaults() -> UserDefaults {
        let suite = "chalant.tests.featureflags.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
