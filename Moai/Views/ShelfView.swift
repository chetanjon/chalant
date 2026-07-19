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
            VStack {
                Spacer()
                Text("Drop files on the notch to stash them here.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textHint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(shelf.items) { item in
                        ShelfRow(item: item, model: model, shelf: shelf)
                    }
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
    @State private var hovered = false

    var body: some View {
        let extractedText = shelf.extractText(item)
        return HStack(spacing: Theme.Space.m) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 16, height: 16)

            Text(item.name)
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                IconActionButton(symbol: "square.and.arrow.up") {
                    shelf.airDrop(item)
                }
                if let extractedText {
                    IconActionButton(symbol: "sparkles", tint: accent) {
                        model.askAbout(name: item.name, text: extractedText)
                    }
                }
                IconActionButton(symbol: "xmark", dim: true) {
                    shelf.remove(item)
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
        // Drag the file back out to Finder or any app
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
    }
}
