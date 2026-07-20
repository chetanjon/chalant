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
                Text("Copy text or a screenshot and it lands here.")
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

/// One clip, text or image. Actions rest quiet and come to full
/// strength when the row is under the cursor.
private struct ClipRow: View {
    let clip: ClipboardStore.Clip
    let model: NotchViewModel
    let clipboard: ClipboardStore

    @Environment(\.moaiAccent) private var accent
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if clip.isImage {
                thumbnail
                Text("Screenshot")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(clip.text ?? "")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                IconActionButton(symbol: "doc.on.doc") {
                    clipboard.copyBack(clip)
                }
                // Text can go to the answer surface; an image can't.
                if let text = clip.text {
                    IconActionButton(symbol: "sparkles", tint: accent) {
                        model.askAbout(name: "clipboard", text: text)
                    }
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

    @ViewBuilder
    private var thumbnail: some View {
        if let url = clip.imageURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 46, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
    }
}
