import SwiftUI

/// The Notes tab: quick thoughts, typed here or spoken ("note: pick
/// up the parcel"). Newest first, gone with one click when done.
struct NotesView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var notes: NotesStore
    @Environment(\.moaiAccent) private var accent

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    init(model: NotchViewModel) {
        self.model = model
        self.notes = model.notes
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            addRow
            if notes.notes.isEmpty {
                EmptyPaneHint(message: "Jot a thought here, or say \"note: something\".")
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(notes.notes) { note in
                            NoteRow(note: note, model: model, notes: notes)
                        }
                    }
                }
            }
        }
        .animation(Theme.Motion.content, value: notes.notes)
    }

    private var addRow: some View {
        HStack(spacing: Theme.Space.m) {
            TextField("A thought to keep", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .focused($fieldFocused)
                .onSubmit(commit)
            Button(action: commit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.Fonts.icon(.l))
                    .foregroundStyle(draft.isEmpty ? Theme.textTertiary : accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(draft.isEmpty)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .moaiField(active: fieldFocused)
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.add(text)
        draft = ""
    }
}

/// One note: the thought, when it landed, and quiet actions that
/// wake on hover.
private struct NoteRow: View {
    let note: NotesStore.Note
    let model: NotchViewModel
    let notes: NotesStore

    @Environment(\.moaiAccent) private var accent
    @State private var hovered = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.text)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(Self.dateFormatter.string(from: note.date))
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(Theme.textGhost)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                IconActionButton(symbol: "sparkles", tint: accent) {
                    model.askAbout(name: "note", text: note.text)
                }
                IconActionButton(symbol: "xmark", dim: true) {
                    notes.remove(note)
                }
            }
            .opacity(hovered ? 1 : 0.6)
        }
        .rowInsets()
        .moaiCard(radius: Theme.Radius.row)
        .hoverHighlight(radius: Theme.Radius.row)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}
