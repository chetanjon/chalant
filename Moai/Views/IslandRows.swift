import SwiftUI

/// The music row: artwork, title, scrub with real timestamps, full
/// transport, and volume — everything in one 44pt line of control.
struct MusicRow: View {
    @ObservedObject var music: MusicController
    @Environment(\.moaiAccent) private var accent
    @State private var scrubPosition: Double?
    @State private var volumeDraft: Double?

    var body: some View {
        if let playing = music.nowPlaying {
            HStack(spacing: Theme.Space.l) {
                artworkView

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.s) {
                        Text(playing.track)
                            .font(Theme.Fonts.bodyEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(playing.artist)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: Theme.Space.m) {
                        Text(Self.clock(scrubPosition ?? playing.position))
                            .font(Theme.Fonts.microMono)
                            .foregroundStyle(Theme.textTertiary)
                        Slider(
                            value: Binding(
                                get: { scrubPosition ?? playing.position },
                                set: { scrubPosition = $0 }
                            ),
                            in: 0...max(playing.duration, 1),
                            onEditingChanged: { editing in
                                if !editing, let target = scrubPosition {
                                    music.seek(to: target)
                                    scrubPosition = nil
                                }
                            }
                        )
                        .controlSize(.mini)
                        .tint(accent)
                        Text(Self.clock(playing.duration))
                            .font(Theme.Fonts.microMono)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                HStack(spacing: Theme.Space.s) {
                    HoverGlyphButton(symbol: "backward.fill", scale: .s, tint: Theme.textPrimary) {
                        music.previous()
                    }
                    Button {
                        playing.isPlaying ? music.pause() : music.play()
                    } label: {
                        Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                            .font(Theme.Fonts.icon(.m, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.94)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                    HoverGlyphButton(symbol: "forward.fill", scale: .s, tint: Theme.textPrimary) {
                        music.next()
                    }
                    Slider(
                        value: Binding(
                            get: { volumeDraft ?? playing.volume },
                            set: { volumeDraft = $0 }
                        ),
                        in: 0...100,
                        onEditingChanged: { editing in
                            if !editing, let target = volumeDraft {
                                music.setVolume(target)
                                volumeDraft = nil
                            }
                        }
                    )
                    .controlSize(.mini)
                    .tint(Color.white.opacity(0.5))
                    .frame(width: 54)
                }
            }
        }
    }

    private var artworkView: some View {
        Group {
            if let artwork = music.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.surface
                    Image(systemName: "music.note")
                        .font(Theme.Fonts.icon(.l))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The ambience row: six plain-text chips — the words are the
/// interface — plus a volume that appears once something is playing.
struct AmbienceRow: View {
    @ObservedObject var ambience: AmbienceController
    @Environment(\.moaiAccent) private var accent

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ForEach(NoiseEngine.NoiseColor.allCases, id: \.self) { color in
                chip(color)
            }
            Spacer(minLength: 0)
            if ambience.active != nil {
                Slider(value: $ambience.volume, in: 0...1)
                    .controlSize(.mini)
                    .tint(Color.white.opacity(0.5))
                    .frame(width: 44)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.content, value: ambience.active)
    }

    private func chip(_ color: NoiseEngine.NoiseColor) -> some View {
        let on = ambience.active == color
        return Button {
            ambience.toggle(color)
        } label: {
            Text(color.displayName)
                .font(Theme.Fonts.label)
                .fontWeight(.medium)
                .foregroundStyle(on ? Color.white : Theme.textSecondary)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(
                    Capsule().fill(on ? accent.opacity(0.18) : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule().strokeBorder(
                        on ? accent.opacity(0.32) : Color.clear, lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(on ? "Stop \(color.displayName)" : "Play \(color.displayName)")
    }
}

/// The ask bar — the island's protagonist, identical in Peek and Full.
struct AskBar: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.moaiAccent) private var accent
    @FocusState private var inputFocused: Bool
    @AppStorage("aiProvider") private var aiProvider = ""

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            providerChip
            TextField("Ask anything…", text: $model.draftPrompt)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.reading)
                .focused($inputFocused)
                .onSubmit(sendDraft)
            HoverGlyphButton(symbol: "mic.fill", scale: .m, tint: Theme.textTertiary) {
                model.toggleListening()
            }
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.Fonts.icon(.xl))
                    .foregroundStyle(
                        model.draftPrompt.isEmpty ? Theme.textTertiary : accent
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(model.draftPrompt.isEmpty || model.isWorking)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
        .moaiField(active: inputFocused || !model.draftPrompt.isEmpty)
        .onAppear { inputFocused = true }
    }

    private var providerChip: some View {
        let provider = AIProvider(rawValue: aiProvider) ?? AIProvider.current
        return Button {
            aiProvider = provider.next.rawValue
        } label: {
            Text(provider.displayName)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: 22)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help("Answers with \(provider.displayName) — tap to switch")
    }

    private func sendDraft() {
        let text = model.draftPrompt
        model.draftPrompt = ""
        model.submit(text)
    }
}

/// The labeled way into Full — a pill that says what it does.
struct MoreButton: View {
    let expanded: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(expanded ? "Less" : "More")
                    .font(Theme.Fonts.caption)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(Theme.Fonts.icon(.xs, weight: .bold))
            }
            .foregroundStyle(hovered ? Theme.textSecondary : Theme.textTertiary)
            .padding(.horizontal, Theme.Space.wingInset)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(hovered ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}

/// The answer surface (Full's first tab): the reply, the hint, or the
/// working state. Input lives in the shared ask bar, not here.
struct AnswerView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.moaiAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let context = model.pendingContext {
                contextChip(context.name)
            }
            if model.isWorking, model.answer.isEmpty {
                ThinkingDots()
                    .padding(.top, Theme.Space.xs)
            } else if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.answer.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Ask anything — or hold the notch and speak.")
                        .font(Theme.Fonts.reading)
                        .foregroundStyle(Theme.textHint)
                    Text("remind me to call amma at 6 · focus 25 · timer 10 · note: an idea")
                        .font(Theme.Fonts.label)
                        .fontWeight(.regular)
                        .foregroundStyle(Theme.textGhost)
                }
            } else if model.answer.count > 900 {
                ScrollView {
                    answerText
                }
                .frame(maxHeight: 280)
            } else {
                answerText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var answerText: some View {
        Text(model.answer)
            .font(Theme.Fonts.reading)
            .lineSpacing(3)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextChip(_ name: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "paperclip")
                .font(Theme.Fonts.icon(.xs))
            Text(name)
                .font(Theme.Fonts.caption)
                .lineLimit(1)
            Button {
                model.pendingContext = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.Fonts.icon(.xs, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .foregroundStyle(accent)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(Capsule().fill(accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1))
    }
}
