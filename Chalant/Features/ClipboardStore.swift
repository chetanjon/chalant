import AppKit
import ImageIO

@MainActor
final class ClipboardStore: ObservableObject {
    struct Clip: Identifiable, Equatable, Codable {
        var id = UUID()
        var date = Date()
        /// Text clips carry `text`; image clips (screenshots, copied
        /// pictures) carry a PNG on disk at `imageURL`; file clips
        /// (Finder copies) carry the copied paths.
        var text: String?
        var imageURL: URL?
        var filePaths: [String]?
        /// Pinned clips float to the top, never age out, and come
        /// back after a relaunch. History stays ephemeral.
        var pinned = false

        var isImage: Bool { imageURL != nil }
        var isFile: Bool { !(filePaths ?? []).isEmpty }

        static func == (lhs: Clip, rhs: Clip) -> Bool {
            lhs.id == rhs.id && lhs.pinned == rhs.pinned
        }
    }

    /// Invariant: pinned clips first (newest pin first), then unpinned
    /// by recency. Views can render straight through.
    @Published var clips: [Clip] = []

    /// Whether a clip answers to a search.
    ///
    /// Case- and diacritic-insensitive, matched anywhere in the content:
    /// people search for a fragment they remember, not a prefix, and
    /// they do not remember accents. A file clip matches on its names,
    /// which is the part a person recalls copying. An image carries no
    /// text at all, so it can only fail — better than quietly ranking
    /// it as a match for everything.
    static func matches(_ clip: Clip, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let text = clip.text, text.range(of: needle, options: options) != nil {
            return true
        }
        return (clip.filePaths ?? []).contains {
            ($0 as NSString).lastPathComponent.range(of: needle, options: options) != nil
        }
    }

    /// The clips a search leaves, in the order they already had. Pinned
    /// clips are not exempt: a search that still showed them would be
    /// answering a question nobody asked.
    static func filtered(_ clips: [Clip], query: String) -> [Clip] {
        clips.filter { matches($0, query: query) }
    }

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let maxClips = 30

    /// Standard flag password managers set on sensitive copies.
    /// Chalant never stores anything marked with it.
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    init() {
        loadPinned()
    }

    func start() {
        // Called twice, this would leak the first timer to the run loop
        // and poll the pasteboard at double the rate for the life of
        // the app, with nothing to show that it had happened.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if let types = pasteboard.types,
           types.contains(concealedType) || types.contains(transientType) {
            return
        }

        // A copied file first: Finder puts the file's NAME on the
        // pasteboard as text too, and capturing that as a text clip
        // was the last incoherence between the stream and the keep.
        // The file itself is the meaning.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty, urls.allSatisfy(\.isFileURL) {
            let paths = urls.map(\.path)
            if firstUnpinned?.filePaths == paths { return }
            insert(Clip(filePaths: paths))
            return
        }

        // Text wins when present (a text copy often carries an icon too).
        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if firstUnpinned?.text == text { return }
            insert(Clip(text: text))
            return
        }

        // Otherwise a copied image or screenshot (Cmd-Ctrl-Shift-4).
        if let image = NSImage(pasteboard: pasteboard),
           let url = Self.savePNG(image) {
            insert(Clip(imageURL: url))
        }
    }

    /// An image dropped on the island (a screenshot thumbnail, a
    /// picture from the browser); joins history like a copied image.
    @discardableResult
    func addImage(_ image: NSImage) -> Bool {
        guard let url = Self.savePNG(image) else { return false }
        insert(Clip(imageURL: url))
        return true
    }

    /// A text snippet dropped on the island; same rules as a copy.
    @discardableResult
    func addText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Already at the top of the history: that counts as landed.
        if firstUnpinned?.text == text { return true }
        insert(Clip(text: text))
        return true
    }

    private var firstUnpinned: Clip? {
        clips.first { !$0.pinned }
    }

    /// New arrivals land at the top of the unpinned section, and only
    /// unpinned history counts toward the cap.
    private func insert(_ clip: Clip) {
        let pinnedCount = clips.prefix { $0.pinned }.count
        clips.insert(clip, at: pinnedCount)
        let unpinned = clips.filter { !$0.pinned }
        if unpinned.count > maxClips {
            for evicted in unpinned.suffix(unpinned.count - maxClips) {
                evicted.imageURL.map { try? FileManager.default.removeItem(at: $0) }
                clips.removeAll { $0.id == evicted.id }
            }
        }
    }

    /// Pin lands it on top of the keepers; unpin returns it to the top
    /// of history, as the most recently touched thing.
    func togglePin(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var moved = clips.remove(at: index)
        moved.pinned.toggle()
        if moved.pinned {
            clips.insert(moved, at: 0)
        } else {
            let pinnedCount = clips.prefix { $0.pinned }.count
            clips.insert(moved, at: pinnedCount)
        }
        savePinned()
    }

    func copyBack(_ clip: Clip) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let paths = clip.filePaths, !paths.isEmpty {
            pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        } else if let text = clip.text {
            pasteboard.setString(text, forType: .string)
        } else if let url = clip.imageURL, let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        }
    }

    func remove(_ clip: Clip) {
        clip.imageURL.map { try? FileManager.default.removeItem(at: $0) }
        let wasPinned = clip.pinned
        clips.removeAll { $0.id == clip.id }
        if wasPinned { savePinned() }
    }

    // MARK: - Pinned persistence

    private static func clipsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chalant/Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func pinnedFile() -> URL {
        clipsDirectory().appendingPathComponent("pinned.json")
    }

    /// Pinned clips ride a small JSON file; everything else is session
    /// history. Image files no pinned clip references are deleted here,
    /// they used to pile up forever, one PNG per copied screenshot.
    private func loadPinned() {
        var pinned: [Clip] = []
        if let data = try? Data(contentsOf: Self.pinnedFile()),
           let decoded = try? JSONDecoder().decode([Clip].self, from: data) {
            pinned = decoded.filter { clip in
                guard let url = clip.imageURL else { return true }
                return FileManager.default.fileExists(atPath: url.path)
            }
        }
        clips = pinned
        let kept = Set(pinned.compactMap { $0.imageURL?.lastPathComponent })
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.clipsDirectory(), includingPropertiesForKeys: nil
        )) ?? []
        for file in contents
        where file.pathExtension == "png" && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func savePinned() {
        let pinned = clips.filter(\.pinned)
        if let data = try? JSONEncoder().encode(pinned) {
            try? data.write(to: Self.pinnedFile())
        }
    }

    // MARK: - Images

    /// Copied images have no file behind them, so keep a PNG in the app's
    /// own folder that a clip can point at and paste back later.
    private static func savePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = clipsDirectory().appendingPathComponent("\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Row thumbnails, decoded once and kept warm. Reading the full
    /// PNG off disk on every row render made the pane stutter.
    private static let thumbCache = NSCache<NSURL, NSImage>()

    static func thumbnail(for url: URL, height: CGFloat = 64) -> NSImage? {
        if let cached = thumbCache.object(forKey: url as NSURL) {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(height * 4),
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        thumbCache.setObject(image, forKey: url as NSURL)
        return image
    }
}
