import SwiftUI

/// One note in the list: title, then time and preview on a line, and a rule
/// underneath. Search matches are marked white on black.
struct NoteRow: View {
    let note: Note
    /// The search query to highlight, or empty.
    var highlight: String = ""
    var isLast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marked(note.title, base: Theme.fg))
                    .font(Theme.Font.rowTitle)
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.fg)
                        .accessibilityLabel("Pinned")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DateFormat.when(note.updatedAt))
                    .font(Theme.Font.rowBody)
                    .monospacedDigit()
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                    .fixedSize()
                Text(marked(note.preview, base: Theme.muted))
                    .font(Theme.Font.rowBody)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, Theme.rowPadding)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if !isLast {
                Theme.rule
                    .frame(height: 1)
                    .padding(.horizontal, Theme.pagePadding)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The text with every occurrence of the query in white on black, in the
    /// style of an HTML `mark`.
    private func marked(_ string: String, base: Color) -> AttributedString {
        var attributed = AttributedString(string)
        attributed.foregroundColor = base
        let query = highlight.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = Theme.fg
            attributed[range].foregroundColor = Theme.bg
            searchStart = range.upperBound
        }
        return attributed
    }
}
