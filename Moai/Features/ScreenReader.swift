import AppKit
import ScreenCaptureKit
import Vision

/// Reads the frontmost window into words, on this Mac only: one
/// ScreenCaptureKit shot, one Vision pass, and the text joins the
/// ask pipeline like any dropped file. Nothing is stored and nothing
/// leaves the machine; the capture lives exactly as long as the OCR.
enum ScreenReader {
    enum Outcome {
        case text(app: String, words: String)
        case empty(app: String)
        case noWindow
        case denied
        case needsGrant
        /// Permission is fine; the capture or the OCR itself failed.
        /// Saying "check System Settings" over a transient flake sent
        /// people to fix what was not broken (review-caught).
        case failed
    }

    /// The Screen Recording dialog must never be awaited: ask without
    /// waiting and say plainly what to do next (the R94 wedge rule).
    /// macOS applies this grant on the app's NEXT launch more often
    /// than not; the copy says it again rather than promising magic.
    static func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestGrant() {
        CGRequestScreenCaptureAccess()
    }

    static func readFrontWindow() async -> Outcome {
        guard preflight() else { return .needsGrant }
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return .failed }

        // The frontmost app's largest on-screen window; Moai itself
        // never counts, the island is not a document. When Moai IS
        // the frontmost app (the shortcut picker activates it, and
        // the user is mid-conversation with the bar), the front
        // filter must yield or no window can ever qualify (review-
        // caught: the two conditions were mutually unsatisfiable);
        // the biggest visible window is then the honest guess.
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let selfBundle = Bundle.main.bundleIdentifier
        let visible = content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            guard app.bundleIdentifier != selfBundle else { return false }
            return window.isOnScreen && window.frame.width > 200
                && window.frame.height > 150
        }
        let candidates: [SCWindow]
        if let front = frontBundle, front != selfBundle {
            candidates = visible.filter {
                $0.owningApplication?.bundleIdentifier == front
            }
        } else {
            candidates = visible
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { return .noWindow }

        let appName = window.owningApplication?.applicationName ?? "the front app"

        // Scale comes from the content filter, not a guessed 2x: a
        // 1x monitor deserves a 1x capture (computed-not-guessed,
        // the chin's own doctrine).
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        ) else { return .failed }

        guard let words = await recognize(image) else { return .failed }
        guard !words.isEmpty else { return .empty(app: appName) }
        return .text(app: appName, words: words)
    }

    /// nil = Vision itself failed (distinct from a wordless window;
    /// telling someone their document has no text over an OCR error
    /// was a lie, review-caught).
    private static func recognize(_ image: CGImage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let lines = request.results?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}
