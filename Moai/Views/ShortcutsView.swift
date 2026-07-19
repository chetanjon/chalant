import SwiftUI

/// The Go tab: a quiet grid of user-defined shortcuts — websites,
/// apps, folders. Click to launch and the island slips shut.
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
            }
            if store.shortcuts.isEmpty && !adding {
                VStack {
                    Spacer()
                    Text("Save the places you jump to — sites, apps, folders.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textHint)
                    Button {
                        beginAdding()
                    } label: {
                        Text("Add a shortcut")
                            .font(Theme.Fonts.label)
                            .foregroundStyle(accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, Theme.Space.xs)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
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
        HStack(spacing: Theme.Space.m) {
            TextField("Name (optional)", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .frame(width: 110)
            TextField("github.com, /Applications/…, ~/folder", text: $draftLink)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .focused($linkFieldFocused)
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
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.l)
            .moaiCard(radius: Theme.Radius.row)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.03 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovered ? 0.10 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            )
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
            if let fileIcon = ShortcutStore.fileIcon(for: shortcut.link) {
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
