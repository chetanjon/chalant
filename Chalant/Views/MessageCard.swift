import SwiftUI

/// The message that just arrived, and the reply being written into it.
///
/// Reads top down the way the moment does: who wrote, what they said,
/// then one reply field. Talking fills the field, typing fills the
/// field, and Send or Return sends exactly what it shows. It is the
/// session composer's idiom (field, mic, a send arrow that exists only
/// once there are words) because that is the shape every chat app has
/// already taught, and nothing here should need learning.
///
/// Laws kept: no pills behind anything merely selected (law 1), air
/// rather than dividers (law 2), and a control appears only when it can
/// do something (law 5). That last one is load bearing: the reply
/// controls exist only when Contacts has placed the sender, the mic only
/// when dictation is running, the send arrow only with words to send.
/// The first build showed a talk button that said "Listening." while
/// nothing listened.
struct MessageCard: View {
    @ObservedObject var reply: MessageReply
    /// The live mic level while the card hosts a hold, 0...1.
    var level: CGFloat
    /// Whether dictation can run at all right now.
    var canTalk: Bool
    var talkPress: () -> Void
    var talkRelease: (_ held: Bool) -> Void
    var send: () -> Void
    var openInMessages: () -> Void
    var dismiss: () -> Void

    @Environment(\.chalantAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var pressedAt: Date?

    /// Shorter than this and the press was a click, not a hold. Long
    /// enough that a deliberate tap never starts a recording, short
    /// enough that nobody waits to be heard.
    private static let holdThreshold: TimeInterval = 0.25

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let sighting = reply.sighting {
                header(sighting)
                Text(sighting.body)
                    .font(Theme.Fonts.reading)
                    .foregroundStyle(Theme.textPrimary)
                    // A long text must not make the island as tall as
                    // the message and push the reply off the screen. The
                    // whole of it is one press away, in Messages.
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            answer
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { reply.hover($0) }
        // Escape leaves, once the card has the keyboard. It never takes
        // the keyboard by itself, so this cannot steal a keystroke from
        // whatever the person was typing in when the message arrived.
        .onExitCommand(perform: dismiss)
        .onChange(of: fieldFocused) { _, focused in
            if focused { reply.touch() }
        }
        .onChange(of: reply.phase) { _, phase in announce(phase) }
        .animation(reduceMotion ? nil : Theme.Motion.content, value: reply.phase)
        .animation(reduceMotion ? nil : Theme.Motion.content, value: reply.recipient)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message from \(reply.sighting?.sender ?? "")")
    }

    // MARK: - Who and what

    private func header(_ sighting: MessageWatch.Sighting) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            // Says "this is a text message" before a word is read.
            Image(systemName: "message.fill")
                .font(Theme.Fonts.icon(.s))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(sighting.sender)
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.m)
            HoverGlyphButton(
                symbol: "arrow.up.forward.app", label: "Open in Messages",
                scale: .s, action: openInMessages
            )
            HoverGlyphButton(symbol: "xmark", label: "Dismiss", scale: .s, action: dismiss)
                // Live during a send, it would read as "cancel" and
                // cannot be one: the message is already with Messages.
                .disabled(reply.phase == .sending)
                .opacity(reply.phase == .sending ? 0.3 : 1)
        }
    }

    // MARK: - The reply

    @ViewBuilder
    private var answer: some View {
        if case .sent(let name) = reply.phase {
            Label("Sent to \(name)", systemImage: "checkmark.circle.fill")
                .font(Theme.Fonts.subhead)
                .foregroundStyle(accent)
                .transition(.opacity)
        } else {
            switch reply.recipient {
            case .checking:
                // Contacts answers in a blink. Showing a spinner for it
                // would be louder than the wait.
                EmptyView()
            case .known(let name, _):
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    field(for: name)
                    caption(for: name)
                }
            case .cannotReply(let why):
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(why)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: openInMessages) {
                        Text("Open in Messages")
                            .font(Theme.Fonts.subhead)
                            .foregroundStyle(.black)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.s)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private func field(for name: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            TextField(placeholder(for: name), text: $reply.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .lineLimit(1...4)
                .focused($fieldFocused)
                .onSubmit(send)
                .disabled(reply.phase == .sending || reply.phase == .listening)
                .accessibilityLabel("Reply to \(name)")
            if canTalk { mic }
            if reply.canSend {
                HoverGlyphButton(
                    symbol: "arrow.up.circle.fill", label: "Send to \(name)",
                    scale: .m, tint: accent, action: send
                )
                .transition(.opacity)
            }
        }
        .padding(Theme.Space.m)
        .chalantField(active: fieldFocused || reply.phase == .listening)
    }

    private func placeholder(for name: String) -> String {
        switch reply.phase {
        case .listening: return "Listening"
        case .hearing: return "Writing that down"
        default: return "Reply to \(first(of: name))"
        }
    }

    /// Press and hold to talk. The gesture measures its own length so a
    /// click can be told from a hold: a click starts nothing, and the
    /// card says so rather than silently doing nothing.
    private var mic: some View {
        let listening = reply.phase == .listening
        return Image(systemName: listening ? "mic.fill" : "mic")
            .font(Theme.Fonts.icon(.m))
            .foregroundStyle(listening ? accent : Theme.textSecondary)
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(accent.opacity(listening ? 0.18 : 0))
                    // The ring breathes with the voice, so holding it
                    // feels heard rather than merely pressed.
                    .scaleEffect(listening && !reduceMotion ? 1 + level * 0.9 : 1)
                    .animation(reduceMotion ? nil : Theme.Motion.hover, value: level)
            )
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressedAt == nil else { return }
                        pressedAt = Date()
                        talkPress()
                    }
                    .onEnded { _ in
                        guard let began = pressedAt else { return }
                        pressedAt = nil
                        talkRelease(Date().timeIntervalSince(began) >= Self.holdThreshold)
                    }
            )
            .help("Hold to talk")
            .accessibilityElement()
            .accessibilityLabel("Hold to talk your reply")
            .accessibilityHint("Your words appear in the reply field. Nothing is sent until you press Send.")
            .accessibilityAddTraits(.isButton)
            // The card going away mid-hold must never leave the mic hot.
            .onDisappear {
                guard pressedAt != nil else { return }
                pressedAt = nil
                talkRelease(false)
            }
    }

    /// One quiet line that always says the thing most worth knowing
    /// right now. It used to open with "Let go" before anyone had
    /// pressed anything, and go blank while they talked.
    private func caption(for name: String) -> some View {
        let line: String
        var tone = Theme.textTertiary
        switch reply.phase {
        case .listening:
            line = "Listening. Let go when you are done."
        case .hearing:
            line = "Got it. Writing that down."
        case .sending:
            line = "Sending to \(name)."
        case .failed(let why):
            line = why
            tone = Theme.textSecondary
        case .idle, .sent:
            if let hint = reply.hint {
                line = hint
                tone = Theme.textSecondary
            } else if reply.canSend {
                line = "Not sent yet. Press Return or the arrow to send it to \(name)."
            } else if canTalk {
                line = "Type a reply, or hold the mic and talk."
            } else {
                line = "Type a reply and press Return."
            }
        }
        return Text(line)
            .font(Theme.Fonts.caption)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Reply to Sam", not "Reply to Sam Ali". A sender who is a number
    /// or an address has no first name, and splitting one on its spaces
    /// produced "Reply to +1".
    private func first(of name: String) -> String {
        guard MessageCourier.literalHandle(name) == nil else { return name }
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    /// State changes said aloud for anyone not looking at the card.
    private func announce(_ phase: MessageReply.Phase) {
        let words: String?
        switch phase {
        case .listening: words = "Listening"
        case .hearing: words = "Writing that down"
        case .sending: words = "Sending"
        case .sent(let name): words = "Sent to \(name)"
        case .failed(let why): words = why
        case .idle: words = reply.draft.isEmpty ? nil : "Reply ready. Not sent yet."
        }
        guard let words else { return }
        AccessibilityNotification.Announcement(words).post()
    }
}
