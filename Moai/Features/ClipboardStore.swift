import AppKit

@MainActor
final class ClipboardStore: ObservableObject {
    struct Clip: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        /// Text clips carry `text`; image clips (screenshots, copied
        /// pictures) carry a PNG on disk at `imageURL`.
        var text: String?
        var imageURL: URL?

        var isImage: Bool { imageURL != nil }

        static func == (lhs: Clip, rhs: Clip) -> Bool { lhs.id == rhs.id }
    }

    @Published var clips: [Clip] = []

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let maxClips = 30

    /// Standard flag password managers set on sensitive copies.
    /// Moai never stores anything marked with it.
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if let types = pasteboard.types,
           types.contains(concealedType) || types.contains(transientType) {
            return
        }

        // Text wins when present (a text copy often carries an icon too).
        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if clips.first?.text == text { return }
            insert(Clip(date: Date(), text: text))
            return
        }

        // Otherwise a copied image or screenshot (Cmd-Ctrl-Shift-4).
        if let image = NSImage(pasteboard: pasteboard),
           let url = Self.savePNG(image) {
            insert(Clip(date: Date(), imageURL: url))
        }
    }

    private func insert(_ clip: Clip) {
        clips.insert(clip, at: 0)
        if clips.count > maxClips {
            for evicted in clips.suffix(clips.count - maxClips) {
                evicted.imageURL.map { try? FileManager.default.removeItem(at: $0) }
            }
            clips.removeLast(clips.count - maxClips)
        }
    }

    func copyBack(_ clip: Clip) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let text = clip.text {
            pasteboard.setString(text, forType: .string)
        } else if let url = clip.imageURL, let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        }
    }

    func remove(_ clip: Clip) {
        clip.imageURL.map { try? FileManager.default.removeItem(at: $0) }
        clips.removeAll { $0.id == clip.id }
    }

    /// Copied images have no file behind them, so keep a PNG in the app's
    /// own folder that a clip can point at and paste back later.
    private static func savePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moai/Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
