import Foundation

/// The message waiting on the island, and the reply being written
/// into it.
///
/// **One reply field.** Talking fills it, typing fills it, and Send (or
/// Return) sends exactly what is in it. That is the whole model, and it
/// is the one every chat app has already taught: there is never a
/// moment where the words exist somewhere the person cannot see or fix.
///
/// Four rules, all of them the founder's:
///
/// 1. **It is a moment, not an inbox.** A card nobody touches goes after
///    about half a minute, the way the banner it came from did. A newer
///    message replaces an untouched older one. The backlog lives in
///    Messages, which is already good at being a backlog.
/// 2. **Nothing leaves without a deliberate press on words in plain
///    sight.** iMessage cannot unsend by automation, so that press is
///    the whole safety story.
/// 3. **It never guesses who.** A banner names a person, not an
///    address. Contacts is asked the moment the message arrives, so the
///    card knows whether a reply can go BEFORE anybody has spoken one,
///    and the reply controls exist only when it can (the first build
///    let people dictate a whole reply and then told them it could never
///    be sent).
/// 4. **It never lies about what happened.** "Sent" appears when
///    Messages accepted the message and at no other time. The first
///    build showed it for a draft that had gone stale and never left.
@MainActor
final class MessageReply: ObservableObject {
    /// Whether a reply can go to this sender, settled on arrival.
    enum Recipient: Equatable {
        case checking
        case known(name: String, handle: String)
        /// Why not, in the card's own words. The way forward is always
        /// the same: open the conversation in Messages.
        case cannotReply(String)
    }

    /// What the card is doing right now.
    enum Phase: Equatable {
        case idle
        /// The mic button is down.
        case listening
        /// Let go, words not back yet. Without this the card looked
        /// exactly as it had before anyone spoke, for about two seconds.
        case hearing
        case sending
        case sent(name: String)
        /// The send did not go. The draft is kept: nobody should have
        /// to say a sentence twice because a dialog got in the way.
        case failed(String)
    }

    /// The doors to Contacts and Messages, as closures, so every rule
    /// here can be tested without texting anybody.
    struct Courier {
        var resolve: (_ sender: String) async -> MessageCourier.Resolution
        var send: (_ name: String, _ handle: String, _ body: String) async
            -> MessageCourier.SendOutcome

        @MainActor
        static var live: Courier {
            let courier = MessageCourier()
            return Courier(
                resolve: { sender in
                    // A sender who IS an address needs no address book.
                    if let literal = MessageCourier.literalHandle(sender) {
                        return .one(name: sender, handle: literal)
                    }
                    // Strict: a banner title is nobody's choice, so it
                    // must mean exactly one contact or it means nobody.
                    return await MessageCourier.resolve(sender, strict: true)
                },
                send: { name, handle, body in
                    // Staged and confirmed in one breath. The courier's
                    // two minute shelf life guards a spoken "send" that
                    // arrives long after a read-back; here the words are
                    // on screen under the button being pressed.
                    courier.stage(name: name, handle: handle, body: body)
                    var outcome = await courier.confirmSendOutcome()
                    // With Messages closed, the first ask only wakes it.
                    // The person pressed Send once; they should not have
                    // to press it again to find out it was always going
                    // to work.
                    var tries = 0
                    while outcome == .wakingUp, tries < 4 {
                        tries += 1
                        try? await Task.sleep(for: .milliseconds(900))
                        outcome = await courier.confirmSendOutcome()
                    }
                    return outcome
                }
            )
        }
    }

    /// Long enough to read a message and decide, short enough that the
    /// island never becomes something to tidy up.
    static let life: TimeInterval = 30

    /// After the mic is let go, how long the words may take to come
    /// back before the card stops waiting for them. Silence produces no
    /// words at all, and a card stuck on "hearing" for ever is its own
    /// kind of dead end.
    static let hearingPatience: TimeInterval = 8

    @Published private(set) var sighting: MessageWatch.Sighting?
    @Published private(set) var recipient: Recipient = .checking
    @Published private(set) var phase: Phase = .idle
    /// The reply field. Bound by the card, filled by dictation.
    @Published var draft = ""
    /// One quiet line under the field when something needs saying that
    /// the phase alone does not: a click that should have been a hold.
    @Published private(set) var hint: String?

    /// Has anybody touched this card. An untouched card ignores clicks
    /// elsewhere and fades by itself; a touched one is the person's.
    private(set) var engaged = false

