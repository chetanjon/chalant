import Foundation
import SwiftData

/// A note is its text. The first line is the title; there is no separate
/// field for it. `isPinned` is true on at most one note, enforced in
/// `NoteStore.togglePin`, never by the schema.
///
/// Every property has a default and none is unique, because CloudKit
/// requires the first and refuses the second.
@Model
final class Note {
    var id: UUID = UUID()
    var text: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var isPinned: Bool = false

    init(text: String = "") {
        id = UUID()
        self.text = text
        createdAt = .now
        updatedAt = .now
        isPinned = false
    }
}

extension Note {
    var title: String { NoteText.title(text) }
    var bodyLines: [String] { NoteText.bodyLines(text) }
    var isChecklist: Bool { NoteText.isChecklist(text) }
    var checklistSummary: NoteText.Summary { NoteText.checklistSummary(text) }
    var preview: String { NoteText.preview(text) }
    var isBlank: Bool { NoteText.isBlank(text) }

    var pinned: PinStore.Pinned {
        PinStore.Pinned(id: id, title: title, preview: NoteText.widgetPreview(text), updatedAt: updatedAt)
    }
}
