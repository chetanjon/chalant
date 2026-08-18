import ChalantDictationCore
import SwiftUI

/// The names Chalant knows: what it worked out about the way you say your own
/// words, and what you told it outright.
///
/// **This view is the reason the learner is allowed to run at all.** Part 0
/// §0.15 requires every learned pair to be inspectable and reversible, and the
/// reason is not tidiness: a wrong pair rewrites one of the user's words on
/// every future utterance, so without a way to see it and delete it the feature
/// is a permanent bug nobody can reach.
///
/// The typed names ("Add a name") sit in the same list because to the user they
/// are the same thing: names Chalant spells right. They are `Vocabulary`, the
/// list both ears read first, and each is spelled exactly as typed.
///
/// Law 5 of the design constitution, "a control appears only when it can do
/// something", is why there is no empty state to speak of: a fresh install has
/// learned nothing, and a list of nothing is furniture. The one control that is
/// always here is the box to add a name, because it can always do something.
struct LearnedTermsList: View {
    @State private var entries: [Entry] = []
    @State private var typed: [String] = []
    @State private var draft = ""

    /// Flattened out of the actor so the view holds plain values, and given an
    /// identity that survives a reload so rows do not animate as replacements.
    private struct Entry: Identifiable, Equatable {
        let pair: Correction.Pair
        let sightings: Int
        var id: String { pair.heard + "\u{2192}" + pair.meant }
    }

    var body: some View {
        // One root with one `.task`. Putting the load inside both arms of a
        // conditional means it runs again the moment the list stops being
        // empty, which is a second read of the store for no reason.
        VStack(alignment: .leading, spacing: 0) {
            // Law 5: a control appears only when it can do something. A fresh
            // install has learned nothing, and a list of nothing is furniture.
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                // Law 2: air separates and lines are a last resort, but a
                // settings list row is the one place a hairline survives.
                if index > 0 { SettingDivider() }
                row(entry)
            }
            ForEach(Array(typed.enumerated()), id: \.element) { index, name in
                if index > 0 || !entries.isEmpty { SettingDivider() }
                typedRow(name)
            }
            if !entries.isEmpty || !typed.isEmpty { SettingDivider() }
            addRow
        }
        .task { await reload() }
    }

    /// A name you typed: the spelling that lands, and the way to take it back.
    private func typedRow(_ name: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(name)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.l)
            ForgetButton { forget(name) }
                .accessibilityLabel("Forget \(name)")
        }
        .padding(.vertical, Theme.Space.settingsRow)
    }

    /// The box. Same shape as the hook-rules box on the Agents page: a plain
    /// field in a hairline, a small bordered Add beside it, Return adds too.
    private var addRow: some View {
        HStack(spacing: Theme.Space.s) {
            TextField("Add a name", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .onSubmit(add)
                .padding(Theme.Space.m)
                .chalantField()
                .accessibilityLabel("Add a name")
            Button("Add", action: add)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.controlTint)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.vertical, Theme.Space.s)
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: Theme.Space.m) {
            // The misheard word is the dim half and the right one is white.
            // Law 1: active is white, inactive is dim, and no capsule behind
            // either of them.
            Text(entry.pair.heard)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textTertiary)

            Image(systemName: "arrow.right")
                .font(Theme.Fonts.iconThin(.xs))
                .foregroundStyle(Theme.textGhost)

            Text(entry.pair.meant)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: Theme.Space.l)

            // Law 4: numbers are monospace.
            Text("\(entry.sightings)")
                .font(Theme.Fonts.timeMono)
                .foregroundStyle(Theme.textGhost)
                .accessibilityLabel("corrected \(entry.sightings) times")

            ForgetButton {
                Task { await forget(entry.pair) }
            }
            .accessibilityLabel("Forget \(entry.pair.meant)")
        }
        .padding(.vertical, Theme.Space.settingsRow)
    }

    private func reload() async {
        let everything = await LearnedTerms.shared.everything()
        entries = everything.map { Entry(pair: $0.pair, sightings: $0.sightings) }
        typed = Vocabulary.terms()
    }

    private func forget(_ pair: Correction.Pair) async {
        await LearnedTerms.shared.forget(pair)
        await reload()
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Vocabulary.add(name)
        draft = ""
        typed = Vocabulary.terms()
    }

    private func forget(_ name: String) {
        Vocabulary.remove(name)
        typed = Vocabulary.terms()
    }
}

/// The names in Contacts, and where Chalant stands with them.
///
/// Three states, one row each, per law 5: when macOS has not been asked, the
/// ask, in words; when it said yes, what that bought (how many names); when it
/// said no, where to change that. No switch of its own, per law 6: the
/// permission is the switch, and it lives where macOS keeps it.
struct ContactsNamesRow: View {
    @State private var status = ContactNames.status
    @State private var count = 0

    var body: some View {
        Group {
            switch status {
            case .authorized:
                SettingNote(
                    count == 0
                        ? "It can read the names in your Contacts too, but there are none it does not already know."
                        : "It also knows the \(count) names in your Contacts. Read on this Mac, kept nowhere."
                )
            case .notDetermined:
                Button("Use the names in Contacts") {
                    Task {
                        _ = await ContactNames.ask()
                        await refresh()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(Theme.controlTint)
                SettingNote("Names only, read on this Mac, kept nowhere. macOS asks first.")
            default:
                SettingNote(
                    "Contacts is off for Chalant, so it cannot read the names there. "
                    + "System Settings, Privacy and Security, Contacts."
                )
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        status = ContactNames.status
        count = await ContactNames.shared.pool().count
    }
}

/// Dim until you reach for it. No capsule, per law 1: this is a real action, but
/// a glyph that lights is quieter than a button that sits there asking.
private struct ForgetButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(Theme.Fonts.iconThin(.xs))
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textGhost)
                .contentShape(Rectangle())
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
