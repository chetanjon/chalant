import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Go tab: a quiet grid of user-defined shortcuts, websites,
/// apps, folders, and built-in actions. Click to launch and the
/// island slips shut.
struct ShortcutsView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: ShortcutStore
    @Environment(\.moaiAccent) private var accent

    @State private var adding = false
    @State private var draftTitle = ""
    @State private var draftLink = ""
    @FocusState private var linkFieldFocused: Bool

    init(model: NotchViewModel) {
        self.model = model
        self.store = model.shortcuts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if adding {
                addRow
                quickAddRow
            }
            if store.shortcuts.isEmpty && !adding {
                EmptyPaneHint(message: "Save the places you jump to, sites, apps, folders.") {
                    Button {
                        beginAdding()
                    } label: {
                        Text("Add a shortcut")
                            .font(Theme.Fonts.label)
                            .foregroundStyle(accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 96), spacing: Theme.Space.m)],
                        spacing: Theme.Space.m
                    ) {
                        ForEach(store.shortcuts) { shortcut in
                            ShortcutChip(shortcut: shortcut, store: store) {
                                if store.open(shortcut) {
                                    model.collapse()
                                } else {
                                    // Silence reads as broken; say it.
                                    model.collapse()
                                    model.flashGlance("Couldn't open \(shortcut.title)")
                                }
                            }
                        }
                        if !adding {
                            addChip
                        }
                    }
                }
            }
        }
        .animation(Theme.Motion.content, value: adding)
        .animation(Theme.Motion.content, value: store.shortcuts)
        .onChange(of: model.wantsShortcutAdd) { _, wants in
            if wants {
                beginAdding()
                model.wantsShortcutAdd = false
            }
        }
        // The flag can flip before this pane mounts (tab switch and
        // request arrive together); consume it on arrival too.
        .onAppear {
            if model.wantsShortcutAdd {
                beginAdding()
                model.wantsShortcutAdd = false
            }
        }
    }

    private var addChip: some View {
        Button {
            beginAdding()
        } label: {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(Theme.Fonts.icon(.l, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
                Text("Add")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.l)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Theme.hairlineFaint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight()
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                TextField("App, website, or folder", text: $draftLink)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.body)
                    .focused($linkFieldFocused)
                    .onSubmit(commitAdd)
                Rectangle()
                    .fill(Theme.hairlineFaint)
                    .frame(width: 1, height: 16)
                TextField("Name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.body)
                    .frame(width: 92)
                    .onSubmit(commitAdd)
                Button(action: commitAdd) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Theme.Fonts.icon(.l))
                        .foregroundStyle(draftLink.isEmpty ? Theme.textTertiary : accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(draftLink.isEmpty)
                CloseButton {
                    adding = false
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            .moaiField(active: linkFieldFocused)
            Text("Try notes · github.com · ~/Documents")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textHint)
                .padding(.leading, Theme.Space.xs)
        }
    }

    /// The faster paths: every built-in is one tap away, and the
    /// caption says plainly that the tap adds it.
    private var quickAddRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("One tap adds:")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textHint)
                .padding(.leading, Theme.Space.xs)
            FlowLayout(spacing: Theme.Space.s) {
                ForEach(store.remainingActions, id: \.self) { action in
                    quickChip(title: action.title, symbol: action.symbol) {
                        store.add(action: action)
                        adding = false
                    }
                }
                quickChip(title: "Pick an app…", symbol: "macwindow") { pickApp() }
            }
        }
    }

    private func quickChip(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(Theme.Fonts.icon(.xs))
                Text(title)
                    .font(Theme.Fonts.caption)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: 22)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.hairlineFaint, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    /// Browse installed apps instead of typing a path.
    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Pick an app to add to Shortcuts"
        NSApp.activate(ignoringOtherApps: true)
        let store = self.store
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                store.add(title: "", link: url.path)
            }
        }
        adding = false
    }

    private func beginAdding() {
        draftTitle = ""
        draftLink = ""
        adding = true
        linkFieldFocused = true
    }

    private func commitAdd() {
        guard !draftLink.isEmpty else { return }
        store.add(title: draftTitle, link: draftLink)
        adding = false
    }
}

/// One launcher chip. Holds its own hover state, so the delete
/// affordance and highlight never bleed between chips.
private struct ShortcutChip: View {
    let shortcut: ShortcutStore.Shortcut
    let store: ShortcutStore
    let open: () -> Void

    @Environment(\.moaiAccent) private var accent
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: Theme.Space.s) {
                icon
                Text(shortcut.title)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    // Long names keep both ends: the start says what
                    // it is, the tail is where paths differ.
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.l)
            .moaiCard(radius: Theme.Radius.row)
            .hoverHighlight(radius: Theme.Radius.row)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button {
                    store.remove(shortcut)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(minWidth: 22, minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }

    private var icon: some View {
        Group {
            if let action = shortcut.action {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                    Image(systemName: action.symbol)
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(accent)
                }
                .frame(width: 26, height: 26)
            } else if let fileIcon = ShortcutStore.fileIcon(for: shortcut.link) {
                Image(nsImage: fileIcon)
                    .resizable()
                    .frame(width: 26, height: 26)
            } else {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                    Text(String(shortcut.title.prefix(1)).uppercased())
                        .font(Theme.Fonts.icon(.m))
                        .foregroundStyle(accent)
                }
                .frame(width: 26, height: 26)
            }
        }
        .scaleEffect(hovered ? 1.06 : 1)
    }
}
