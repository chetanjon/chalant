import Foundation

/// Everything the app derives from a note's text: its title, its preview,
/// its checklist tally. Pure functions on a `String`, so the `Note` model
/// stays a thin wrapper and all of this is testable without SwiftData.
enum NoteText {
    static let untitled = "New note"

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The first non-empty line, marker stripped. "New note" when there is none.
    static func title(_ text: String) -> String {
        lines(text)
            .map { Checklist.content($0).trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? untitled
    }

    /// Every line after the first.
    static func bodyLines(_ text: String) -> [String] {
        Array(lines(text).dropFirst())
    }

    static func isChecklist(_ text: String) -> Bool {
        bodyLines(text).contains(where: Checklist.isItem)
    }

    struct Summary: Equatable {
        var done: Int
        var total: Int
        var open: [String]
    }

    /// Counts the items in the body. `open` holds the open items' text, in order.
    static func checklistSummary(_ text: String) -> Summary {
        var summary = Summary(done: 0, total: 0, open: [])
        for line in bodyLines(text) where Checklist.isItem(line) {
            summary.total += 1
            if Checklist.isDone(line) {
                summary.done += 1
            } else {
                let item = Checklist.content(line).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { summary.open.append(item) }
            }
        }
        return summary
    }

    /// The single line under a title in the list.
    ///
    /// Plain note: every line after the first, joined with spaces. Checklist:
    /// `"1/4 done · eggs, milk"`, or `"All done"`.
    static func preview(_ text: String) -> String {
        if isChecklist(text) {
            let s = checklistSummary(text)
            if s.done == s.total { return "All done" }
            return "\(s.done)/\(s.total) done · \(s.open.joined(separator: ", "))"
        }
        return bodyLines(text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// What the widget shows under the title: the first line of the body,
    /// or `"2/5 · milk, eggs"` for a checklist.
    static func widgetPreview(_ text: String) -> String {
        if isChecklist(text) {
            let s = checklistSummary(text)
            if s.done == s.total { return "All done" }
            return "\(s.done)/\(s.total) · \(s.open.joined(separator: ", "))"
        }
        return bodyLines(text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    /// Only whitespace and bare markers. Such a note is discarded on dismiss.
    static func isBlank(_ text: String) -> Bool {
        lines(text).allSatisfy {
            Checklist.content($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Case-insensitive search over the whole text.
    static func matches(_ text: String, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
