import SwiftUI

struct ClipboardView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var clipboard: ClipboardStore

    init(model: NotchViewModel) {
        self.model = model
        self.clipboard = model.clipboard
    }

    @State private var query = ""
    @State private var page = 0
    @FocusState private var searching: Bool
    @Environment(\.chalantAccent) private var accent

    /// Rows per page. HuggingList builds every row eagerly (it needs
    /// to measure both its hugging and scrolling layouts), so an
    /// unbounded history rendered in one go is the actual slowdown a
    /// page window avoids, not just a visual convenience.
    private let pageSize = 20

    var body: some View {
        if clipboard.clips.isEmpty {
            EmptyPaneHint(message: "Whatever you copy lands here on its own, all of it. Pin or shelf what should stay.")
        } else {
            let shown = ClipboardStore.filtered(clipboard.clips, query: query)
            let pageCount = max(1, (shown.count + pageSize - 1) / pageSize)
            let currentPage = min(page, pageCount - 1)
            let pageStart = currentPage * pageSize
            let pageEnd = min(pageStart + pageSize, shown.count)
            let pageClips = Array(shown[pageStart..<pageEnd])
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                // Only once there is enough history to lose something
                // in. Below that the search field is a control that
                // costs a row and saves nothing.
                if clipboard.clips.count > 5 { searchField }
                if shown.isEmpty {
                    Text("Nothing copied matches \u{201C}\(query)\u{201D}.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textHint)
                        .padding(.vertical, Theme.Space.m)
                } else {
                    HuggingList {
                        ForEach(pageClips) { clip in
                            ClipRow(clip: clip, model: model, clipboard: clipboard)
                        }
                    }
                    if pageCount > 1 {
                        pageControls(current: currentPage, count: pageCount)
                    }
                }
            }
            .animation(Theme.Motion.content, value: pageClips.map(\.id))
            .onChange(of: query) { _, _ in page = 0 }
        }
    }

    /// Quiet prev/next pair plus a plain count, subordinate to the
    /// rows above it. Only shown once a search or the raw history
    /// actually spans more than one page.
    private func pageControls(current: Int, count: Int) -> some View {
        HStack(spacing: Theme.Space.s) {
            IconActionButton(symbol: "chevron.left", label: "Previous page", dim: current == 0) {
                guard current > 0 else { return }
                page = current - 1
            }
            Spacer()
            Text("Page \(current + 1) of \(count)")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            IconActionButton(symbol: "chevron.right", label: "Next page", dim: current == count - 1) {
                guard current < count - 1 else { return }
                page = current + 1
            }
        }
        .padding(.horizontal, Theme.Space.s)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Fonts.icon(.xs))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search what you copied", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .focused($searching)
            if !query.isEmpty {
                IconActionButton(symbol: "xmark", label: "Clear the search", dim: true) { query = "" }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .chalantField()
    }
}

/// One clip, text or image. Actions rest quiet and come to full
/// strength when the row is under the cursor.
private struct ClipRow: View {
    let clip: ClipboardStore.Clip
    let model: NotchViewModel
    let clipboard: ClipboardStore

    @Environment(\.chalantAccent) private var accent
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
                    label: clip.pinned ? "Unpin" : "Pin",
                    tint: clip.pinned ? accent : Theme.textSecondary
                ) {
                    clipboard.togglePin(clip)
                }
                IconActionButton(symbol: "doc.on.doc", label: "Copy") {
                    clipboard.copyBack(clip)
                }
                // The bridge between the two surfaces: clips are the
                // passing stream, the shelf is the keep, and this
                // moves one across.
                IconActionButton(
                    symbol: "tray.and.arrow.down", label: "Keep on the Shelf",
                    tint: Theme.textSecondary
                ) {
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
                // AirDrop for the clips that are things (files and
                // screenshots); words travel better by paste.
                if clip.isFile || clip.isImage {
                    IconActionButton(symbol: "dot.radiowaves.left.and.right", label: "AirDrop") {
                        let items: [Any] = clip.filePaths?.map {
                            URL(fileURLWithPath: $0)
                        } ?? clip.imageURL.map { [$0] } ?? []
                        guard !items.isEmpty else { return }
                        NSSharingService(named: .sendViaAirDrop)?
                            .perform(withItems: items)
                    }
                }
                // Text can go to the answer surface; an image can't.
                if let text = clip.text {
                    IconActionButton(symbol: "chalant.mark", label: "Ask about this", tint: accent) {
                        model.askAbout(name: "clipboard", text: text)
                    }
                }
                IconActionButton(symbol: "xmark", label: "Remove this clip", dim: true) {
                    clipboard.remove(clip)
                }
            }
            .opacity(hovered ? 1 : clip.pinned ? 0.8 : 0.6)
        }
        .rowInsets()
        .chalantCard(radius: Theme.Radius.row)
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
