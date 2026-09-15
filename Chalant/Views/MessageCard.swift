import SwiftUI

/// The message that just arrived, and the reply being spoken into it.
///
/// Reads top down the way the moment does: who wrote, what they said,
/// then the one thing to do about it. No pills behind anything that is
/// merely selected (law 1), no dividers (law 2), and the send button
/// exists only once there are words to send (law 5).
///
/// The reply button holds dictation itself rather than letting a plain
/// Option hold reach the card. That is deliberate: a text arriving
/// while somebody dictates into their editor must never turn the next
/// sentence into an outgoing message.
struct MessageCard: View {
    @ObservedObject var reply: MessageReply
    @Environment(\.chalantAccent) private var accent

    /// Press and hold these to talk: the same two calls the Option key
    /// makes, so a refused Input Monitoring cannot make the card
    /// silently do nothing.
    var press: () -> Void
    var release: () -> Void
    var send: () -> Void
    var dismiss: () -> Void

    @State private var talking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let sighting = reply.sighting {
                header(sighting)
                Text(sighting.body)
                    .font(Theme.Fonts.reading)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            stage
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ sighting: MessageWatch.Sighting) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(sighting.sender)
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(Theme.Fonts.icon(.s))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch reply.stage {
        case .waiting:
            HStack(spacing: Theme.Space.m) {
                talkButton
                Text(talking ? "" : "Let go and Chalant shows you the words before anything sends.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .drafted(let words):
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(words)
                    .font(Theme.Fonts.reading)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(
                        RoundedRectangle(
                            cornerRadius: Theme.Radius.artwork, style: .continuous
                        )
                        .strokeBorder(accent.opacity(0.30), lineWidth: 1)
                    )
                HStack(spacing: Theme.Space.m) {
                    Button(action: send) {
                        Text("Send")
                            .font(Theme.Fonts.subhead)
                            .foregroundStyle(.black)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.s)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(PressableStyle())
                    talkButton
                }
            }
        case .sending:
            Text("Sending.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
        case .sent:
            Text("Sent.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(accent)
        case .refused(let why):
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(why)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                talkButton
            }
        }
    }

    /// Press and hold to talk, the same gesture the tour's try-it card
    /// uses, so one muscle memory covers both.
    private var talkButton: some View {
        Text(talking ? "Listening. Let go when done." : replyLabel)
            .font(Theme.Fonts.subhead)
            .foregroundStyle(talking ? .black : Theme.textPrimary)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .background(Capsule().fill(talking ? accent : Theme.hairlineFaint))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !talking else { return }
                        talking = true
                        press()
                    }
                    .onEnded { _ in
                        guard talking else { return }
                        talking = false
                        release()
                    }
            )
    }

    private var replyLabel: String {
        if case .drafted = reply.stage { return "Say it again" }
        if case .refused = reply.stage { return "Try again" }
        return "Press and hold to reply"
    }
}
