import SwiftUI

/// The Do surface: answer area, optional attachment chip, input line.
struct DoView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.moaiAccent) private var accent
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            answerArea
            // A live wire under the text while the answer streams in.
            if model.isWorking, !model.answer.isEmpty {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.5), accent.opacity(0.05)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .transition(.opacity)
            }
            if let context = model.pendingContext {
                contextChip(context.name)
            }
            inputBar
        }
        .animation(Theme.Motion.content, value: model.isWorking)
        .onAppear { inputFocused = true }
    }

    private var answerArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.isWorking, model.answer.isEmpty {
                    ThinkingDots()
                        .padding(.top, Theme.Space.xs)
                } else if !model.errorText.isEmpty {
                    Text(model.errorText)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.danger)
                } else if model.answer.isEmpty {
                    Text("remind me to call amma at 6. focus 25. timer 10. note: an idea. notes. Or hold the notch and say it.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(model.answer)
                        .font(Theme.Fonts.reading)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func contextChip(_ name: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "paperclip")
                .font(Theme.Fonts.icon(.xs))
            Text(name)
                .font(Theme.Fonts.caption)
                .lineLimit(1)
            // Tight capsule: a 22pt frame would balloon the chip, so
            // this stays a bare glyph by design.
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

    private var inputBar: some View {
        HStack(spacing: Theme.Space.m) {
            TextField("What needs doing", text: $model.draftPrompt)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.reading)
                .focused($inputFocused)
                .onSubmit(sendDraft)
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
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .moaiField(active: inputFocused || !model.draftPrompt.isEmpty)
    }

    private func sendDraft() {
        let text = model.draftPrompt
        model.draftPrompt = ""
        model.submit(text)
    }
}
