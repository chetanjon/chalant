import SwiftUI

struct ShelfView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    @Environment(\.moaiAccent) private var accent

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
                VStack(spacing: 6) {
                    ForEach(shelf.items) { item in
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ item: ShelfStore.Item) -> some View {
        let extractedText = shelf.extractText(item)
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: "doc.fill")
                .font(Theme.Fonts.icon(.m))
                .foregroundStyle(Theme.textSecondary)

            Text(item.name)
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .moaiCard(radius: Theme.Radius.row)
        .hoverHighlight()
        // Drag the file back out to Finder or any app
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
    }
}
