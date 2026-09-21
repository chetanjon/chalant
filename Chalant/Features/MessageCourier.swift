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
        /// The thread to answer in, when the caller already knows it. The
        /// island's reply card always does: the message came from there.
        var chatID: String?
    }

    private(set) var pending: Pending?

    /// A staged message older than this is a forgotten one; "send"
    /// must never fire something the user no longer remembers.
    private static let shelfLife: TimeInterval = 120

    private static let scriptQueue = DispatchQueue(
        label: "chalant.courier.script", qos: .userInitiated
    )

    /// Everything to do with the automation grant, kept off the lane
    /// above. Asking raises the modal dialog and blocks until the user
    /// answers it, which can be minutes; it used to share the send's
    /// serial lane, so a send said while that dialog was up queued
    /// behind the dialog itself and never ran. The island held
    /// isWorking and went deaf until relaunch. Concurrent, so the
    /// non-blocking status read never queues behind a waiting ask
    /// either.
    private static let grantQueue = DispatchQueue(
        label: "chalant.courier.grant", qos: .utility, attributes: .concurrent
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
    func stage(
        freeform rest: String,
        using resolve: (String) async -> Resolution = { await MessageCourier.resolve($0) }
    ) async -> String {
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
                let answer = await stage(recipient: who, body: what, using: resolve)
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
        var ambiguous: [String]?
        for length in stride(from: min(3, tokens.count), through: 1, by: -1) {
            let candidate = tokens.prefix(length).joined(separator: " ")
            switch await resolve(candidate) {
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
                return "Chalant can't read Contacts. System Settings, Privacy and Security, Contacts. Or text the number itself."
            case .unasked:
                return "macOS is asking to let Chalant see Contacts. Click Allow, then say it again."
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
    private func stage(
        recipient: String,
        body: String,
        using resolve: (String) async -> Resolution = { await MessageCourier.resolve($0) }
    ) async -> String {
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

        switch await resolve(who) {
        case .none:
            return "No one called \"\(who)\" in Contacts."
        case .denied:
            return "Chalant can't read Contacts. System Settings, Privacy and Security, Contacts. Or text the number itself."
        case .many(let names):
            let list = names.prefix(3).joined(separator: " · ")
            return "Which one? \(list). Say text and the fuller name."
        case .unasked:
            return "macOS is asking to let Chalant see Contacts. Click Allow, then say it again."
        case .failed:
            return "Contacts didn't answer. Say it again in a moment."
        case .one(let name, let handle):
            return stagePending(name: name, handle: handle, body: what)
        }
    }

    /// Stage for somebody already resolved. The island's reply card
    /// asks Contacts who the sender is the moment their message
    /// arrives, so by the time there are words there is nothing left
    /// to look up, and nothing left to guess.
    @discardableResult
    func stage(
        name: String, handle: String, body: String, chatID: String? = nil
    ) -> String {
        stagePending(name: name, handle: handle, body: body, chatID: chatID)
    }

    /// Stage, front the grant, read back: one door for every path.
    private func stagePending(
        name: String, handle: String, body: String, chatID: String? = nil
    ) -> String {
        pending = Pending(
            name: name, handle: handle, body: body, staged: Date(), chatID: chatID)
        primeMessagesGrant()
        return readBack()
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

    /// What became of a send, as a value rather than a sentence.
    ///
    /// The voice path only ever needed words to say back. The island's
    /// reply card needs to KNOW: it once showed "Sent." for a message
    /// that had gone stale and never left, because "nothing is staged
    /// any more" was the only signal it had, and a stale message clears
    /// the stage exactly the way a delivered one does (2026-09-19).
    enum SendOutcome: Equatable {
        case sent(name: String)
        case nothingStaged
        /// Staged too long ago to trust; the stage is cleared.
        case stale
        /// Messages has not answered about the grant yet. Still staged.
        case wakingUp
        /// macOS is showing the automation dialog. Still staged.
        case askingPermission
        /// The user refused automation of Messages. Still staged.
        case blocked
        /// No iMessage account on this Mac. Still staged.
        case notSignedIn
        /// Messages returned an error. Still staged.
        case failed(String)
    }

    /// Fire the staged message through Messages.app. The words only
    /// leave once the grant is already settled: a permission dialog
    /// raised mid-send would block the script lane and wedge the
    /// island, so an unsettled grant answers with instructions and
    /// keeps the message staged for the next "send".
    func confirmSend() async -> String {
        switch await confirmSendOutcome() {
        case .sent(let name):
            return "Sent to \(name)."
        case .nothingStaged:
            return "Nothing staged to send."
        case .stale:
            return "That message went stale. Say it again."
        case .wakingUp:
            return "Messages is waking up. Say send again in a moment."
        case .askingPermission:
            return "macOS is asking to let Chalant use Messages. Click Allow, then say send."
        case .blocked:
            return "macOS blocked Chalant from Messages. System Settings, Privacy and Security, Automation, then say send again."
        case .notSignedIn:
            return "Messages isn't signed in to iMessage on this Mac. It holds; say send once that's fixed."
        case .failed(let error):
            return "Messages balked: \(error). It holds; say send to try again."
        }
    }

    /// The same send, answering with what happened instead of what to
    /// say about it. Every string above is derived from this, so the
    /// voice path reads exactly as it always has.
    func confirmSendOutcome() async -> SendOutcome {
        guard let message = pending else { return .nothingStaged }
        guard Date().timeIntervalSince(message.staged) < Self.shelfLife else {
            pending = nil
            return .stale
        }

        guard let grant = await messagesGrantStatus() else {
            primeMessagesGrant()
            return .wakingUp
        }
        switch grant {
        case -1744:
            primeMessagesGrant()
            return .askingPermission
        case -1743:
            return .blocked
        default:
            break
        }

        // **Answer in the thread the message came from.**
        //
        // The line below used to be `1st account whose service type =
        // iMessage` for everybody. Measured on the founder's Mac
        // 2026-09-20: 84 of their 135 one-to-one threads are SMS and 7
        // are RCS. For all 91 of those, forcing iMessage asks Messages to
        // send through an account the other person may not have, and
        // AppleScript reports no error either way, so the card would have
        // said "Sent" over a message that never arrived.
        //
        // A thread that does not exist yet is the one case with nothing to
        // answer in, and there iMessage is the only thing to try.
        var chatID = message.chatID
        if chatID == nil {
            let all = await Self.conversations()
            if case .one(let found) = Self.conversation(handle: message.handle, in: all) {
                chatID = found.id
            }
        }
        // The message stays staged until it actually leaves: every
        // failure below invites a retry, and a retry with nothing
        // staged was a lie the review caught. Success alone clears.
        let script: String
        if let chatID {
            script = """
            tell application "Messages"
                send "\(Self.escaped(message.body))" to chat id "\(Self.escaped(chatID))"
            end tell
            """
        } else {
            script = """
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                send "\(Self.escaped(message.body))" to participant "\(Self.escaped(message.handle))" of targetService
            end tell
            """
        }
        let error = await Self.runScript(script)
        guard let error else {
            pending = nil
            return .sent(name: message.name)
        }
        if error.contains("-1743") { return .blocked }
        if error.contains("service type") || error.contains("account") {
            return .notSignedIn
        }
        return .failed(error)
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

    // MARK: - The conversations already on this Mac

    /// One thread in Messages, as the card needs to see it.
    ///
    /// **This, not Contacts, is what a reply should be aimed at.** A name
    /// in Contacts gives a number; a conversation gives the thread the
    /// message actually arrived in, and its service. Measured on the
    /// founder's Mac 2026-09-20: of 135 one-to-one threads, **84 are SMS
    /// and 7 are RCS. Only 44 are iMessage.** Sending every reply through
    /// `1st account whose service type = iMessage`, as the voice path
    /// does, would report success and deliver nothing for two thirds of
    /// them. Every handle mapped to exactly one thread, so this is not
    /// ambiguous in practice.
    struct Conversation: Equatable {
        /// `any;-;+15551234567` for one to one, `any;+;<guid>` for a group.
        let id: String
        /// iMessage, SMS or RCS: whatever this thread actually is.
        let service: String
        /// What Messages calls the other person, which is the same name it
        /// puts in the banner.
        let name: String
        let handle: String
        let isGroup: Bool
    }

    /// Which thread a banner's sender means.
    enum ConversationMatch: Equatable {
        case one(Conversation)
        /// Two threads answer to that name, so no reply is aimed anywhere.
        case several
        case none
    }

    /// Compare addresses the way people do not: `+1 (555) 010-0142` and
    /// `+15550100142` are one number, and an address is itself.
    nonisolated static func addressKey(_ handle: String) -> String {
        let digits = handle.filter(\.isNumber)
        if digits.count >= 10 { return String(digits.suffix(10)) }
        return handle.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The thread a message came from, found by the name on its banner.
    ///
    /// A group is never a match: the banner of a group message names the
    /// person who wrote, and a reply to them alone would be a private
    /// answer to something said in a room.
    nonisolated static func conversation(
        named sender: String, in all: [Conversation]
    ) -> ConversationMatch {
        let wanted = sender.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return .none }
        let byName = all.filter {
            !$0.isGroup
                && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }
        if byName.count == 1, let only = byName.first { return .one(only) }
        if byName.count > 1 { return .several }

        // A sender shown as a bare number: the name and the handle are the
        // same thing, formatted differently.
        let key = addressKey(sender)
        let byHandle = all.filter { !$0.isGroup && addressKey($0.handle) == key }
        if byHandle.count == 1, let only = byHandle.first { return .one(only) }
        return byHandle.isEmpty ? .none : .several
    }

    /// The thread for an address, for the Contacts fallback: the banner
    /// showed a name Messages does not use in its participant list.
    nonisolated static func conversation(
        handle: String, in all: [Conversation]
    ) -> ConversationMatch {
        let key = addressKey(handle)
        let hits = all.filter { !$0.isGroup && addressKey($0.handle) == key }
        if hits.count == 1, let only = hits.first { return .one(only) }
        return hits.isEmpty ? .none : .several
    }

    /// Read every thread out of Messages.
    ///
    /// One script rather than a question per chat: 145 of them answered in
    /// about a second, and the card cannot wait longer than it takes to
    /// read the message it is showing.
    nonisolated static func conversations() async -> [Conversation] {
        // **Never launch Messages to look.** `tell application` starts an
        // app that is not running, and a card appears for every text: one
        // ignored message would put Messages in the Dock. The send may
        // launch it, because sending was asked for; looking was not.
        guard messagesBundleIDs.contains(where: {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }) else { return [] }
        let source = """
        tell application "Messages"
            set out to ""
            repeat with c in chats
                try
                    set ps to participants of c
                    set n to count of ps
                    if n is 1 then
                        set p to item 1 of ps
                        set out to out & (id of c) & tab & ¬
                            (service type of account of c as text) & tab & ¬
                            (name of p as text) & tab & (handle of p as text) & linefeed
                    else
                        set out to out & (id of c) & tab & ¬
                            (service type of account of c as text) & tab & ¬
                            "" & tab & "" & linefeed
                    end if
                end try
            end repeat
            return out
        end tell
        """
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            scriptQueue.async {
                var error: NSDictionary?
                let answer = NSAppleScript(source: source)?
                    .executeAndReturnError(&error).stringValue ?? ""
                continuation.resume(returning: answer)
            }
        }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { return nil }
            return Conversation(
                id: id, service: parts[1].trimmingCharacters(in: .whitespaces),
                name: parts[2], handle: parts[3],
                // The id says so itself, and the participant count agrees.
                isGroup: id.contains(";+;") || parts[3].isEmpty
            )
        }
    }

    // MARK: - Who

    enum Resolution: Equatable {
        case none
        case denied
        /// The Contacts dialog has not been answered yet; the ask
        /// was just fired without waiting (the R94 wedge rule).
        case unasked
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
    /// - Parameter strict: for a name READ OFF A BANNER rather than spoken.
    ///   See `decide`.
    nonisolated static func resolve(
        _ spokenName: String, strict: Bool = false
    ) async -> Resolution {
        // Anything not undetermined/denied/restricted passes (limited
        // access counts as a yes). The undetermined case fires the
        // ask without waiting and reports itself, so no caller ever
        // blocks on a dialog (the R94 wedge rule) and no separate
        // gate needs to run before resolution.
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            Task.detached(priority: .userInitiated) {
                _ = try? await CNContactStore().requestAccess(for: .contacts)
            }
            return .unasked
        case .denied, .restricted:
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
            func people(_ contacts: [CNContact]) -> [Person] {
                contacts.map {
                    Person(id: $0.identifier, name: Self.displayName($0),
                           handle: Self.handle(for: $0))
                }
            }
            return Self.decide(
                nick: people(exactNick), given: people(exactGiven),
                full: people(exactFull), prefix: people(prefixFull),
                strict: strict
            )
        }.value
    }

    /// One contact, reduced to what deciding needs, so the decision can be
    /// tested without an address book.
    struct Person: Equatable {
        let id: String
        let name: String
        let handle: String?
    }

    /// Who a name means.
    ///
    /// **Spoken**, the first tier with anybody in it wins (nickname, then
    /// given name, then full name, then a full-name prefix). That is right
    /// for a name somebody just said: they meant their "Mum", and the
    /// read-back catches a wrong pick before anything is sent.
    ///
    /// **Strict** is for a name read off a notification banner, where
    /// nobody chose anything and there is no read-back of the recipient to
    /// catch a wrong one. There the question is not "which tier is best"
    /// but "is there exactly ONE contact this could be". Every exact tier
    /// counts together, a prefix never counts ("Sam" is not "Samantha"),
    /// and two candidates of any kind is a refusal. A reply that cannot be
    /// aimed with certainty is opened in Messages instead, where the
    /// conversation itself is the address.
    nonisolated static func decide(
        nick: [Person], given: [Person], full: [Person], prefix: [Person],
        strict: Bool
    ) -> Resolution {
        let pool: [Person]
        if strict {
            var seen = Set<String>()
            pool = (nick + given + full).filter { seen.insert($0.id).inserted }
        } else {
            pool = [nick, given, full, prefix].first { !$0.isEmpty } ?? []
        }
        let reachable = pool.filter { $0.handle != nil }
        guard !reachable.isEmpty else { return .none }
        if reachable.count == 1, let person = reachable.first, let handle = person.handle {
            return .one(name: person.name, handle: handle)
        }
        return .many(reachable.map(\.name))
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

    static let messagesBundleIDs = ["com.apple.MobileSMS", "com.apple.iChat"]

    private var runningMessagesBundleID: String? {
        Self.messagesBundleIDs.first {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
    }

    /// The grant, checked without asking: noErr means go, -1744 means
    /// the dialog hasn't been answered, -1743 means it was answered
    /// no. nil means Messages isn't running to be asked about.
    private func messagesGrantStatus() async -> OSStatus? {
        guard let bundleID = runningMessagesBundleID else { return nil }
        // A TCC round trip, so it does not belong on the main actor
        // even when it is only reading. askIfNeeded is false here: this
        // one never raises a dialog, so it never blocks its lane.
        return await withCheckedContinuation { continuation in
            Self.grantQueue.async {
                continuation.resume(
                    returning: PermissionPrimer.primeAutomation(
                        bundleID: bundleID, askIfNeeded: false)
                )
            }
        }
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
        grantQueue.async {
            PermissionPrimer.primeAutomation(bundleID: bundleID, askIfNeeded: true)
        }
    }
}
