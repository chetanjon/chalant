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

    func push(id: String, title: String, detail: String?, state: State) {
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
