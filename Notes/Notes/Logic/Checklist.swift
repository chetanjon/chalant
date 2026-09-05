import Foundation

/// Checklists are plain text. A line that starts with `□ ` is an open item
/// and one that starts with `■ ` is done. Everything here is string
/// manipulation on the line under the cursor; there is no rich text model.
///
/// Cursor positions are UTF-16 offsets, the unit `UITextView.selectedRange`
/// speaks, so the editor can pass them straight through. Both markers are a
/// single UTF-16 unit, so a marker with its space is always two units.
enum Checklist {
    static let open = "□ "
    static let done = "■ "
    /// Length of a marker plus its trailing space, in UTF-16 units.
    static let markerLength = 2

    static func isItem(_ line: Substring) -> Bool {
        line.hasPrefix(open) || line.hasPrefix(done)
    }

    static func isItem(_ line: String) -> Bool { isItem(line[...]) }

    static func isDone(_ line: String) -> Bool { line.hasPrefix(done) }

    /// Swaps an open marker for a done one and back. A line that is not an
    /// item comes back unchanged.
    static func toggle(_ line: String) -> String {
        if line.hasPrefix(done) { return open + line.dropFirst(markerLength) }
        if line.hasPrefix(open) { return done + line.dropFirst(markerLength) }
        return line
    }

    /// The text of an item without its marker; the line itself otherwise.
    static func content(_ line: String) -> String {
        isItem(line) ? String(line.dropFirst(markerLength)) : line
    }

    /// The result of an edit: the new text and where the cursor should land.
    struct Edit: Equatable {
        var text: String
        var cursor: Int
    }

    /// The range of the line containing `cursor`, without its line break.
    static func lineRange(in text: String, at cursor: Int) -> NSRange {
        let ns = text as NSString
        let location = max(0, min(cursor, ns.length))
        let full = ns.lineRange(for: NSRange(location: location, length: 0))
        var length = full.length
        // Trim the terminator: "\r\n", "\n", or "\r".
        if length > 0, ns.character(at: full.location + length - 1) == 0x0A { length -= 1 }
        if length > 0, ns.character(at: full.location + length - 1) == 0x0D { length -= 1 }
        return NSRange(location: full.location, length: length)
    }

    /// The line containing `cursor`, without its line break.
    static func line(in text: String, at cursor: Int) -> String {
        (text as NSString).substring(with: lineRange(in: text, at: cursor))
    }

    /// The toolbar button. A plain line becomes an open item; an item goes
    /// back to plain text. The cursor keeps its place in the line's content.
    static func toggleItem(in text: String, at cursor: Int) -> Edit {
        let ns = text as NSString
        let range = lineRange(in: text, at: cursor)
        let line = ns.substring(with: range)
        if isItem(line) {
            let replaced = ns.replacingCharacters(
                in: NSRange(location: range.location, length: markerLength), with: "")
            return Edit(text: replaced, cursor: max(range.location, cursor - markerLength))
        }
        let replaced = ns.replacingCharacters(
            in: NSRange(location: range.location, length: 0), with: open)
        return Edit(text: replaced, cursor: cursor + markerLength)
    }

    /// Tapping the marker. Flips open and done on the line containing
    /// `cursor`; a plain line is left alone.
    static func toggleDone(in text: String, at cursor: Int) -> Edit {
        let ns = text as NSString
        let range = lineRange(in: text, at: cursor)
        let line = ns.substring(with: range)
        guard isItem(line) else { return Edit(text: text, cursor: cursor) }
        return Edit(text: ns.replacingCharacters(in: range, with: toggle(line)), cursor: cursor)
    }

    /// Whether `offset` (a UTF-16 offset into `text`) sits on a marker, that
    /// is at position 0 or 1 of an item line.
    static func isOnMarker(in text: String, at offset: Int) -> Bool {
        let range = lineRange(in: text, at: offset)
        guard isItem((text as NSString).substring(with: range)) else { return false }
        return offset - range.location < markerLength
    }

    /// The Return key with `selection` about to be replaced by a line break.
    /// On an item with content, the list continues on a new line. On an
    /// empty item, the marker is removed and the list ends. On a plain line
    /// the answer is nil and the text view does what it always does.
    static func handleReturn(in text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        let range = lineRange(in: text, at: selection.location)
        let line = ns.substring(with: range)
        guard isItem(line) else { return nil }
        // Return with a selection deletes it and continues from there.
        let afterDeletion = ns.replacingCharacters(in: selection, with: "")
        let cursor = selection.location
        let remaining = (afterDeletion as NSString).substring(
            with: lineRange(in: afterDeletion, at: cursor))
        if content(remaining).trimmingCharacters(in: .whitespaces).isEmpty {
            let lineStart = lineRange(in: afterDeletion, at: cursor).location
            let ended = (afterDeletion as NSString).replacingCharacters(
                in: NSRange(location: lineStart, length: remaining.utf16.count), with: "")
            return Edit(text: ended, cursor: lineStart)
        }
        let insertion = "\n" + open
        let continued = (afterDeletion as NSString).replacingCharacters(
            in: NSRange(location: cursor, length: 0), with: insertion)
        return Edit(text: continued, cursor: cursor + insertion.utf16.count)
    }
}
