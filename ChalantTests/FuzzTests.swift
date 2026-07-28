import XCTest
@testable import Chalant

/// Throwing arbitrary input at everything that parses it.
///
/// Two of the four crashes fixed this month were traps in exactly these
/// functions: a negative Content-Length reaching `Data.prefix`, and an
/// eighteen-digit number reaching a multiply. Both were found by reading
/// carefully. Neither had to be: they are pure functions over untrusted
/// input, which is the one thing a fuzzer is better at than a person.
/// The HTTP parser had even been hardened by hand once already, for the
/// empty-value case, and the negative case was still missed.
///
/// A Swift trap cannot be caught, so a crash here does not fail a test,
/// it takes the whole runner down. That is the intended signal. Every
/// stream is a pure function of its seed, so anything found replays.
@MainActor
final class FuzzTests: XCTestCase {

    /// Every target runs from each of these, so one unlucky stream
    /// cannot pass for coverage.
    ///
    /// Baked in rather than read from the environment on purpose. An
    /// env var set in the shell does not reach the test process under
    /// xcodebuild, and neither does the TEST_RUNNER_ prefix once the
    /// bundle has been built separately. The first version of this file
    /// took its seed that way, ran the identical stream eight times, and
    /// reported eight clean passes. Deterministic and genuinely varied
    /// beats configurable and quietly ignored.
    private static let seeds: [UInt64] = [
        0, 1, 31, 911, 4242, 99991, 123456789, 0xDEADBEEF,
    ]

    private let rounds = 2000

    /// xorshift64. Seeded, and independent of the system generator so a
    /// run on another machine is the same run.
    private struct Rng {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int(next() % span)
        }

        mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
        mutating func chance(_ oneIn: Int) -> Bool { int(1...oneIn) == 1 }
    }

    private func sweep(_ label: String, base: UInt64, _ body: (inout Rng) -> Void) {
        print("[fuzz] \(label): \(Self.seeds.count) seeds x \(rounds)")
        for seed in Self.seeds {
            var rng = Rng(seed: base &+ seed)
            for _ in 0..<rounds { body(&rng) }
        }
    }

    /// Characters chosen to break things: a combining mark that makes
    /// character count differ from scalar count, an RTL override, a
    /// zero-width joiner, a null, grapheme clusters built from several
    /// scalars, and the ascii that matters to these particular parsers.
    private static let nasty: [Character] = [
        "\0", "\n", "\r", "\t", " ", "\"", "\\", ":", "{", "}", "[", "]",
        "-", "+", "0", "9", "e", "%", "/", "\u{0301}", "\u{200D}", "\u{202E}",
        "\u{FEFF}", "é", "日", "🙂", "👨‍👩‍👧‍👦", "\u{1F1EE}\u{1F1F3}",
    ]

    private func noisyString(_ rng: inout Rng, maxLength: Int = 80) -> String {
        let length = rng.int(0...maxLength)
        var out = ""
        for _ in 0..<length {
            if rng.chance(3) {
                out.append(Self.nasty[rng.int(0...(Self.nasty.count - 1))])
            } else {
                out.unicodeScalars.append(UnicodeScalar(UInt8(rng.int(32...126))))
            }
        }
        return out
    }

    /// Digit runs at and around every boundary that has already bitten:
    /// Int64's edge, the clamp, and lengths that overflow a multiply.
    private func numeric(_ rng: inout Rng) -> String {
        let shapes: [String] = [
            "\(Int.max)", "\(Int.min)", "9223372036854775808",
            "99999999999999999999999999", "100000", "100001", "-1", "-0",
            "0", "007", "2147483648", "4294967296",
            String(repeating: "9", count: rng.int(1...40)),
            String(repeating: "0", count: rng.int(1...30)) + "\(rng.int(0...99))",
        ]
        let verbs = ["timer", "focus", "volume", "push standup by", "remind me in", ""]
        return "\(rng.pick(verbs)) \(rng.pick(shapes)) \(rng.pick(["", "hours", "minutes", "%"]))"
    }

    // MARK: The localhost parser, which anything on the machine reaches

    private func httpRequest(_ rng: inout Rng) -> Data {
        let methods = ["GET", "POST", "DELETE", "PUT", "", "P\u{0}ST",
                       String(repeating: "A", count: rng.int(0...200))]
        let paths = ["/activity", "/activities",
                     "/activity/" + noisyString(&rng, maxLength: 20),
                     "", "/", noisyString(&rng, maxLength: 40)]
        // The field that has already taken the app down once.
        let lengths = ["-1", "-9223372036854775808", "\(Int.max)", "0", "",
                       "   ", "abc", "1e9", "+5", "999999999999999999999",
                       "\(rng.int(0...2000))", "-\(rng.int(0...2000))"]

        var head = "\(rng.pick(methods)) \(rng.pick(paths)) HTTP/1.1"
        if rng.chance(2) { head += "\r\nContent-Length: \(rng.pick(lengths))" }
        if rng.chance(4) { head += "\r\nContent-Length:" }
        if rng.chance(3) { head += "\r\nOrigin: \(noisyString(&rng, maxLength: 30))" }
        if rng.chance(4) { head += "\r\nSec-Fetch-Mode: cors" }
        if rng.chance(3) { head += "\r\nX-Chalant-Token: \(noisyString(&rng, maxLength: 50))" }
        if rng.chance(5) { head += "\r\n" + noisyString(&rng, maxLength: 60) }

        let body: String
        switch rng.int(0...3) {
        case 0: body = ""
        case 1: body = #"{"id":"a","title":"b","state":"working"}"#
        case 2: body = "{" + noisyString(&rng, maxLength: 60)
        default: body = noisyString(&rng, maxLength: 120)
        }

        // Sometimes a whole request, sometimes a truncated one, sometimes
        // bytes that were never a request at all.
        switch rng.int(0...5) {
        case 0:
            var bytes = Data()
            for _ in 0...rng.int(0...300) { bytes.append(UInt8(rng.int(0...255))) }
            return bytes
        case 1:
            return Data(head.utf8)
        default:
            return Data("\(head)\r\n\r\n\(body)".utf8)
        }
    }

    func testFuzzTheLocalhostRequestParser() {
        sweep("localhost parser", base: 0xC0FFEE_1234) { rng in
            let data = httpRequest(&rng)
            guard let request = ActivityServer.parse(data) else { return }
            // Whatever it accepts must hold the promises route() leans
            // on, or route() is simply the next thing to trap.
            XCTAssertLessThanOrEqual(request.body.count, ActivityServer.maxBody)
            XCTAssertLessThanOrEqual(request.body.count, data.count)
            XCTAssertFalse(request.method.contains(" "))
        }
    }

    func testFuzzActivityStringCapping() {
        sweep("activity capping", base: 0x5EED_0002) { rng in
            let title = noisyString(&rng, maxLength: 400)
            let detail = rng.chance(4) ? nil : noisyString(&rng, maxLength: 900)
            let id = rng.chance(3) ? nil : noisyString(&rng, maxLength: 300)
            let capped = ActivityServer.capped(title: title, detail: detail, id: id)
            XCTAssertLessThanOrEqual(capped.title.count, ActivityServer.maxTitle)
            XCTAssertLessThanOrEqual(capped.detail?.count ?? 0, ActivityServer.maxDetail)
            // The id falls back to the title, and must not carry the
            // title's wider allowance in with it.
            XCTAssertLessThanOrEqual(capped.id.count, ActivityServer.maxID)
        }
    }

    func testFuzzTokenComparisonAgreesWithEquality() {
        // A constant-time compare that disagrees with == is either a
        // lock-out or an open door, and both are silent.
        sweep("token compare", base: 0x5EED_0003) { rng in
            let real = noisyString(&rng, maxLength: 44)
            let offered = rng.chance(3) ? real : noisyString(&rng, maxLength: 44)
            XCTAssertEqual(
                ActivityServer.tokenMatches(offered, real),
                !real.isEmpty && offered == real
            )
        }
    }

    // MARK: Everything a voice session can put in front of the verbs

    func testFuzzTheVerbParsers() {
        sweep("verb parsers", base: 0x5EED_0004) { rng in
            let raw = rng.chance(3) ? numeric(&rng) : noisyString(&rng, maxLength: 120)
            let lower = raw.lowercased()

            _ = ActionEngine.sanitized(raw)
            _ = ActionEngine.strippedOfPleasantries(raw)
            _ = ActionEngine.isSessionQuestion(lower)
            _ = ActionEngine.volumeIntent(lower)
            _ = ActionEngine.textingPrefix(of: lower)
            _ = ActionEngine.sendVerdict(lower)
            _ = MessageCourier.literalHandle(raw)
            _ = AIService.rescueParaphrase(raw)

            // Every caller turns this into seconds by multiplying, so
            // the clamp is the only thing between a spoken number and
            // an overflow trap.
            if let number = ActionEngine.firstNumber(in: raw) {
                XCTAssertLessThanOrEqual(number, 100_000)
                XCTAssertGreaterThanOrEqual(number, 0)
                _ = number * 3600
                _ = number * 60
            }
        }
    }

    func testFuzzRedactionNeverLeaksAMessageBody() {
        // The trail is written to preferences and rotates rather than
        // clearing, so anything kept here is kept for good.
        let prefixes = ["text ", "tell ", "message ", "imessage ", "send ",
                        "note: ", "timer ", ""]
        sweep("voice log redaction", base: 0x5EED_0005) { rng in
            let secret = "zqx\(rng.int(100000...999999))"
            // Sometimes with a recipient, sometimes without: the second
            // shape is what found the leak, because the body's first
            // word was being promoted to recipient and kept.
            let name = rng.chance(3) ? "" : noisyString(&rng, maxLength: 12)
            let raw = "\(rng.pick(prefixes))\(name) \(secret)"
            let (heard, outcome) = NotchViewModel.redactedForLog(
                heard: raw,
                outcome: "To Someone: \u{201C}\(secret) \(noisyString(&rng, maxLength: 20))\u{201D}."
                    + " Say send, or anything else to drop it."
            )
            if ActionEngine.textingPrefix(of: raw.lowercased()) != nil {
                XCTAssertFalse(heard.contains(secret), "leaked from: \(raw)")
            }
            // The read-back quotes the body whatever the utterance was.
            XCTAssertFalse(outcome.contains(secret), "read-back leaked: \(raw)")
        }
    }

    func testFuzzCrashReportReader() {
        // Runs at launch over a file written by a dying process, so it
        // must never become the second crash.
        sweep("crash report reader", base: 0x5EED_0006) { rng in
            var text = noisyString(&rng, maxLength: 200)
            if rng.chance(3) { text = "Swift runtime failure: " + text }
            if rng.chance(4) { text = #"{"reason":""# + text }
            if rng.chance(5) { text = #"{"indicator":""# + text }
            let reason = CrashWatch.reason(inReportText: text)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertLessThan(reason.count, 400)
        }
    }
}