    private let courier: Courier
    private let life: TimeInterval
    private let hearingPatience: TimeInterval
    private var fade: DispatchWorkItem?
    private var hearingTimeout: DispatchWorkItem?
    private var onFade: (() -> Void)?
    private var hovering = false

    init(
        courier: Courier? = nil,
        life: TimeInterval = MessageReply.life,
        hearingPatience: TimeInterval = MessageReply.hearingPatience
    ) {
        self.courier = courier ?? .live
        self.life = life
        self.hearingPatience = hearingPatience
    }

    var isShowing: Bool { sighting != nil }

    /// Somebody is in the middle of answering. A newer message must not
    /// take the card now: replacing it would throw their words away at
    /// best, and at worst leave a reply meant for one person sitting
    /// under another person's name.
    var isMidReply: Bool {
        guard isShowing else { return false }
        // Clicked into, even with nothing written yet: the next keystroke
        // belongs to THIS conversation. A newer message sliding in under
        // the cursor would put those words under someone else's name.
        if engaged { return true }
        switch phase {
        case .idle, .failed:
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .listening, .hearing, .sending:
            return true
        case .sent:
            return false
        }
    }

    var canSend: Bool {
        guard case .known = recipient else { return false }
        switch phase {
        case .idle, .failed:
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    // MARK: - Arriving and leaving

    /// A message arrived. The caller has already checked `isMidReply`;
    /// whatever was here before had its turn.
    func show(_ sighting: MessageWatch.Sighting, onFade: @escaping () -> Void) {
        cancelTimers()
        self.sighting = sighting
        self.onFade = onFade
        recipient = .checking
        phase = .idle
        draft = ""
        hint = nil
        engaged = false
        // `hovering` is deliberately kept: a card replaced under the
        // pointer is still under the pointer, and resetting it made the
        // new card fade while somebody was reading it.
        armFade()

        guard sighting.lineCount == 2 else {
            recipient = .cannotReply(
                "This looks like a group or a thread Chalant hasn't seen before, so it won't guess who a reply would reach. Reply in Messages."
            )
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let answer = await courier.resolve(sighting.sender)
            // The card may have moved on while Contacts was thinking.
            guard self.sighting?.id == sighting.id else { return }
            recipient = Self.recipient(for: answer, sender: sighting.sender)
        }
    }

    /// The card goes: dismissed, faded, or done.
    func dismiss() {
        cancelTimers()
        sighting = nil
        onFade = nil
        recipient = .checking
        phase = .idle
        draft = ""
        hint = nil
        engaged = false
        hovering = false
    }

    // MARK: - The fade

    /// The pointer is on the card: somebody is reading. A card that
    /// vanishes under the pointer at second thirty is the rudest thing
    /// this could do short of sending something.
    func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            fade?.cancel()
            fade = nil
        } else {
            armFade()
        }
    }

    /// Typing, focusing the field, pressing the mic: the card is the
    /// person's now, and it stays until they are done with it.
    func touch() {
        engaged = true
        armFade()
    }

    private var isUnattended: Bool {
        guard isShowing, !hovering else { return false }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    private func armFade() {
        fade?.cancel()
        fade = nil
        // Only an unattended card fades: nothing written, nothing in
        // flight, nobody's pointer on it. A touched card counts as
        // unattended again once it has sat empty and idle for a whole
        // life; otherwise one stray click would pin a card open for ever
        // and block every later message behind it.
        guard isUnattended else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, isUnattended else { return }
            let done = onFade
            dismiss()
            done?()
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + life, execute: work)
    }

    // MARK: - Talking

    /// The mic button went down.
    func talkPressed() {
        guard case .known = recipient else { return }
        touch()
        hint = nil
        hearingTimeout?.cancel()
        phase = .listening
    }

