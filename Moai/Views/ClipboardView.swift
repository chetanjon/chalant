import SwiftUI

struct ClipboardView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var clipboard: ClipboardStore

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
                VStack(spacing: Theme.Space.s) {
                    ForEach(clipboard.clips) { clip in
                        ClipRow(clip: clip, model: model, clipboard: clipboard)
                    }
                }
            }
        }
    }
}

/// One clip. Actions rest quiet and come to full strength when the
/// row is under the cursor.
private struct ClipRow: View {
    let clip: ClipboardStore.Clip
    let model: NotchViewModel
    let clipboard: ClipboardStore

    @Environment(\.moaiAccent) private var accent
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(clip.text)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
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
            .opacity(hovered ? 1 : 0.6)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .moaiCard(radius: Theme.Radius.row)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.03 : 0))
                .allowsHitTesting(false)
        )
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}
