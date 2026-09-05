import SwiftData
import SwiftUI
import UIKit

/// The home screen: title, search, the notes, and the pen.
struct NotesListView: View {
    @Environment(\.modelContext) private var context
    @Environment(Navigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]

    @State private var query = ""
    @State private var isSearching = false
    @State private var showWidgetHint = false
    @AppStorage("didShowWidgetHint") private var didShowWidgetHint = false
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// Pinned first, then newest edit first.
    private var visible: [Note] {
        let filtered = trimmedQuery.isEmpty
            ? Array(notes)
            : notes.filter { NoteText.matches($0.text, query: trimmedQuery) }
        return filtered.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            ZStack(alignment: .bottomTrailing) {
                Theme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    if !isSearching {
                        Text("Notes")
                            .font(Theme.Font.screenTitle)
                            .tracking(Theme.Font.screenTitleTracking)
                            .foregroundStyle(Theme.fg)
                            .padding(.horizontal, Theme.pagePadding)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                    }
                    searchBar
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.top, isSearching ? 8 : 0)
                        .padding(.bottom, 12)
                    content
                }
                composeButton
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                if let note = NoteStore.note(withID: id, in: context) {
                    EditorView(note: note)
                } else {
                    MissingNoteView()
                }
            }
        }
        .sheet(isPresented: $showWidgetHint) {
            WidgetHintView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { NoteStore.syncPinnedRecord(in: context) }
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(isSearching ? Theme.fg : Theme.muted)
                TextField("", text: $query, prompt: Text("Search").foregroundStyle(Theme.faint))
                    .font(Theme.Font.rowBody)
                    .foregroundStyle(Theme.fg)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: searchFocused) { _, focused in
                        if focused { withAnimation(.easeOut(duration: 0.2)) { isSearching = true } }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.muted)
                            .frame(width: Theme.tapTarget, height: Theme.tapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, query.isEmpty ? 12 : 0)
            .frame(height: Theme.searchHeight)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.searchRadius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }

            if isSearching {
                Button("Cancel") { cancelSearch() }
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.fg)
                    .frame(height: Theme.tapTarget)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private func cancelSearch() {
        query = ""
        searchFocused = false
        withAnimation(.easeOut(duration: 0.2)) { isSearching = false }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let rows = visible
        if notes.isEmpty {
            Text("No notes yet. Tap the pen to write one.")
                .font(Theme.Font.rowBody)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if !trimmedQuery.isEmpty, rows.isEmpty {
            Text("No matches.")
                .font(Theme.Font.rowBody)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            List {
                if !trimmedQuery.isEmpty {
                    Text(rows.count == 1 ? "1 note" : "\(rows.count) notes")
                        .font(Theme.Font.label)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.bottom, 4)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.bg)
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { note in
                    NoteRow(note: note, highlight: trimmedQuery, isLast: note.id == rows.last?.id)
                        .contentShape(Rectangle())
                        .onTapGesture { open(note) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Theme.bg)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                NoteStore.delete(note, in: context)
                            } label: {
                                // A rendered image keeps its own colour, which
                                // is the only way to get black text on the
                                // white block: swipe actions paint any Text
                                // label white over the tint.
                                Image(uiImage: TextImage.render("Delete"))
                                    .renderingMode(.original)
                            }
                            .tint(Theme.fg)
                            .accessibilityLabel("Delete")
                        }
                        .contextMenu {
                            Button {
                                togglePin(note)
                            } label: {
                                Label(note.isPinned ? "Unpin" : "Pin to Lock Screen",
                                      systemImage: note.isPinned ? "pin.slash" : "pin")
                            }
                            Button(role: .destructive) {
                                NoteStore.delete(note, in: context)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                // Room so the last row clears the compose button.
                Color.clear
                    .frame(height: Theme.composeSize + 48)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Theme.bg)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var composeButton: some View {
        Button {
            let note = NoteStore.create(in: context)
            searchFocused = false
            navigation.open(note.id)
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.bg)
                .frame(width: Theme.composeSize, height: Theme.composeSize)
                .background(Theme.fg, in: Circle())
        }
        .buttonStyle(PressedButtonStyle())
        .padding(.trailing, Theme.pagePadding)
        .padding(.bottom, 24)
        .accessibilityLabel("New note")
    }

    private func open(_ note: Note) {
        searchFocused = false
        navigation.open(note.id)
    }

    private func togglePin(_ note: Note) {
        NoteStore.togglePin(note, in: context)
        if note.isPinned, !didShowWidgetHint {
            didShowWidgetHint = true
            showWidgetHint = true
        }
    }
}

/// Shown when a deep link names a note that no longer exists.
private struct MissingNoteView: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Text("That note is gone.")
                .font(Theme.Font.rowBody)
                .foregroundStyle(Theme.muted)
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

/// White fills dim to `field` grey while pressed; the only pressed state.
struct PressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Renders a word as an image so a swipe action can show it in black.
enum TextImage {
    static func render(_ string: String) -> UIImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: UIColor.black,
        ]
        let size = (string as NSString).size(withAttributes: attributes)
        let bounds = CGSize(width: ceil(size.width), height: ceil(size.height))
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: bounds, format: format).image { _ in
            (string as NSString).draw(at: .zero, withAttributes: attributes)
        }
    }
}
