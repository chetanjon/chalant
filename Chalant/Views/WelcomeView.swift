import SwiftUI

/// The first hello: a few quiet steps inside the island itself. No
/// separate window, no permission wall; macOS asks for things as they
/// are first used, and the tour just says so.
///
/// Five steps where dictation exists (macOS 26), four where it does not:
/// law 5, a card appears only when it can do something, and a card that
/// says "hold Option" on a Mac that cannot is a promise the build cannot
/// keep.
struct WelcomeView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.chalantAccent) private var accent

    /// How many cards this Mac gets. Read by the tour's own controls and by
    /// the "debug welcome <n>" hook, so the two can never disagree.
    @MainActor static var stepCount: Int { Dictation.isSupported ? 6 : 4 }
    private var steps: Int { Self.stepCount }
    /// The permissions page's one-tap state.
    @State private var primed = false
    @State private var priming = false
    /// The dictation page's switch, read once when the card appears so an
    /// install that already turned it on says so instead of asking again.
    @State private var dictating = Dictation.isEnabled()
    /// The first sentence anyone dictates, landed in the card itself.
    @State private var practiceHeard: String?
    /// Whether the card's own press-and-hold button is down.
    @State private var practising = false
    /// The role card's selection, read once so a replayed tour shows the
    /// standing answer instead of forgetting it.
    @State private var chosenRole = ChalantRole.current

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            controls
        }
        .frame(height: 250)
        .onExitCommand { model.finishWelcome() }
    }

    /// The page index of each card, so inserting cards on the Macs that
    /// have them does not renumber the rest by hand. The role question
    /// leads on Macs that can dictate: it is the choice everything after
    /// it reads (one app, two faces; founder, 2026-08-20).
    /// **Dictation moved to second on 2026-08-30**, behind the role
    /// question and ahead of everything else. The founder, dictating:
    /// "the onboarding should be easy and they should be able to use voice
    /// dictation immediately without any issues." It used to be the FOURTH
    /// card, so someone who downloaded a dictation app met the wordmark and
    /// the island's verbs first. The role question keeps the lead it was
    /// given on 2026-08-20: it is one tap, and everything after it reads
    /// the answer.
    private var roleStep: Int? { Dictation.isSupported ? 0 : nil }
    private var dictationStep: Int? { Dictation.isSupported ? 1 : nil }
    private var introStep: Int { Dictation.isSupported ? 2 : 0 }
    private var sayItStep: Int { Dictation.isSupported ? 3 : 1 }
    private var permissionsStep: Int { Dictation.isSupported ? 4 : 2 }

    @ViewBuilder
    private var content: some View {
        switch model.welcomeStep {
        case roleStep:
            roleCard
        case introStep:
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ChalantWordmark()
                    .frame(width: 104, height: 22)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityLabel("Chalant")
                step(
                    title: "I live up here.",
                    lines: [
                        ("cursorarrow.motionlines", "Glide to the top of the screen and I open."),
                        // Read off VoiceDoor, never written here: this
                        // line spent 1.12.x telling every new user to
                        // tap a mic the build had stopped drawing.
                        ("mic.fill", VoiceDoor.welcomeLine),
                        ("bolt.fill", "The verbs run on this Mac, keyless and instant."),
                    ]
                )
            }
        case sayItStep:
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Say it.")
                    .font(Theme.Fonts.headline)
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
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case dictationStep:
            dictationCard
        case permissionsStep:
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Say yes once.")
                    .font(Theme.Fonts.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("The island uses the mic and speech for talking, Reminders and Calendar for your day, and Contacts for the texts you send. One tap asks for all five now, instead of ambushing you one feature at a time. When music first plays or a text first sends, macOS asks once more; that yes is for the app doing the work.")
                    .font(Theme.Fonts.subhead)
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
                        .font(Theme.Fonts.subhead)
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
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            step(
                title: "The rest finds you.",
                lines: [
                    ("tray.and.arrow.down.fill", "Drag any file or screenshot upward; a bubble meets it halfway."),
                    ("doc.on.doc", "Copies land in Clips, files on the Shelf, thoughts in Notes."),
                    ("calendar", "Your day shows once macOS says yes to Calendar, and it never leaves this Mac."),
                ]
            )
        }
    }

    /// The first question, on the Macs that can dictate: what is Chalant
    /// here? Choosing only selects; the arrows still advance, and Settings
    /// can change the answer any day. "Just dictation" hides the island
    /// everywhere and keeps only the strip and its moments.
    private var roleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("What should Chalant be?")
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                roleChoice(
                    .both, "Both",
                    "The island up top, and hold Option to dictate anywhere.")
                roleChoice(
                    .dictation, "Just dictation",
                    "No island. A small strip appears only while you talk.")
                roleChoice(
                    .island, "The island",
                    "The island and its verbs; dictation stays off.")
            }
            Text("You can change this any time in Settings.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func roleChoice(_ role: ChalantRole, _ title: String, _ detail: String) -> some View {
        Button {
            ChalantRole.set(role)
            chosenRole = role
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Image(systemName: chosenRole == role ? "circle.inset.filled" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(chosenRole == role ? accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Fonts.subhead)
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    /// The second door, in its own card because the first card is about
    /// talking TO the island and this is about talking THROUGH it, into
    /// whatever you were typing. The gesture line is read off `VoiceDoor`,
    /// never written here, so the tour and Settings can never describe two
    /// different keys. The button is the same consent the Settings switch
    /// is: turning it on is what raises the Input Monitoring and
    /// Accessibility asks, so nothing is asked of a Mac that only wanted
    /// the island.
    private var dictationCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(practiceHeard == nil ? "Hold Option and talk." : "That is dictation.")
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.textPrimary)

            // The landing spot. A first hold with nothing focused to receive
            // text is a silence indistinguishable from a broken build, so
            // the card holds the spot itself and the words appear here.
            practiceField

            if let heard = practiceHeard, !heard.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Image(systemName: "checkmark")
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(accent)
                        .frame(width: 18)
                    Text("Heard on this Mac. Nothing was uploaded, and nothing was typed anywhere else yet.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if dictating {
                HStack(spacing: Theme.Space.m) {
                    practiceButton
                    Text(VoiceDoor.dictationLine(available: true) ?? "")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    guard !dictating else { return }
                    Dictation.setEnabled(true)
                    Dictation.shared.start()
                    Dictation.shared.holdPracticeLanding { text in
                        practiceHeard = text
                    }
                    dictating = true
                } label: {
                    Text("Turn on and try it")
                        .font(Theme.Fonts.subhead)
                        .foregroundStyle(.black)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(PressableStyle())
                Text("Only the microphone for now. Letting Chalant type into your other apps is the next card.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if dictating {
                Dictation.shared.holdPracticeLanding { text in practiceHeard = text }
            }
        }
        .onDisappear {
            // The spot is the card's, never the app's: leaving hands
            // dictation back to whatever the user is really typing into.
            Dictation.shared.holdPracticeLanding(nil)
        }
    }

    /// Where a practice sentence lands. Dashed while it waits, solid once
    /// something is in it: law 2, air and a line's own weight rather than a
    /// box that shouts.
    private var practiceField: some View {
        Text(practiceHeard ?? "Say anything. Your words appear right here.")
            .font(Theme.Fonts.reading)
            .foregroundStyle(practiceHeard == nil ? Theme.textGhost : Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
            .padding(Theme.Space.l)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous)
                    .strokeBorder(
                        practiceHeard == nil ? Theme.hairlineFaint : accent.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1, dash: practiceHeard == nil ? [4, 4] : [])
                    )
            )
    }

    /// The button half of the try-it card, and the reason it exists: the
    /// event tap can install and still receive nothing when Input
    /// Monitoring was refused, which is a silent nothing at the worst
    /// possible moment. A press-and-hold that calls the same two entry
    /// points the tap does cannot fail that way.
    private var practiceButton: some View {
        Text(practising ? "Listening. Let go when done." : "Press and hold to talk")
            .font(Theme.Fonts.subhead)
            .foregroundStyle(practising ? .black : Theme.textPrimary)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .background(Capsule().fill(practising ? accent : Theme.hairlineFaint))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !practising else { return }
                        practising = true
                        Dictation.shared.practicePress()
                    }
                    .onEnded { _ in
                        guard practising else { return }
                        practising = false
                        Dictation.shared.practiceRelease()
                    }
            )
    }

    private func step(
        title: String,
        lines: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title)
                .font(Theme.Fonts.headline)
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