    /// The mic button came up. `held` is false for a click that was
    /// never a hold, which starts nothing and says why.
    func talkReleased(held: Bool) {
        guard phase == .listening else { return }
        guard held else {
            phase = .idle
            hint = "Hold the mic down while you talk, then let go."
            return
        }
        phase = .hearing
        let work = DispatchWorkItem { [weak self] in
            guard let self, phase == .hearing else { return }
            phase = .idle
            hint = "I didn't catch that. Try again, or type it."
            armFade()
        }
        hearingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hearingPatience, execute: work)
    }

    /// The hold was long enough to have gone live and never did: the
    /// model is still downloading, or the microphone is not granted. The
    /// first build said "Listening" and then "Got it" over a dead mic.
    func talkRefused() {
        guard phase == .listening else { return }
        phase = .idle
        hint = "Dictation isn't ready yet. Type your reply for now."
        armFade()
    }

    /// Something the island needs the person to know, said on the card
    /// because the card is what they are looking at.
    func note(_ line: String) {
        hint = line
    }

    /// Words came back from dictation, for the card that asked for them.
    ///
    /// `asked` is the message that was on the card when the mic went
    /// down. If a different one is showing now, the words are dropped:
    /// a sentence spoken to one person never lands under another's name.
    func heard(_ text: String, for asked: MessageWatch.Sighting) {
        guard let sighting, sighting.id == asked.id else { return }
        hearingTimeout?.cancel()
        hearingTimeout = nil
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only "hearing" ends here. Words from an earlier hold can arrive
        // while the mic is down again, and flipping to idle then would
        // show a resting card under a finger that is still talking.
        if phase == .hearing { phase = .idle }
        guard !words.isEmpty else {
            hint = "I didn't catch that. Try again, or type it."
            return
        }
        hint = nil
        // Added to what is there, never over it: someone who types a
        // few words and then talks has not asked to lose the first part.
        let existing = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = existing.isEmpty ? words : existing + " " + words
    }

    // MARK: - Sending

    /// The deliberate press. Sends exactly what the field shows.
    @discardableResult
    func send() async -> Bool {
        guard canSend, case .known(let name, let handle) = recipient else { return false }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        touch()
        hint = nil
        phase = .sending
        let sender = sighting?.id
        let outcome = await courier.send(name, handle, body)
        // Dismissed or replaced while Messages was working: the result
        // belongs to a card that is gone. Writing it onto whatever is up
        // now would put "Sent to Sam" under Ravi's message.
        guard let sender, sighting?.id == sender else {
            if case .sent = outcome { return true }
            return false
        }
        switch outcome {
        case .sent(let sentTo):
            draft = ""
            phase = .sent(name: sentTo)
            return true
        default:
            // The draft stays exactly as it was. Every line below says
            // what to do with a button, never with a spoken command.
            phase = .failed(Self.explain(outcome))
            return false
        }
    }

    // MARK: - The card's own words

    /// Contacts' answer, as something a card can say. These are NOT the
    /// courier's strings: those were written for a voice path ("Say
    /// text and the fuller name") and reached the first build verbatim,
    /// telling people to speak commands to a card that cannot hear them.
    static func recipient(
        for answer: MessageCourier.Resolution, sender: String
    ) -> Recipient {
        switch answer {
        case .one(let name, let handle):
            return .known(name: name, handle: handle)
        case .many:
            return .cannotReply(
                "More than one person in your Contacts has this name, so Chalant won't guess which. Reply in Messages."
            )
        case .none:
            return .cannotReply(
                "Not in your Contacts, so Chalant can't be sure where a reply would go. Reply in Messages."
            )
        case .denied:
            return .cannotReply(
                "Chalant needs Contacts to know who this is. Turn it on in System Settings, Privacy and Security, Contacts."
            )
        case .unasked:
            return .cannotReply(
                "macOS is asking to let Chalant see Contacts. Allow it and the next message can be answered here."
            )
        case .failed:
            return .cannotReply("Contacts didn't answer just now. Reply in Messages.")
        }
    }

    static func explain(_ outcome: MessageCourier.SendOutcome) -> String {
        switch outcome {
        case .sent:
            return ""
        case .askingPermission:
            return "macOS is asking to let Chalant use Messages. Click Allow, then press Send again. Your words are still here."
        case .blocked:
            return "macOS is blocking Chalant from Messages. Allow it in System Settings, Privacy and Security, Automation, then press Send again."
        case .wakingUp:
            return "Messages is still waking up. Press Send again in a moment."
        case .notSignedIn:
            return "Messages isn't signed in to iMessage on this Mac. Sign in, then press Send again."
        case .stale, .nothingStaged:
            return "That didn't go. Press Send again."
        case .failed:
            return "Messages couldn't send that. Press Send again, or reply in Messages."
        }
    }

    private func cancelTimers() {
        fade?.cancel()
        fade = nil
        hearingTimeout?.cancel()
        hearingTimeout = nil
    }
}
