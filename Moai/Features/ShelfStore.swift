import AppKit
import PDFKit

@MainActor
final class ShelfStore: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var name: String { url.lastPathComponent }
    }

    @Published var items: [Item] = []
    private let maxItems = 12
    private let defaultsKey = "shelfBookmarks"

    init() {
        load()
    }

    func add(_ url: URL) {
        guard !items.contains(where: { $0.url == url }) else { return }
        items.insert(Item(url: url), at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
        save()
    }

    /// A dropped image with no file behind it (a screenshot thumbnail):
    /// write a PNG into the app's own folder, then stash that.
    func addImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moai/Dropped", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Shot-\(Int(Date().timeIntervalSince1970)).png")
        guard (try? png.write(to: url)) != nil else { return }
        add(url)
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: Persistence

    /// Bookmarks, not paths: a stashed file keeps resolving after the
    /// user renames or moves it. Files deleted since last launch are
    /// quietly pruned.
    private func load() {
        guard let blobs = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] else {
            return
        }
        items = blobs.compactMap { data in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Item(url: url)
        }
        save()
    }

    private func save() {
        let blobs = items.compactMap { try? $0.url.bookmarkData() }
        UserDefaults.standard.set(blobs, forKey: defaultsKey)
    }

    func airDrop(_ item: Item) {
        NSSharingService(named: .sendViaAirDrop)?
            .perform(withItems: [item.url])
    }

    /// Best-effort text extraction so Moai can answer questions
    /// about a stashed file. PDFs and any UTF-8 text for v1.
    func extractText(_ item: Item, limit: Int = 8000) -> String? {
        let url = item.url
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url),
                  let text = document.string else { return nil }
            return String(text.prefix(limit))
        }
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(limit))
        }
        return nil
    }
}
