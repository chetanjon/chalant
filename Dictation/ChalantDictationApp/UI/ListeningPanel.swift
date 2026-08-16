import AppKit

/// The thing that tells you it is listening.
///
/// **Scope note:** Part 3 says M0 has "no UI beyond a menu bar item". This
/// widens that, at the founder's request, and it earns the exception: without
/// any feedback there is no way to tell "the app never heard me" from "the app
/// heard me and the paste failed", which makes M0's own acceptance test
/// guesswork. The fed-buffer count already caught one silent-microphone run
/// that looked identical to a broken engine.
///
/// It shows two things, both of which answer a question a menu bar dot cannot:
/// a level meter, which proves the microphone is live rather than delivering
/// silence, and the words as they are recognised, which is the thing that
/// makes dictation feel responsive rather than suspenseful.
///
/// It hangs just under the notch because that is where this ends up living
/// once it moves into Chalant's island.
@MainActor
final class ListeningPanel {
    private var panel: NSPanel?
    private var levelLayer: CALayer?
    private var textField: NSTextField?

    private static let size = CGSize(width: 420, height: 64)

    func show() {
        let panel = ensurePanel()
        guard let screen = NSScreen.main else { return }

        // Under the notch, horizontally centred.
        let origin = NSPoint(
            x: screen.frame.midX - Self.size.width / 2,
            y: screen.frame.maxY - Self.size.height - 12
        )
        panel.setFrameOrigin(origin)
        textField?.stringValue = ""
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    /// Called on a display timer while the key is held.
    func update(level: Double, text: String) {
        // A little headroom so ordinary speech fills most of the bar rather
        // than a sliver: raw peak on a built-in mic rarely passes 0.3.
        let scaled = min(1, level * 3.2)
        levelLayer?.frame.size.width = max(2, Self.size.width * scaled)

        if let field = textField {
            field.stringValue = text.isEmpty ? "Listening…" : text
            field.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor

        // The level meter: a single bar across the bottom edge. One symbol per
        // meaning, and nothing that pretends to be a waveform it is not.
        let level = CALayer()
        level.frame = CGRect(x: 0, y: 0, width: 2, height: 3)
        level.backgroundColor = NSColor.systemBlue.cgColor
        content.layer?.addSublayer(level)
        self.levelLayer = level

        let field = NSTextField(labelWithString: "Listening…")
        field.frame = NSRect(x: 18, y: 18, width: Self.size.width - 36, height: 28)
        field.font = .systemFont(ofSize: 15, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingHead
        field.maximumNumberOfLines = 1
        content.addSubview(field)
        self.textField = field

        panel.contentView = content
        self.panel = panel
        return panel
    }
}
