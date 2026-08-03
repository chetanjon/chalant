import Foundation
import os

/// Live status for things with no home: agent runs, deploys, renders,
/// long downloads. Anything local can push "working / needs input /
/// done" through the ActivityServer; the OPEN island lists it all,
/// attention first. The closed pill never grows for any of it: an
/// outside process does not get to resize the hardware (user,
/// 2026-07-23, after two rounds of narrowing). Upserts are keyed by
/// caller-chosen id; finished states clear themselves.
@MainActor
final class ActivityStore: ObservableObject {
    enum State: String, Codable {
        case working
        case needsInput = "needs-input"
        case done
        case failed

        var symbol: String {
            switch self {
            case .working: return "circle.dashed"
            case .needsInput: return "exclamationmark.circle.fill"
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            }
        }
    }

    struct Activity: Identifiable, Equatable {
        let id: String
        var title: String
        var detail: String?
        var state: State
        var startedAt: Date
        var updatedAt: Date
    }

    /// Attention first: needs-input, then working, then the finished,
    /// each newest first. Views render straight through.
    @Published private(set) var activities: [Activity] = []

    private static let log = Logger(subsystem: "com.cj.chalant", category: "activities")

    private let maxActivities = 8
    /// Finished states linger just long enough to be seen.
    private let finishedTTL: TimeInterval = 60
    private var expiryWork: [String: DispatchWorkItem] = [:]

    /// Fired when a row arrives, or turns, into needs-input.
    ///
    /// This is the path the Claude Code hook actually uses. A stopping
    /// session posts an activity, not a question, so wiring the
    /// announcement only to `SessionStore.attach` left the common case
    /// silent: the pill appeared in the open island and the collapsed
    /// one said nothing at all (founder, 2026-08-02, "I didn't get a
    /// notification that it stopped working" - verified by pushing one
    /// from the CLI and watching the island not react).
    var onNeedsInput: ((String) -> Void)?

    func push(id: String, title: String, detail: String?, state: State) {
        let wasAlreadyAsking = activities.first { $0.id == id }?.state == .needsInput
        var activity = activities.first { $0.id == id }
            ?? Activity(
                id: id, title: title, detail: detail,
                state: state, startedAt: Date(), updatedAt: Date()
            )
        activity.title = title
        activity.detail = detail
        activity.state = state
        activity.updatedAt = Date()
        activities.removeAll { $0.id == id }
        activities.append(activity)
        sort()
        // Only on the way in, for the same reason the session path is:
        // a row re-pushed while already asking is the same ask, and
        // announcing it on every poll would train anyone to ignore it.
        if state == .needsInput, !wasAlreadyAsking { onNeedsInput?(title) }
        if activities.count > maxActivities {
            // Finished rows go first, then the stalest working one.
            //
            // A needs-input row is a question waiting on the user, and
            // nothing re-pushes it: dropping one loses something nobody
            // can get back. The old fallback here was `activities.last`,
            // which — because needs-input sorts FIRST — is exactly that
            // row once every slot is a question. Nine outstanding
            // questions and the tenth push silently ate one. The cap
            // yields instead; a list one row long is the cheaper failure.
            let victim = activities.last { $0.state == .done || $0.state == .failed }
                ?? activities.last { $0.state == .working }
            if let victim {
                Self.log.notice(
                    "activity list full, dropping \(victim.id, privacy: .public)")
                clear(id: victim.id)
            }
        }
        expiryWork[id]?.cancel()
        if state == .done || state == .failed {
            let work = DispatchWorkItem { [weak self] in self?.clear(id: id) }
            expiryWork[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + finishedTTL, execute: work)
        }
    }

    func clear(id: String) {
        expiryWork[id]?.cancel()
        expiryWork[id] = nil
        activities.removeAll { $0.id == id }
    }

    /// Resolves a needs-input pill whose session has since ended,
    /// rather than leaving it looking actionable forever (H5, founder
    /// 2026-08-02: pills from sessions long gone, clickable only into
    /// "that session is no longer running").
    ///
    /// Reuses `.failed` instead of clearing outright: an unanswered
    /// question is information, not nothing, so it gets to be seen once
    /// more, no longer claiming to be at the top of the list, before it
    /// clears itself on the same timer every other finished row uses.
    /// Silent deletion was the other option and was rejected for the
    /// same reason `SessionStore` never claims `.done` for a session it
    /// only knows stopped reporting — this store cannot claim the
    /// question was answered either, only that it no longer can be.
    /// A no-op for anything not currently asking, so a late call after
    /// the row already resolved or expired changes nothing.
    func resolveIfPending(id: String) {
        guard let index = activities.firstIndex(where: { $0.id == id }),
              activities[index].state == .needsInput
        else { return }
        push(id: id, title: activities[index].title,
             detail: "The session behind this ended before it was answered.",
             state: .failed)
    }

    func clearAll() {
        activities.map(\.id).forEach { clear(id: $0) }
    }

    private func sort() {
        func rank(_ state: State) -> Int {
            switch state {
            case .needsInput: return 0
            case .working: return 1
            case .failed: return 2
            case .done: return 3
            }
        }
        activities.sort {
            rank($0.state) != rank($1.state)
                ? rank($0.state) < rank($1.state)
                : $0.updatedAt > $1.updatedAt
        }
    }
}
