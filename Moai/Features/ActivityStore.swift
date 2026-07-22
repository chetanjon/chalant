import Foundation

/// Live status for things with no home: agent runs, deploys, renders,
/// long downloads. Anything local can push "working / needs input /
/// done" through the ActivityServer and the island wears it. Upserts
/// are keyed by caller-chosen id; finished states clear themselves.
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
            // The oldest finished thing goes first; never drop live work.
            if let victim = activities.last(where: { $0.state == .done || $0.state == .failed })
                ?? activities.last {
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

    /// What the collapsed island should say: the most urgent thing.
    var glanceActivity: Activity? {
        activities.first
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
