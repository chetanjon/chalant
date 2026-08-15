import Foundation

/// How dictated text should read in one particular app (M6).
///
/// A Slack message, a commit message, an email and a code comment are not the
/// same shape, and every competitor treats them the same. Keyed by bundle ID.
public struct AppProfile: Sendable, Hashable {
    /// The register the text should be written in.
    public enum Register: String, Sendable, CaseIterable {
        /// Chat: short, no trailing period, few commas. Part 0 §0.17 notes
        /// commas are the weak class, and short-message registers need few.
        case message
        /// Mail and documents: full sentences, paragraphs.
        case prose
        /// Terminals and editors: no auto-capitalisation, identifiers intact.
        case code
    }

    public let bundleID: String
    public var register: Register
    /// Whether the optional Foundation Models pass may run here at all.
    public var allowsPolish: Bool
    /// Constrained command grammar rather than free dictation (M6, Part 0
    /// §0.19: free dictation is agreed to fail for code).
    public var codeMode: Bool
    /// Set when a tier has failed here before, so insertion demotes rather
    /// than retrying a path this app is known to refuse (M1). Holds the
    /// BEST tier still allowed, so a larger number is a worse ladder.
    public var maxInsertionTier: Int?
    /// Consecutive failures per tier, keyed by `InsertionTier.rawValue`.
    /// Reset by a success, so demotion needs a genuine streak.
    public var consecutiveFailures: [Int: Int]

    public init(
        bundleID: String,
        register: Register = .prose,
        allowsPolish: Bool = true,
        codeMode: Bool = false,
        maxInsertionTier: Int? = nil,
        consecutiveFailures: [Int: Int] = [:]
    ) {
        self.bundleID = bundleID
        self.register = register
        self.allowsPolish = allowsPolish
        self.codeMode = codeMode
        self.maxInsertionTier = maxInsertionTier
        self.consecutiveFailures = consecutiveFailures
    }
}
