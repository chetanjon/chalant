import SwiftUI

struct ClipboardView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var clipboard: ClipboardStore
    @Environment(\.moaiAccent) private var accent

    init(model: NotchViewModel) {
        self.model = model
        self.clipboard = model.clipboard
    }

    var body: some View {
        if clipboard.clips.isEmpty {
            VStack {
                Spacer()
                Text("Everything you copy lands here.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textHint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(clipboard.clips) { clip in
                        row(clip)
                    }
                }
            }
        }
    }

    private func row(_ clip: ClipboardStore.Clip) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(clip.text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Copy it back to the pasteboard
            IconActionButton(symbol: "doc.on.doc") {
                clipboard.copyBack(clip)
            }
            // Hand it to the Do surface: summarize, rewrite, translate
            IconActionButton(symbol: "sparkles", tint: accent) {
                model.askAbout(name: "clipboard", text: clip.text)
            }
            IconActionButton(symbol: "xmark", dim: true) {
                clipboard.remove(clip)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .moaiCard(radius: Theme.Radius.row)
        .hoverHighlight()
    }
}
