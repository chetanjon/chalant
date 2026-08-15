import Foundation

/// Persistence seam for the learned vocabulary (Part 2 §7, GRDB behind it).
///
/// `Core` never sees SQLite. The four verbs are named in Part 2 §3; the
/// signatures below are this scaffold's reading of them and are reported as
/// an open decision.
public protocol TermRepository: Sendable {
    func fetch() async throws -> [Term]
    func upsert(_ term: Term) async throws
    /// Bumps use count and last-used, which feed recency decay in `BiasSelector`.
    func recordUse(_ termID: UUID, at when: Date) async throws
    /// Records an observed heard/meant pair. Part 3 M5 requires count >= 2
    /// before a substitution ever fires, and Part 0 §0.15 requires every
    /// learned pair to stay inspectable and reversible.
    func recordConfusion(_ confusion: Confusion) async throws
}
