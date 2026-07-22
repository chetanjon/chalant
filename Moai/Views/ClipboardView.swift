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
            EmptyPaneHint(message: "Whatever you copy lands here on its own, the last 30. Pin or shelf what should stay.")
        } else {
            HuggingList {
                ForEach(clipboard.clips) { clip in
                    ClipRow(clip: clip, model: model, clipboard: clipboard)
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
            } else if let paths = clip.filePaths, let first = paths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(
                    paths.count == 1
                        ? (first as NSString).lastPathComponent
                        : "\((first as NSString).lastPathComponent) + \(paths.count - 1) more"
                )
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(clip.text ?? "")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                // Keepers: a pinned clip floats up, never ages out,
                // and survives a relaunch.
                IconActionButton(
                    symbol: clip.pinned ? "pin.fill" : "pin",
                    tint: clip.pinned ? accent : Theme.textSecondary
                ) {
                    clipboard.togglePin(clip)
                }
                IconActionButton(symbol: "doc.on.doc") {
                    clipboard.copyBack(clip)
                }
                // The bridge between the two surfaces: clips are the
                // passing stream, the shelf is the keep, and this
                // moves one across.
                IconActionButton(symbol: "tray.and.arrow.down", tint: Theme.textSecondary) {
                    let kept: Bool
                    if let paths = clip.filePaths, !paths.isEmpty {
                        // Copied files shelve as themselves, same as
                        // a drop would.
                        paths.forEach { model.shelf.add(URL(fileURLWithPath: $0)) }
                        kept = true
                    } else if let source = clip.imageURL {
                        kept = model.shelf.keep(imageAt: source)
                    } else {
                        kept = model.shelf.keep(text: clip.text ?? "")
                    }
                    if kept { model.flashGlance("Kept on the Shelf") }
                }
                .help("Keep on the Shelf")
                // AirDrop for the clips that are things (files and
                // screenshots); words travel better by paste.
                if clip.isFile || clip.isImage {
                    IconActionButton(symbol: "dot.radiowaves.left.and.right") {
                        let items: [Any] = clip.filePaths?.map {
                            URL(fileURLWithPath: $0)
                        } ?? clip.imageURL.map { [$0] } ?? []
                        guard !items.isEmpty else { return }
                        NSSharingService(named: .sendViaAirDrop)?
                            .perform(withItems: items)
                    }
                    .help("AirDrop")
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
            .opacity(hovered ? 1 : clip.pinned ? 0.8 : 0.6)
        }
        .rowInsets()
        .moaiCard(radius: Theme.Radius.row)
        .hoverHighlight(radius: Theme.Radius.row)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        // Drag a clip back out to any app: a screenshot travels as
        // its file, text as text.
        .onDrag {
            if let first = clip.filePaths?.first {
                return NSItemProvider(object: NSURL(fileURLWithPath: first))
            }
            if let url = clip.imageURL {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider(object: (clip.text ?? "") as NSString)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = clip.imageURL, let image = ClipboardStore.thumbnail(for: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 46, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
    }
}
