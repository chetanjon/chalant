import AppKit
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

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

    /// A dragged web link becomes a .webloc in the app's folder, so it
    /// rides the same bookmark persistence as any stashed file.
    @discardableResult
    func addLink(_ link: URL) -> Bool {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: ["URL": link.absoluteString],
            format: .xml,
            options: 0
        ) else { return false }
        let name = "\(link.host ?? "link")-\(Self.uniqueSuffix()).webloc"
        let url = Self.droppedDirectory().appendingPathComponent(name)
        guard (try? data.write(to: url)) != nil else { return false }
        add(url)
        return true
    }

    /// A clip promoted off the passing stream: the content is copied
    /// into the shelf's own folder, so the keep outlives the ring.
    @discardableResult
    func keep(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let name = "Snippet-\(Self.uniqueSuffix()).txt"
        let url = Self.droppedDirectory().appendingPathComponent(name)
        guard (try? trimmed.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return false }
        add(url)
        return true
    }

    @discardableResult
    func keep(imageAt source: URL) -> Bool {
        let name = "Screenshot-\(Self.uniqueSuffix()).png"
        let url = Self.droppedDirectory().appendingPathComponent(name)
        guard (try? FileManager.default.copyItem(at: source, to: url)) != nil
        else { return false }
        add(url)
        return true
    }

    private static func droppedDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chalant/Dropped", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func uniqueSuffix() -> String {
        String(UUID().uuidString.prefix(4))
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Empties the shelf.
    ///
    /// Nothing is deleted. The shelf only ever held bookmarks to files
    /// that live wherever the user already keeps them, so this forgets
    /// where they were and leaves every file untouched. That is why it
    /// needs no confirmation, unlike the clipboard's clear, which does
    /// delete the screenshots it owns.
    func clearAll() {
        items.removeAll()
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

    /// Copy the file itself: paste lands the file in Finder and the
    /// image in image-aware apps.
    func copyToPasteboard(_ item: Item) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item.url as NSURL])
    }

    /// Cheap check for the ask-mark affordance. The old path ran the
    /// full extraction (whole file read, PDF parse) for every row on
    /// every render; this reads nothing but the file extension.
    func canExtractText(_ item: Item) -> Bool {
        let ext = item.url.pathExtension.lowercased()
        if ext == "pdf" { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .json) || type.conforms(to: .propertyList)
    }

    /// Best-effort text extraction so Chalant can answer questions
    /// about a stashed file. PDFs and any UTF-8 text for v1. Runs
    /// only when the user actually asks, never during render.
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

    // MARK: - Thumbnails

    private static let thumbCache = NSCache<NSURL, NSImage>()

    /// A real Quick Look preview of the file, generated once and kept
    /// warm; nil until it lands (rows show the Finder icon meanwhile).
    static func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = thumbCache.object(forKey: url as NSURL) {
            return cached
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail
        )
        guard let rep = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        thumbCache.setObject(image, forKey: url as NSURL)
        return image
    }
}
