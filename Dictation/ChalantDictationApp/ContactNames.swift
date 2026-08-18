import AppKit
import Contacts
import Foundation
import os

/// The names in the user's Contacts, as the wide pool both ears draw on.
///
/// **Read only when macOS already says Chalant may.** The grant is the one the
/// "text someone" door asks for; this never asks on its own. Settings has the
/// ask, in words, next to what it is for. Names only: given, family, nickname,
/// organization. Not numbers, not emails, not who they belong to, and nothing
/// is written to disk: the list lives in memory and is read again when
/// Contacts changes.
///
/// **A name that is an ordinary English word is left out.** Both ears already
/// hear "Rose", "Mark" and "Will"; a vocabulary that carries them would only
/// capitalize the verb, and a Whisper prompt full of them tilts its
/// capitalization for nothing. The pool exists for Priya, Gangothri and
/// Jonnalagadda. Same spell-checker test the learner uses.
///
/// Refuses nothing else on its own: which of these names reach an ear for a
/// given utterance is `NameHints`' decision, made from what the first ear
/// heard, so a thousand contacts are never cut alphabetically.
actor ContactNames {
    static let shared = ContactNames()
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "names")

    private(set) var names: [String] = []
    private var loaded = false
    private var observer: NSObjectProtocol?

    static var status: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    static var isAuthorized: Bool { status == .authorized }

    /// The one place the ask lives. Returns whether access is granted after
    /// the dialog, and loads the names when it is.
    static func ask() async -> Bool {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        if granted { await shared.reload() }
        return granted
    }

    /// Loads once, when authorized; a second call is free. Watches for
    /// changes to Contacts from then on.
    func load() async {
        guard !loaded else { return }
        loaded = true
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .CNContactStoreDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                Task { await self?.reload() }
            }
        }
        await reload()
    }

    /// The pool as of now: authorized and loaded, or empty.
    func pool() async -> [String] {
        await load()
        return names
    }

    func reload() async {
        guard Self.isAuthorized else {
            names = []
            return
        }
        let raw = Self.read()
        let usable = await Self.usable(raw)
        names = usable
        Self.log.info("contacts: \(raw.count, privacy: .public) name pieces read, \(usable.count, privacy: .public) usable")
    }

    /// Every name piece in Contacts, in the order the store gives them.
    /// Enumeration failures leave an empty pool and a log line, never a crash
    /// and never a stale claim of names that were not read.
    private static func read() -> [String] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey,
            CNContactNicknameKey, CNContactOrganizationNameKey,
        ].map { $0 as CNKeyDescriptor }
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var pieces: [String] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                for field in [contact.givenName, contact.familyName, contact.nickname, contact.organizationName] {
                    for piece in field.split(whereSeparator: { $0.isWhitespace }) {
                        pieces.append(String(piece))
                    }
                }
            }
        } catch {
            log.error("contacts could not be read: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return pieces
    }

    /// The pieces worth keeping: two to forty characters, made of letters
    /// (with the apostrophes, hyphens and dots names carry), not an ordinary
    /// dictionary word, each spelling once. Sorted, so the pool is the same
    /// list whatever order the store enumerated in.
    @MainActor
    static func usable(_ pieces: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            guard (2...40).contains(trimmed.count) else { continue }
            guard trimmed.contains(where: { $0.isLetter }) else { continue }
            guard trimmed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" || $0 == "." || $0 == "\u{2019}" }) else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            guard !CorrectionObserver.isDictionaryWord(trimmed) else { continue }
            out.append(trimmed)
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }
}
