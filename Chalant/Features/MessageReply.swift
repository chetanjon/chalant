import Foundation

/// The message waiting on the island, and the reply being spoken into
/// it.
///
/// Three rules, all of them the founder's:
///
/// 1. **It is a moment, not an inbox.** A card waits about half a
///    minute and then goes, the way the banner it came from did. A
///    newer message replaces an older one. The backlog lives in
///    Messages, which is already good at being a backlog.
/// 2. **Nothing leaves without a second press.** The words are shown
///    before they are sent, every time. `MessageCourier` already
///    refuses to send anything it has not read back, and this keeps
///    that promise on the island's side: a draft is staged, seen, and
///    only then confirmed. iMessage cannot unsend by automation, so
///    the press is the whole safety story.
/// 3. **It never guesses who.** A banner names a person, not an
///    address. Contacts decides, through the courier, and several
///    equal matches come back as a refusal rather than a pick. Texting
///    the wrong person is the one failure this feature cannot have.
@MainActor
final class MessageReply: ObservableObject {
    /// Everything the card can be showing, in the order it happens.
    enum Stage: Equatable {
        /// Their message, nothing spoken yet.
        case waiting
        /// Words heard, staged, and read back. One press from sending.
        case drafted(String)
        case sending
        case sent
        /// Why this reply cannot go: no such contact, several of them,
        /// Messages refusing. The card shows this line as written.
        case refused(String)
    }

    /// The doors to Messages, as closures so the card's behaviour can
    /// be tested without sending anybody a text.
    struct Courier {
        var stage: (_ recipient: String, _ body: String) async -> String
        var isStaged: () -> Bool
        var confirm: () async -> String
        var drop: () -> Void

        @MainActor
        static var live: Courier {
            let courier = MessageCourier()
            return Courier(
                stage: { await courier.stage(recipient: $0, body: $1) },
                isStaged: { courier.pending != nil },
                confirm: { await courier.confirmSend() },
                drop: { courier.drop() }
            )
        }
    }

    /// Long enough to read a message and decide, short enough that the
    /// island never becomes something to tidy up. A banner gets about
    /// five seconds; this is the generous version of that, not a new
    /// kind of unread.
    static let life: TimeInterval = 30

    @Published private(set) var sighting: MessageWatch.Sighting?
    @Published private(set) var stage: Stage = .waiting

    private let courier: Courier
    private let life: TimeInterval
    private var fade: DispatchWorkItem?

    init(courier: Courier? = nil, life: TimeInterval = MessageReply.life) {
        self.courier = courier ?? .live
        self.life = life
    }

    var isShowing: Bool { sighting != nil }

    /// A message arrived. Whatever was on the card before is gone:
    /// newest wins, because the older one already had its turn.
    func show(_ sighting: MessageWatch.Sighting, onFade: @escaping () -> Void) {
        courier.drop()
        self.sighting = sighting
        stage = .waiting
        scheduleFade(onFade)
    }

    /// Somebody is talking to the card. The fade stops, because taking
    /// a card away mid-sentence is the rudest thing this could do.
    func holdOpen() {
        fade?.cancel()
        fade = nil
    }

    /// Words came back from dictation. They are staged and read back,
    /// never sent: the next press does that.
    func heard(_ text: String) async {
        guard let sighting else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        holdOpen()
        let answer = await courier.stage(sighting.sender, words)
        stage = courier.isStaged() ? .drafted(words) : .refused(answer)
    }

    /// The second press. Only a drafted reply can be sent, which is
    /// what makes the read-back impossible to skip.
    func send() async -> Bool {
        guard case .drafted = stage else { return false }
        stage = .sending
        let answer = await courier.confirm()
        guard courier.isStaged() == false else {
            // Still staged means it did not go: a grant dialog, or a
            // stale message. The line says which.
            stage = .refused(answer)
            return false
        }
        stage = .sent
        return true
    }

    /// The card goes: dismissed, faded, or done.
    func dismiss() {
        fade?.cancel()
        fade = nil
        courier.drop()
        sighting = nil
        stage = .waiting
    }

    private func scheduleFade(_ onFade: @escaping () -> Void) {
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A draft in progress is not an unattended card. Somebody
            // is mid-reply; let them finish.
            if case .waiting = stage {
                dismiss()
                onFade()
            }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + life, execute: work)
    }
}
