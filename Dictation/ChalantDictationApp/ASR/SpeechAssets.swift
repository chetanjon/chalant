import Foundation
import Speech
import os

/// Where the on-device language model for a locale currently stands.
///
/// Part 0 §0.6 is emphatic that this is a state machine rather than setup
/// boilerplate: valid locales throw `SFSpeechErrorDomain Code=10`, assets get
/// stuck "downloading", `supportedLocale` returns nil for hyphen/underscore
/// mismatches, and per an Apple engineer **the OS may delete shared language
/// model assets under disk pressure**. So "it worked last launch" proves
/// nothing and every session start is gated afresh.
enum SpeechAssetState: Sendable, Equatable {
    case checking
    /// No model exists for this locale on this OS. Terminal.
    case unsupported(requested: String)
    /// Installing. `fraction` is 0...1 where the OS reports it.
    case downloading(fraction: Double)
    /// Ready. Carries the canonical locale, which may differ from the one asked for.
    case available(locale: Locale)
    /// Retryable.
    case failed(reason: String)

    var isReady: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Resolves and installs the speech assets for a locale.
///
/// M0's acceptance criterion depends on this: per §0.6 the milestone accepts
/// only if "not installed yet" is handled without a crash or a hang.
///
/// Gated to macOS 26 by the merge: Chalant ships a macOS 14 floor and promises
/// it publicly, while `SpeechTranscriber` and `AssetInventory` have no backport.
/// `SpeechAssetState` above stays ungated on purpose, so callers below 26 can
/// still describe why dictation is unavailable.
@available(macOS 26, *)
actor SpeechAssets {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "assets")

    private(set) var state: SpeechAssetState = .checking

    /// Bring `locale` to `.available`, or explain why not.
    ///
    /// Never throws: every failure becomes a state the UI can render, because
    /// a thrown error here would surface as a dead hotkey with no explanation.
    func ensure(locale requested: Locale) async -> SpeechAssetState {
        state = .checking

        // Canonicalise first. §0.6: hyphen/underscore locale-identity
        // mismatches are a real failure class, and the identifier the user
        // configured is not necessarily the one the framework knows.
        guard let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            Self.log.error("locale \(requested.identifier, privacy: .public) is not supported")
            state = .unsupported(requested: requested.identifier)
            return state
        }

        let module = SpeechTranscriber(locale: canonical, preset: .progressiveTranscription)

        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            state = .available(locale: canonical)

        case .unsupported:
            state = .unsupported(requested: canonical.identifier)

        case .supported, .downloading:
            state = await install(module: module, canonical: canonical)

        @unknown default:
            // A new case in a future OS must not read as "ready".
            state = .failed(reason: "unrecognized asset status")
        }

        Self.log.info("asset state for \(canonical.identifier, privacy: .public): \(String(describing: self.state), privacy: .public)")
        return state
    }

    /// Reserve the locale and pull the model down.
    private func install(module: SpeechTranscriber, canonical: Locale) async -> SpeechAssetState {
        do {
            // §0.6 names an `AssetInventory.maximumReservedLocales` cap. M0
            // uses one locale, so this is a guard rather than a policy; the
            // eviction strategy is M6's problem when per-app locales exist.
            if await !AssetInventory.reservedLocales.contains(canonical) {
                let reserved = try await AssetInventory.reserve(locale: canonical)
                if !reserved {
                    Self.log.error("could not reserve \(canonical.identifier, privacy: .public)")
                }
            }

            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                // Nothing to install and the status was not `.installed`.
                // Re-read rather than assume either way.
                let status = await AssetInventory.status(forModules: [module])
                return status == .installed
                    ? .available(locale: canonical)
                    : .failed(reason: "no installation request available")
            }

            state = .downloading(fraction: request.progress.fractionCompleted)
            try await request.downloadAndInstall()

            // Confirm rather than trust the call returning. §0.6 documents
            // assets stuck in "downloading".
            let after = await AssetInventory.status(forModules: [module])
            return after == .installed
                ? .available(locale: canonical)
                : .failed(reason: "install finished but status is \(after)")

        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
