import AppKit
import SwiftUI

struct ShelfView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var shelf: ShelfStore

    init(model: NotchViewModel) {
        self.model = model
        self.shelf = model.shelf
    }

    var body: some View {
        if shelf.items.isEmpty {
            EmptyPaneHint(message: "Drop files or links on the notch and they stay here until you take them back.")
        } else {
            HuggingList {
                ForEach(shelf.items) { item in
                    ShelfRow(item: item, model: model, shelf: shelf)
                }
            }
        }
    }
}

/// One stashed file: its real Finder icon, name, and quiet actions
/// that wake on hover. Draggable back out to any app.
private struct ShelfRow: View {
    let item: ShelfStore.Item
    let model: NotchViewModel
    let shelf: ShelfStore

    @Environment(\.moaiAccent) private var accent
    @Environment(\.displayScale) private var displayScale
    @State private var hovered = false
    /// The file's Quick Look preview; the Finder icon holds the seat
    /// until it arrives.
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            preview

            Text(item.name)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                IconActionButton(symbol: "doc.on.doc") {
                    shelf.copyToPasteboard(item)
                }
                // The full share sheet (Messages, Mail, everything).
                ShareLink(item: item.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                // And the one-tap jump for the commonest case: this
                // file, that Mac or phone, now.
                IconActionButton(symbol: "dot.radiowaves.left.and.right") {
                    NSSharingService(named: .sendViaAirDrop)?
                        .perform(withItems: [item.url])
                }
                .help("AirDrop")
                if shelf.canExtractText(item) {
                    IconActionButton(symbol: "sparkles", tint: accent) {
                        guard let text = shelf.extractText(item) else { return }
                        model.askAbout(name: item.name, text: text)
                    }
                }
                IconActionButton(symbol: "xmark", dim: true) {
                    shelf.remove(item)
                }
            }
            .opacity(hovered ? 1 : 0.6)
        }
        .rowInsets()
        .moaiCard(radius: Theme.Radius.row)
        .hoverHighlight(radius: Theme.Radius.row)
        .contentShape(Rectangle())
        // A tap opens the file where it belongs; the buttons keep
        // their own clicks.
        .onTapGesture {
            NSWorkspace.shared.open(item.url)
        }
        .help("Open \(item.name)")
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        // Drag the file back out to Finder or any app
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
        .task(id: item.url) {
            thumb = await ShelfStore.thumbnail(
                for: item.url,
                size: CGSize(width: 46, height: 32),
                scale: displayScale
            )
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumb {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 46, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 46, height: 32)
        }
    }
}
