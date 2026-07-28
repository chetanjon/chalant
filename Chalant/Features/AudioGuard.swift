import Foundation
import os

/// The audio calls that kill the process instead of failing.
///
/// `AVAudioEngine` reports a whole family of misuse by raising an
/// Objective-C exception, and Swift has no `catch` that sees one: the
/// process dies where it stands. A second tap on an occupied bus is the
/// one that actually killed this app, but a format the graph cannot
/// take, a node that was never attached, and a buffer scheduled against
/// the wrong format all end the same way.
///
/// Guarding is not the same as recovering. A raised exception means the
/// framework abandoned an operation partway, so its state has to be
/// assumed wrong afterwards: every caller here tears the engine down and
/// says so, rather than carrying on as though the call merely returned
/// false.
enum AudioGuard {
    static let log = Logger(subsystem: "com.cj.chalant", category: "audio")

    struct Failure: Error {
        /// The exception's name, e.g. NSInternalInconsistencyException.
        var name: String
        /// The framework's own words, e.g. "required condition is
        /// false: nullptr == Tap()".
        var reason: String
        /// Which call raised, so the log names the site and not just
        /// the symptom.
        var during: String

        var localizedDescription: String { "\(during): \(name), \(reason)" }
    }

    /// Run `body`, turning a raised exception into a thrown `Failure`.
    static func attempt(_ during: String, _ body: () -> Void) throws {
        do {
            try CHExceptionCatcher.run(body)
        } catch let error as NSError {
            let failure = Failure(
                name: error.userInfo[CHExceptionNameKey] as? String ?? "NSException",
                reason: error.localizedDescription,
                during: during
            )
            log.error(
                "\(during, privacy: .public) raised \(failure.name, privacy: .public): \(failure.reason, privacy: .public)")
            throw failure
        }
    }

    /// Run `body` and report whether it survived, for the paths where
    /// there is nothing to say to the user and nothing to unwind.
    @discardableResult
    static func succeeds(_ during: String, _ body: () -> Void) -> Bool {
        do {
            try attempt(during, body)
            return true
        } catch {
            return false
        }
    }
}
