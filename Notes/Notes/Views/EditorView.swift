import SwiftData
import SwiftUI

/// The editor: one text view, a 44pt bar above it. The first line is the
/// title. Every change autosaves after a short pause; Done only dismisses.
struct EditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let note: Note

    @State private var text: String
    @State private var isFocused: Bool
    @State private var command: ChecklistTextView.Command?
    @State private var confirmingDelete = false
    @State private var deleteTimer: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var showWidgetHint = false
    @AppStorage("didShowWidgetHint") private var didShowWidgetHint = false

    /// Autosave waits this long after the last keystroke.
    private static let saveDelay: Duration = .milliseconds(350)
    /// The trash button reverts from "Delete" after this long.
    private static let deleteWindow: Duration = .seconds(3)

    init(note: Note) {
        self.note = note
        _text = State(initialValue: note.text)
        // A new note opens with the keyboard up; an existing one waits for a tap.
        _isFocused = State(initialValue: note.isBlank)
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ChecklistTextView(text: $text, isFocused: $isFocused, command: $command)
                .padding(.horizontal, Theme.pagePadding - 5)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: text) { _, newValue in
            scheduleSave(newValue)
        }
        .onChange(of: note.text) { _, synced in
            // Another device edited this note while it was open.
            if synced != text, saveTask == nil { text = synced }
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            deleteTimer?.cancel()
            if NoteText.isBlank(text) {
                NoteStore.delete(note, in: context)
            } else {
                NoteStore.update(note, text: text, in: context)
            }
        }
        .sheet(isPresented: $showWidgetHint) {
            WidgetHintView()
        }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 0) {
            barButton("chevron.left", label: "Back") { dismiss() }
            Spacer()
            barButton("checklist", label: "Checklist") { command = .toggleItem }
            barButton(note.isPinned ? "pin.fill" : "pin",
                      label: note.isPinned ? "Unpin" : "Pin to Lock Screen") { togglePin() }
            if confirmingDelete {
                Button {
                    deleteNow()
                } label: {
                    Text("Delete")
                        .font(Theme.Font.toolbar)
                        .foregroundStyle(Theme.fg)
                        .frame(height: Theme.tapTarget)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                barButton("trash", label: "Delete") { armDelete() }
            }
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(Theme.Font.toolbar)
                    .foregroundStyle(Theme.fg)
                    .frame(height: Theme.tapTarget)
                    .padding(.leading, 10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.pagePadding - 10)
        .frame(height: Theme.tapTarget)
        .background(Theme.bg)
        .animation(.easeOut(duration: 0.15), value: confirmingDelete)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.fg)
                .frame(width: Theme.tapTarget, height: Theme.tapTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func scheduleSave(_ value: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            NoteStore.update(note, text: value, in: context)
            saveTask = nil
        }
    }

    private func togglePin() {
        // Save first so the widget shows what is on screen, not what was.
        saveTask?.cancel()
        saveTask = nil
        NoteStore.update(note, text: text, in: context)
        NoteStore.togglePin(note, in: context)
        if note.isPinned, !didShowWidgetHint {
            didShowWidgetHint = true
            showWidgetHint = true
        }
    }

    /// First tap: the icon becomes the word. A second tap within three
    /// seconds deletes; otherwise it reverts. No system alert.
    private func armDelete() {
        confirmingDelete = true
        deleteTimer?.cancel()
        deleteTimer = Task { @MainActor in
            try? await Task.sleep(for: Self.deleteWindow)
            guard !Task.isCancelled else { return }
            confirmingDelete = false
        }
    }

    private func deleteNow() {
        deleteTimer?.cancel()
        saveTask?.cancel()
        saveTask = nil
        // Blank it so onDisappear finds nothing to save and discards it.
        text = ""
        dismiss()
    }
}
