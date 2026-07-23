import AppKit
import Contacts
import Foundation

/// Sends iMessages through Messages.app, with one hard rule: nothing
/// leaves this Mac until the exact words have been read back and the
/// user says "send". A misheard name plus an instant send would put
/// words in front of a real person; the read-back makes that
/// impossible. Staged messages die quietly: any other command drops
/// them, and a stale one expires on its own.
@MainActor
final class MessageCourier {
    struct Pending {
        let name: String
        let handle: String
        let body: String
        let staged: Date
    }

    private(set) var pending: Pending?

    /// A staged message older than this is a forgotten one; "send"
    /// must never fire something the user no longer remembers.
    private static let shelfLife: TimeInterval = 120

    private static let scriptQueue = DispatchQueue(
        label: "moai.courier.script", qos: .userInitiated
    )

    // MARK: - Staging

    /// "mom on my way", "john smith: running late", "5551234567 hi".
    /// The name ends where a said separator puts it, or where the
    /// address book stops recognizing; the rest is the message.
    /// Separators only count NEAR THE FRONT: a comma or "that" deep
    /// inside the message is punctuation, not a boundary (review-
    /// caught: "text mom running late, see you soon" once died on
    /// its own comma), and a front separator whose left side isn't
    /// in Contacts falls through to the token walk instead of
    /// giving up.
    func stage(freeform rest: String) async -> String {
        pending = nil
        var trimmed = rest.trimmingCharacters(in: .whitespaces)
        for lead in ["to "] where trimmed.lowercased().hasPrefix(lead) {
            trimmed = String(trimmed.dropFirst(lead.count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty else { return "Text who?" }

        // An explicit separator in name position: at most three
        // words may sit left of it for it to mean "here ends who".
        let separators = [": ", " that ", " saying ", " to say ", ", "]
        let cut = separators
            .compactMap { trimmed.range(of: $0, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
        if let cut {
            let who = String(trimmed[..<cut.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let whoTokens = who.split(separator: " ").count
            if whoTokens <= 3 {
                let what = String(trimmed[cut.upperBound...])
                let answer = await stage(recipient: who, body: what)
                // A failed front-split is not the end: the walk
                // below may still find the name.
                if pending != nil || !answer.hasPrefix("No one called") {
                    return answer
                }
            }
        }

        let tokens = trimmed.split(separator: " ").map(String.init)

        // A spoken or pasted phone number arrives as several tokens
        // ("+1 (630) 545 8630"); eat the leading phone-shaped run as
        // one handle before asking the address book anything.
        var phoneTokens = 0
        var digitCount = 0
        for token in tokens {
            guard token.allSatisfy({ $0.isNumber || "+-().".contains($0) }),
                  !token.isEmpty else { break }
            phoneTokens += 1
            digitCount += token.filter(\.isNumber).count
        }
        if phoneTokens > 0, digitCount >= 7 {
            return await stage(
                recipient: tokens.prefix(phoneTokens).joined(separator: " "),
                body: tokens.dropFirst(phoneTokens).joined(separator: " ")
            )
        }

        // An email never spans words; it already says where to go.
        if let first = tokens.first, Self.literalHandle(first) != nil {
            return await stage(
                recipient: first,
                body: tokens.dropFirst().joined(separator: " ")
            )
        }

        // The address book decides where the name ends. Longest
        // candidate first, so "mary jane meet me" reaches Mary Jane
        // and not a Mary with a strange message; the whole utterance
        // is a fair candidate too ("text mary jane" is a name and a
        // missing message, not Mary and the word jane).
        if let gate = contactsGate() { return gate }
        var ambiguous: [String]?
        for length in stride(from: min(3, tokens.count), through: 1, by: -1) {
            let candidate = tokens.prefix(length).joined(separator: " ")
            switch await Self.resolve(candidate) {
            case .one(let name, let handle):
                let body = tokens.dropFirst(length).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else {
                    return "Text \(name) what? Say it in one line: text \(name.lowercased()), then the words."
                }
                return stagePending(name: name, handle: handle, body: body)
            case .many(let names) where ambiguous == nil:
                ambiguous = names
            case .denied:
                return "Moai can't read Contacts. System Settings, Privacy and Security, Contacts. Or text the number itself."
            case .failed:
                return "Contacts didn't answer. Say it again in a moment."
            default:
                continue
            }
        }
        if let ambiguous {
            let list = ambiguous.prefix(3).joined(separator: " · ")
            return "Which one? \(list). Say text and the fuller name."
        }
        return "No one called \"\(tokens[0])\" in Contacts. A number or email works too."
    }

    /// Resolve who and stage what; the returned line is the read-back.
    private func stage(recipient: String, body: String) async -> String {
        pending = nil
        var who = recipient.trimmingCharacters(in: .whitespaces)
        for lead in ["to "] where who.lowercased().hasPrefix(lead) {
            who = String(who.dropFirst(lead.count))
                .trimmingCharacters(in: .whitespaces)
        }
        let what = body.trimmingCharacters(in: .whitespaces)
        guard !who.isEmpty else { return "Text who?" }
        guard !what.isEmpty else {
            return "Text \(who.capitalized) what? Say it in one line: text \(who.lowercased()), then the words."
        }

        if let literal = Self.literalHandle(who) {
            return stagePending(name: who, handle: literal, body: what)
        }

        if let gate = contactsGate() { return gate }
        switch await Self.resolve(who) {
        case .none:
            return "No one called \"\(who)\" in Contacts."
        case .denied:
            return "Moai can't read Contacts. System Settings, Privacy and Security, Contacts. Or text the number itself."
        case .many(let names):
            let list = names.prefix(3).joined(separator: " · ")
            return "Which one? \(list). Say text and the fuller name."
        case .failed:
            return "Contacts didn't answer. Say it again in a moment."
        case .one(let name, let handle):
            return stagePending(name: name, handle: handle, body: what)
        }
    }

    /// Stage, front the grant, read back: one door for every path.
    private func stagePending(name: String, handle: String, body: String) -> String {
        pending = Pending(name: name, handle: handle, body: body, staged: Date())
        primeMessagesGrant()
        return readBack()
    }

    /// The Contacts dialog must never be awaited from here: a dialog
    /// nobody clicks would hold isWorking and wedge the island. Ask
    /// without waiting and say plainly what to do next.
    private func contactsGate() -> String? {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            Task.detached(priority: .userInitiated) {
                _ = try? await CNContactStore().requestAccess(for: .contacts)
            }
            return "macOS is asking to let Moai see Contacts. Click Allow, then say it again."
        case .denied, .restricted:
            return "Moai can't read Contacts. System Settings, Privacy and Security, Contacts. Or text the number itself."
        default:
            return nil
        }
    }

    private func readBack() -> String {
        guard let pending else { return "Nothing staged to send." }
        // The handle earns its parentheses only when it says something
        // the name doesn't; "to x (x)" reads twice for no reason.
        let address = pending.handle == pending.name ? "" : " (\(pending.handle))"
        return "To \(pending.name)\(address): \u{201C}\(pending.body)\u{201D}. Say send, or anything else to drop it."
    }

    /// Any command that is not "send" clears the stage; a message must
    /// never outlive the moment it was read back in.
    func drop() {
        pending = nil
    }

    // MARK: - Sending

    /// Fire the staged message through Messages.app. The words only
    /// leave once the grant is already settled: a permission dialog
    /// raised mid-send would block the script lane and wedge the
    /// island, so an unsettled grant answers with instructions and
    /// keeps the message staged for the next "send".
    func confirmSend() async -> String {
        guard let message = pending else { return "Nothing staged to send." }
        guard Date().timeIntervalSince(message.staged) < Self.shelfLife else {
            pending = nil
            return "That message went stale. Say it again."
        }

        guard let grant = messagesGrantStatus() else {
            primeMessagesGrant()
            return "Messages is waking up. Say send again in a moment."
        }
        switch grant {
        case -1744:
            primeMessagesGrant()
            return "macOS is asking to let Moai use Messages. Click Allow, then say send."
        case -1743:
            return "macOS blocked Moai from Messages. System Settings, Privacy and Security, Automation, then say send again."
        default:
            break
        }

        // The message stays staged until it actually leaves: every
        // failure below invites a retry, and a retry with nothing
        // staged was a lie the review caught. Success alone clears.
        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            send "\(Self.escaped(message.body))" to participant "\(Self.escaped(message.handle))" of targetService
        end tell
        """
        let error = await Self.runScript(script)
        guard let error else {
            pending = nil
            return "Sent to \(message.name)."
        }
        if error.contains("-1743") {
            return "macOS blocked Moai from Messages. System Settings, Privacy and Security, Automation, then say send again."
        }
        if error.contains("service type") || error.contains("account") {
            return "Messages isn't signed in to iMessage on this Mac. It holds; say send once that's fixed."
        }
        return "Messages balked: \(error). It holds; say send to try again."
    }

    /// Runs on the script lane; returns nil on success, the error
    /// message otherwise. The call can block for a while (first run
    /// launches Messages and may raise the automation dialog), which
    /// is exactly why it never runs on the main actor.
    private static func runScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            scriptQueue.async {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                let message = error.map {
                    "\($0[NSAppleScript.errorAppName] ?? "")\($0[NSAppleScript.errorNumber] ?? "") \($0[NSAppleScript.errorMessage] ?? "")"
                    .trimmingCharacters(in: .whitespaces)
                }
                continuation.resume(returning: message)
            }
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Who

    private enum Resolution {
        case none
        case denied
        case failed
        case one(name: String, handle: String)
        case many([String])
    }

    /// Phone-ish or email-ish input is its own address.
    nonisolated static func literalHandle(_ text: String) -> String? {
        if text.contains("@"), text.contains("."), !text.contains(" ") {
            return text
        }
        let digits = text.filter(\.isNumber)
        let phoneish = text.allSatisfy {
            $0.isNumber || "+-() .".contains($0)
        }
        if phoneish, digits.count >= 7 {
            // Formatting never travels: "+1 (555) 123-4567" goes out
            // as +15551234567 (review-caught; the plus branch used
            // to keep its parentheses).
            return text.first == "+" ? "+" + digits : digits
        }
        return nil
    }

    /// Look the spoken name up in the user's address book. Nickname
    /// beats given name beats full name; several equal hits come back
    /// as a question instead of a guess.
    nonisolated private static func resolve(_ spokenName: String) async -> Resolution {
        // Mirror the gate exactly: it lets through anything that is
        // not undetermined/denied/restricted (limited access counts
        // as a yes), so requiring .authorized here called limited
        // access "denied" and pointed at the wrong fix (review-
        // caught).
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined, .denied, .restricted:
            return .denied
        default:
            break
        }
        let store = CNContactStore()

        let keys = [
            CNContactGivenNameKey, CNContactFamilyNameKey,
            CNContactNicknameKey, CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]

        return await Task.detached(priority: .userInitiated) {
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = true
            let wanted = spokenName.lowercased()

            var exactNick: [CNContact] = []
            var exactGiven: [CNContact] = []
            var exactFull: [CNContact] = []
            var prefixFull: [CNContact] = []
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    let full = "\(contact.givenName) \(contact.familyName)"
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    if contact.nickname.lowercased() == wanted {
                        exactNick.append(contact)
                    } else if contact.givenName.lowercased() == wanted {
                        exactGiven.append(contact)
                    } else if full == wanted {
                        exactFull.append(contact)
                    } else if full.hasPrefix(wanted), !wanted.isEmpty {
                        prefixFull.append(contact)
                    }
                }
            } catch {
                // A fetch that THREW is not an empty address book;
                // saying "no one called mom" over a transient error
                // was a lie (review-caught).
                return .failed
            }
            let tier = [exactNick, exactGiven, exactFull, prefixFull]
                .first { !$0.isEmpty } ?? []
            let reachable = tier.filter { Self.handle(for: $0) != nil }
            guard !reachable.isEmpty else { return .none }
            if reachable.count == 1, let contact = reachable.first,
               let handle = Self.handle(for: contact) {
                return .one(name: Self.displayName(contact), handle: handle)
            }
            return .many(reachable.map(Self.displayName))
        }.value
    }

    /// Mobile first, then any phone, then an email; iMessage answers
    /// to all three.
    nonisolated private static func handle(for contact: CNContact) -> String? {
        let phones = contact.phoneNumbers
        let mobile = phones.first {
            $0.label == CNLabelPhoneNumberMobile
                || $0.label == CNLabelPhoneNumberiPhone
                || $0.label == CNLabelPhoneNumberMain
        }
        if let number = (mobile ?? phones.first)?.value.stringValue {
            return number
        }
        return contact.emailAddresses.first.map { String($0.value) }
    }

    nonisolated private static func displayName(_ contact: CNContact) -> String {
        let nick = contact.nickname.trimmingCharacters(in: .whitespaces)
        if !nick.isEmpty { return nick }
        return "\(contact.givenName) \(contact.familyName)"
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The grant

    private static let messagesBundleIDs = ["com.apple.MobileSMS", "com.apple.iChat"]

    private var runningMessagesBundleID: String? {
        Self.messagesBundleIDs.first {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    /// The grant, checked without asking: noErr means go, -1744 means
    /// the dialog hasn't been answered, -1743 means it was answered
    /// no. nil means Messages isn't running to be asked about.
    private func messagesGrantStatus() -> OSStatus? {
        guard let bundleID = runningMessagesBundleID else { return nil }
        return PermissionPrimer.primeAutomation(bundleID: bundleID, askIfNeeded: false)
    }

    /// The automation dialog can only be raised for a running app, so
    /// stage time launches Messages quietly and fronts the ask; the
    /// dialog lands while the read-back is on screen, not after the
    /// user has already said send. Same lesson as the music players:
    /// an unprompted grant once sat unanswered for a day.
    private func primeMessagesGrant() {
        if let running = runningMessagesBundleID {
            Self.primeAutomation(bundleID: running)
            return
        }
        for bundleID in Self.messagesBundleIDs {
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleID) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Self.primeAutomation(bundleID: bundleID)
                }
            }
            return
        }
    }

    private static func primeAutomation(bundleID: String) {
        scriptQueue.async {
            PermissionPrimer.primeAutomation(bundleID: bundleID, askIfNeeded: true)
        }
    }
}
