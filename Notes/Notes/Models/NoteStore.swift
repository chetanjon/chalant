import Foundation
import SwiftData

/// The few operations that touch more than one note or reach outside the
/// model context: creating, deleting, pinning. Views call these instead of
/// editing the context directly so the pin invariant and the widget record
/// are kept in one place.
enum NoteStore {
    /// The container the app runs on. CloudKit when the entitlement is
    /// there, local storage when it is not, so a free-account build that
    /// cannot carry the iCloud capability still opens.
    static func makeContainer() -> ModelContainer {
        let schema = Schema([Note.self])
        let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
            return container
        }
        let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            fatalError("Could not open the notes store: \(error)")
        }
    }

    @discardableResult
    static func create(in context: ModelContext) -> Note {
        let note = Note()
        context.insert(note)
        save(context)
        return note
    }

    static func delete(_ note: Note, in context: ModelContext) {
        let wasPinned = note.isPinned
        context.delete(note)
        save(context)
        if wasPinned { PinStore.write(nil) }
    }

    /// Records an edit. Called by the editor's autosave.
    static func update(_ note: Note, text: String, in context: ModelContext) {
        guard note.text != text else { return }
        note.text = text
        note.updatedAt = .now
        save(context)
        if note.isPinned { PinStore.write(note.pinned) }
    }

    /// Only one note is pinned at a time; pinning a new one unpins the old.
    static func togglePin(_ note: Note, in context: ModelContext) {
        let wasPinned = note.isPinned
        let all = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        for other in all where other.isPinned { other.isPinned = false }
        note.isPinned = !wasPinned
        save(context)
        PinStore.write(note.isPinned ? note.pinned : nil)
    }

    /// After a sync, another device may have pinned a different note. Make
    /// the widget agree with the store.
    static func syncPinnedRecord(in context: ModelContext) {
        let pinned = try? context.fetch(
            FetchDescriptor<Note>(predicate: #Predicate { $0.isPinned })).first
        let record = pinned?.pinned
        if PinStore.read() != record { PinStore.write(record) }
    }

    static func note(withID id: UUID, in context: ModelContext) -> Note? {
        try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first
    }

    private static func save(_ context: ModelContext) {
        do { try context.save() } catch { assertionFailure("Save failed: \(error)") }
    }
}
