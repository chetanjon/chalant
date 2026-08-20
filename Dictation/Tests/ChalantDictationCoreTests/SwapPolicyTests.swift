import XCTest
@testable import ChalantDictationCore

/// The seven conditions for replacing just-inserted text with its tidied
/// version (spec 2026-08-17, "Instant, then tidied in place"). Each test
/// removes one condition and expects a keep with that reason; the first proves
/// the happy path swaps.
final class SwapPolicyTests: XCTestCase {

    private func situation(
        inserted: String = "so um I think we should move the review to thursday",
        tidied: String = "So I think we should move the review to Thursday.",
        outcome: InsertionOutcome = .inserted(tier: .systemEvents),
        userActed: Bool = false,
        frontStillTarget: Bool = true,
        elapsed: TimeInterval = 1.1,
        bundleID: String? = "com.tinyspeck.slackmacgap"
    ) -> SwapPolicy.Situation {
        SwapPolicy.Situation(
            inserted: inserted, tidied: tidied, outcome: outcome, userActedSinceInsert: userActed,
            frontIsStillTarget: frontStillTarget, secondsSinceInsert: elapsed, bundleID: bundleID)
    }

    func testAllConditionsMetMeansSwap() {
        XCTAssertEqual(SwapPolicy.decide(situation()), .swap)
    }

    func testUnchangedTextIsKept() {
        let same = "So I think we should move the review to Thursday."
        XCTAssertEqual(SwapPolicy.decide(situation(inserted: same, tidied: same)), .keep(.unchanged))
        // Whitespace at the ends is not a change worth undoing a paste for.
        XCTAssertEqual(SwapPolicy.decide(situation(inserted: same, tidied: " \(same)\n")), .keep(.unchanged))
    }

    func testEmptyTidiedIsKept() {
        XCTAssertEqual(SwapPolicy.decide(situation(tidied: "   ")), .keep(.unchanged))
    }

    func testOnlyAPasteCanBeUndone() {
        XCTAssertEqual(SwapPolicy.decide(situation(outcome: .inserted(tier: .cgEvent))), .swap)
        XCTAssertEqual(SwapPolicy.decide(situation(outcome: .leftOnClipboard(reason: "x"))), .keep(.notPasted))
        XCTAssertEqual(SwapPolicy.decide(situation(outcome: .refused(reason: .noTarget))), .keep(.notPasted))
    }

    func testTypingOrClickingSinceTheInsertKeepsTheText() {
        XCTAssertEqual(SwapPolicy.decide(situation(userActed: true)), .keep(.userActed))
    }

    func testFocusMovedKeepsTheText() {
        XCTAssertEqual(SwapPolicy.decide(situation(frontStillTarget: false)), .keep(.focusMoved))
    }

    func testTooLateKeepsTheText() {
        XCTAssertEqual(SwapPolicy.decide(situation(elapsed: 3.9)), .swap)
        XCTAssertEqual(SwapPolicy.decide(situation(elapsed: 4.1)), .keep(.tooLate))
    }

    /// The better ear needs ~1.2 s to hear plus the tidy, so it may arrive
    /// later than the tidy alone and still be welcome; not indefinitely.
    func testTheBetterEarGetsALongerCeiling() {
        var s = situation(elapsed: 5.5); s.source = .hearing
        XCTAssertEqual(SwapPolicy.decide(s), .swap)
        s.secondsSinceInsert = 6.5
        XCTAssertEqual(SwapPolicy.decide(s), .keep(.tooLate))
        XCTAssertEqual(SwapPolicy.maximumDelay(for: .tidy), 4)
        XCTAssertEqual(SwapPolicy.maximumDelay(for: .hearing), 6)
    }

    /// The hearing ceiling earns time with the utterance: Whisper needs
    /// ~6.3 s for 70 s of audio (measured 2026-08-20), and a flat 6 s
    /// excluded exactly the long paragraphs the first ear is worst at. The
    /// tidy's ceiling never moves, and the cap holds however long they spoke.
    func testALongUtteranceEarnsTheEarMoreTime() {
        var s = situation(elapsed: 12); s.source = .hearing; s.utteranceSeconds = 70
        XCTAssertEqual(SwapPolicy.decide(s), .swap)
        s.utteranceSeconds = 5
        XCTAssertEqual(SwapPolicy.decide(s), .keep(.tooLate))
        XCTAssertEqual(SwapPolicy.maximumDelay(for: .hearing, utteranceSeconds: 70), 16.5)
        XCTAssertEqual(SwapPolicy.maximumDelay(for: .hearing, utteranceSeconds: 500), 20)
        XCTAssertEqual(SwapPolicy.maximumDelay(for: .tidy, utteranceSeconds: 500), 4)
        s.source = .tidy; s.utteranceSeconds = 500
        XCTAssertEqual(SwapPolicy.decide(s), .keep(.tooLate))
    }

    /// ⌘Z is not undo in a terminal, and a second paste would double the text.
    func testTerminalsNeverSwap() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm"] {
            XCTAssertEqual(SwapPolicy.decide(situation(bundleID: id)), .keep(.noUndoHere), id)
        }
        XCTAssertEqual(SwapPolicy.decide(situation(bundleID: nil)), .keep(.noUndoHere))
    }

    /// Editors with a terminal inside them: Electron cannot tell us which
    /// pane has focus, and a second paste into the terminal doubles the text.
    func testEditorsThatCarryATerminalNeverSwap() {
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed"] {
            XCTAssertEqual(SwapPolicy.decide(situation(bundleID: id)), .keep(.noUndoHere), id)
        }
        // Where the swap is for: browsers, Slack, Notes, Mail.
        for id in ["ai.perplexity.comet", "com.google.Chrome", "com.tinyspeck.slackmacgap", "com.apple.Notes", "com.apple.mail"] {
            XCTAssertEqual(SwapPolicy.decide(situation(bundleID: id)), .swap, id)
        }
    }

    /// The reasons read as one word each in the log, never content.
    func testKeepReasonsAreLoggableWords() {
        for reason in SwapPolicy.KeepReason.allCases {
            XCTAssertFalse(reason.rawValue.contains(" "), reason.rawValue)
        }
    }
}
