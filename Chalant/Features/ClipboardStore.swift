import AppKit
import ImageIO
import os

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
        /// Pinned clips float to the top and never age out; plain
        /// history is everything else. Both persist across a relaunch.
        var pinned = false

        var isImage: Bool { imageURL != nil }
        var isFile: Bool { !(filePaths ?? []).isEmpty }

        static func == (lhs: Clip, rhs: Clip) -> Bool {
            lhs.id == rhs.id && lhs.pinned == rhs.pinned
        }
    }

    /// Invariant: pinned clips first (newest pin first), then unpinned
    /// by recency. Views can render straight through. This is the
    /// whole durable history, not a capped window: nothing here ages
    /// out on its own, so it can grow large over a long-lived install.
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
    private var lastChangeCount: Int

    /// The board this store watches and writes. Always the general
    /// pasteboard in production; a test passes its own named board so
    /// the suite neither touches nor depends on the machine's real
    /// clipboard.
    private let pasteboard: NSPasteboard

    /// Standard flags password managers and other "don't persist this"
    /// tools set on a sensitive copy. Chalant never stores anything
    /// marked with either, on the system pasteboard or in history.
    /// A pure function of the pasteboard's declared types, so the gate
    /// is testable without touching the live system pasteboard.
    static func isSensitive(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    private static let log = Logger(subsystem: "com.cj.chalant", category: "clipboard")

    /// Where the index and image files live. Always Application
    /// Support in production; a test passes its own scratch
    /// directory so a persistence test can never touch a real
    /// install's history.
    private let clipsDir: URL

    init(clipsDirectory: URL? = nil, pasteboard: NSPasteboard = .general) {
        clipsDir = clipsDirectory ?? Self.defaultClipsDirectory()
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
        loadIndex()
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

    /// Internal, not private, so a test can drive one capture pass
    /// directly instead of waiting out the timer.
    func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if let types = pasteboard.types, Self.isSensitive(types) {
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
           let url = savePNG(image) {
            insert(Clip(imageURL: url))
        }
    }

    /// An image dropped on the island (a screenshot thumbnail, a
    /// picture from the browser); joins history like a copied image.
    @discardableResult
    func addImage(_ image: NSImage) -> Bool {
        guard let url = savePNG(image) else { return false }
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

    /// New arrivals land at the top of the unpinned section. Every
    /// copy is kept: "so I dont lose anything that I copied" ruled
    /// out a count-based cap. Disk is the only limit now, the same as
    /// Finder or Photos, and the row's own remove button is the one
    /// way a clip leaves history.
    private func insert(_ clip: Clip) {
        let pinnedCount = clips.prefix { $0.pinned }.count
        clips.insert(clip, at: pinnedCount)
        saveIndex()
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
        saveIndex()
    }

    func copyBack(_ clip: Clip) {
        pasteboard.clearContents()
        if let paths = clip.filePaths, !paths.isEmpty {
            pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        } else if let text = clip.text {
            pasteboard.setString(text, forType: .string)
        } else if let url = clip.imageURL, let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        }
        // Copying back is a restore, not a copy: the poller must not
        // archive our own write as a brand-new clip, which put the
        // same content at the top again (worst for images, which have
        // no consecutive-repeat guard and minted a fresh row and PNG
        // every time). Marking the change as already seen covers
        // exactly this one write; the next foreign copy lands as usual.
        lastChangeCount = pasteboard.changeCount
    }

    func remove(_ clip: Clip) {
        clip.imageURL.map { try? FileManager.default.removeItem(at: $0) }
        clips.removeAll { $0.id == clip.id }
        saveIndex()
    }

    /// Everything the user did not pin, gone, images deleted from disk
    /// alongside their entries.
    ///
    /// Pins survive on purpose. Pinning is this app's standing promise
    /// that something stays, said out loud in the empty state ("Pin or
    /// shelf what should stay"), and a bulk clear that broke it would
    /// delete files somebody had deliberately marked as keepers, with
    /// no undo. Unpin first if a pin should go.
    func clearUnpinned() {
        for clip in clips where !clip.pinned {
            clip.imageURL.map { try? FileManager.default.removeItem(at: $0) }
        }
        clips.removeAll { !$0.pinned }
        saveIndex()
    }

    /// Whether `clearUnpinned` would actually do anything, so the
    /// control can stay away when it cannot act.
    var hasUnpinned: Bool {
        clips.contains { !$0.pinned }
    }

    /// What the history costs on disk, in bytes.
    ///
    /// Nothing is evicted any more, which is what "I don't lose
    /// anything" asks for and is the right default. It does mean a
    /// screenshot copied is a screenshot kept forever, and images are
    /// megabytes where text is bytes, so a year of this is real disk
    /// with nothing anywhere admitting it. Keeping everything is a
    /// choice the user should be able to see the price of; a cost that
    /// only shows up when the disk is full is a cost that was hidden.
    func historyBytes() -> Int64 {
        clips.compactMap(\.imageURL).reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            total += Int64(size ?? 0)
        }
    }

    /// Everything that is not pinned, and its images with it. Pinned
    /// clips are the ones deliberately kept, so a reclaim never touches
    /// them: this is for taking the disk back, not for forgetting.
    func forgetUnpinned() {
        for clip in clips where !clip.pinned {
            clip.imageURL.map { try? FileManager.default.removeItem(at: $0) }
        }
        clips.removeAll { !$0.pinned }
        saveIndex()
    }

    // MARK: - Persistence

    private static func defaultClipsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chalant/Clips", isDirectory: true)
    }

    private func clipsDirectory() -> URL {
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        return clipsDir
    }

    /// Named from when this file held only pinned clips. It now holds
    /// the whole durable history; renaming it would need a migration
    /// step for zero benefit, so the name stays and this comment
    /// carries the truth. Every clip already on disk here (a founder's
    /// pinned keepers) loads exactly as before, then joins the same
    /// file as plain history from the next copy on.
    private func indexFile() -> URL {
        clipsDirectory().appendingPathComponent("pinned.json")
    }

    /// The whole history rides one JSON file; images stay in their own
    /// PNG files (below) so the index itself never carries pixel data.
    /// Entries whose image went missing some other way are dropped
    /// rather than shown broken. Orphan PNGs are swept the same way
    /// the old pinned-only cleanup did.
    private func loadIndex() {
        var loaded: [Clip] = []
        if let data = try? Data(contentsOf: indexFile()) {
            do {
                let decoded = try JSONDecoder().decode([Clip].self, from: data)
                loaded = decoded.filter { clip in
                    guard let url = clip.imageURL else { return true }
                    return FileManager.default.fileExists(atPath: url.path)
                }
            } catch {
                Self.log.error("clip history failed to decode, starting empty: \(error, privacy: .public)")
            }
        }
        clips = loaded
        let kept = Set(loaded.compactMap { $0.imageURL?.lastPathComponent })
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: clipsDirectory(), includingPropertiesForKeys: nil
        )) ?? []
        for file in contents
        where file.pathExtension == "png" && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// ponytail: rewrites the whole array on every save, atomically so
    /// a crash mid-write can never leave a torn file. Fine at the size
    /// a personal clipboard reaches; move to an append log or SQLite
    /// if this ever measurably slows down.
    private func saveIndex() {
        do {
            let data = try JSONEncoder().encode(clips)
            try data.write(to: indexFile(), options: .atomic)
        } catch {
            Self.log.error("clip history failed to save: \(error, privacy: .public)")
        }
    }

    // MARK: - Images

    /// Copied images have no file behind them, so keep a PNG in the app's
    /// own folder that a clip can point at and paste back later.
    private func savePNG(_ image: NSImage) -> URL? {
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
