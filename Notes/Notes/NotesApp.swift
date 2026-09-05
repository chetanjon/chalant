import SwiftData
import SwiftUI

@main
struct NotesApp: App {
    private let container = NoteStore.makeContainer()
    @State private var navigation = Navigation()

    var body: some Scene {
        WindowGroup {
            NotesListView()
                .environment(navigation)
                .preferredColorScheme(.dark)
                .tint(Theme.fg)
                .onOpenURL { url in
                    // notes://note/<uuid>, from the widget.
                    guard let id = PinStore.noteID(from: url) else { return }
                    navigation.open(id)
                }
        }
        .modelContainer(container)
    }
}

/// Which note is open. The list owns the navigation path; the app sets it
/// from a deep link; the widget's URL lands here.
@Observable
final class Navigation {
    var path: [UUID] = []

    func open(_ id: UUID) {
        path = [id]
    }
}
