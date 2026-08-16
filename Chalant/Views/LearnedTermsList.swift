import ChalantDictationCore
import SwiftUI

/// What Chalant has worked out about the way you say your own words.
///
/// **This view is the reason the learner is allowed to run at all.** Part 0
/// §0.15 requires every learned pair to be inspectable and reversible, and the
/// reason is not tidiness: a wrong pair rewrites one of the user's words on
/// every future utterance, so without a way to see it and delete it the feature
/// is a permanent bug nobody can reach.
///
/// Law 5 of the design constitution, "a control appears only when it can do
/// something", is why there is no empty state to speak of: a fresh install has
/// learned nothing, and a list of nothing is furniture.
struct LearnedTermsList: View {
    @State private var entries: [Entry] = []

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
        }
        .task { await reload() }
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
    }

    private func forget(_ pair: Correction.Pair) async {
        await LearnedTerms.shared.forget(pair)
        await reload()
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
