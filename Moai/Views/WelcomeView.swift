import SwiftUI

/// The first hello: three quiet steps inside the island itself. No
/// separate window, no permission wall; macOS asks for things as they
/// are first used, and the tour just says so.
struct WelcomeView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.moaiAccent) private var accent

    private let steps = 4
    /// The permissions page's one-tap state.
    @State private var primed = false
    @State private var priming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            controls
        }
        .frame(height: 250)
        .onExitCommand { model.finishWelcome() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.welcomeStep {
        case 0:
            step(
                title: "I live up here.",
                lines: [
                    ("cursorarrow.motionlines", "Glide to the top of the screen and I open."),
                    ("mic.fill", "Tap the mic and talk, or just type in the bar."),
                    ("bolt.fill", "The verbs run on this Mac, keyless and instant."),
                ]
            )
        case 1:
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Say it.")
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.textPrimary)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    verb("remind me to call amma at 6")
                    verb("text amma: on my way")
                    verb("focus 25")
                    verb("left half")
                    verb("summarize my screen")
                    verb("find parcel")
                }
                Text("Recognition is Apple's standard dictation, the same path Notes and Messages use. Your music ducks while you speak.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case 2:
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Say yes once.")
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("The island uses the mic and speech for talking, Reminders and Calendar for your day, and Contacts for the texts you send. One tap asks for all five now, instead of ambushing you one feature at a time. When music first plays or a text first sends, macOS asks once more; that yes is for the app doing the work.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    guard !priming, !primed else { return }
                    priming = true
                    Task {
                        await PermissionPrimer.primeAll()
                        priming = false
                        primed = true
                    }
                } label: {
                    Text(primed
                        ? "Asked. Anything denied lives in System Settings."
                        : priming ? "Asking…" : "Allow mic, speech, reminders, calendar, contacts")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(primed ? Theme.textSecondary : .black)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s)
                        .background(
                            Capsule().fill(primed ? Theme.hairlineFaint : accent)
                        )
                }
                .buttonStyle(PressableStyle())
                Text("Windows snapping asks for Accessibility separately, the first time you say left half.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            step(
                title: "The rest finds you.",
                lines: [
                    ("tray.and.arrow.down.fill", "Drag any file or screenshot upward; a bubble meets it halfway."),
                    ("doc.on.doc", "Copies land in Clips, files on the Shelf, thoughts in Notes."),
                    ("calendar", "Your day stays private until you switch Calendar on in Settings."),
                ]
            )
        }
    }

    private func step(
        title: String,
        lines: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.textPrimary)
            ForEach(lines, id: \.1) { symbol, text in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Image(systemName: symbol)
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(accent)
                        .frame(width: 18)
                    Text(text)
                        .font(Theme.Fonts.reading)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func verb(_ text: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("\u{201C}\(text)\u{201D}")
                .font(Theme.Fonts.bodyMono)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.snug) {
                ForEach(0..<steps, id: \.self) { index in
                    Circle()
                        .fill(
                            index == model.welcomeStep
                                ? AnyShapeStyle(accent)
                                : AnyShapeStyle(Color.white.opacity(0.15))
                        )
                        .frame(width: 5, height: 5)
                }
            }
            Spacer()
            if model.welcomeStep < steps - 1 {
                Button("Skip") { model.finishWelcome() }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Button {
                if model.welcomeStep < steps - 1 {
                    withAnimation(Theme.Motion.content) { model.welcomeStep += 1 }
                } else {
                    model.finishWelcome()
                }
            } label: {
                Text(model.welcomeStep < steps - 1 ? "Next" : "Begin")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, Theme.Space.l)
                    .frame(minHeight: 26)
                    .background(Capsule().fill(Theme.textPrimary))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
    }
}
