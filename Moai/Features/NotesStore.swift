import Foundation

@MainActor
final class NotesStore: ObservableObject {
    struct Note: Identifiable, Codable, Equatable {
        var id = UUID()
        let text: String
        let date: Date
    }

    @Published private(set) var notes: [Note] = [] {
        didSet { save() }
    }

    private let storageKey = "moai.notes"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Note].self, from: data) {
            notes = decoded
        }
    }

    func add(_ text: String) {
        notes.insert(Note(text: text, date: Date()), at: 0)
    }

    func remove(_ note: Note) {
        notes.removeAll { $0.id == note.id }
    }

    func clear() {
        notes = []
    }

    var rendered: String {
        guard !notes.isEmpty else {
            return "No notes yet. Type \"note: something\" to capture one."
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return notes
            .map { "• \($0.text)  (\(formatter.string(from: $0.date)))" }
            .joined(separator: "\n")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
