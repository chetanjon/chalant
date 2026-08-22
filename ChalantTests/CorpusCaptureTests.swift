import XCTest

@testable import Chalant

/// The corpus row carries the four texts of the path (schema 3): the
/// transcriber's own text, the text after the deterministic passes, the
/// model's text or why there is none, and the string actually inserted.
/// Written and read back in a temporary folder with its own defaults
/// suite, so no test row ever lands in the founder's real corpus.
final class CorpusCaptureTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-capture-tests-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "com.cj.chalant.tests.corpus.\(UUID().uuidString)")
        CorpusCapture.setEnabled(true, in: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func rows() throws -> [[String: Any]] {
        let manifest = folder.appendingPathComponent("captured.jsonl")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testARowKeepsAllFourTextsAndTheirReasons() async throws {
        let corpus = CorpusCapture(folder: folder, defaults: defaults)
        let audio = await corpus.begin(bundleID: "com.apple.TextEdit")
        XCTAssertNotNil(audio)

        let id = await corpus.finish(
            output: "Send 15, not 50.",
            fedBuffers: 40, finalize: 0.1, insert: 0.02, polish: 0.4,
            polishOutcome: "landed", chunkCount: 1, warmChunks: 1,
            texts: CorpusCapture.Texts(
                asrRaw: "send fifteen um not fifty",
                afterDeterministic: "Send 15, not 50.",
                modelOutput: "Send 15, not 50.",
                modelReason: "landed",
                modelChunks: ["landed"],
                inserted: "Send 15, not 50.",
                insertOutcome: "inserted:systemEvents"))
        XCTAssertNotNil(id)

        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(row["schema"] as? Int, 3)
        XCTAssertEqual(row["asrRaw"] as? String, "send fifteen um not fifty")
        XCTAssertEqual(row["afterDeterministic"] as? String, "Send 15, not 50.")
        XCTAssertEqual(row["modelOutput"] as? String, "Send 15, not 50.")
        XCTAssertEqual(row["modelReason"] as? String, "landed")
        XCTAssertEqual(row["modelChunks"] as? [String], ["landed"])
        XCTAssertEqual(row["inserted"] as? String, "Send 15, not 50.")
        XCTAssertEqual(row["insertOutcome"] as? String, "inserted:systemEvents")
        // The legacy alias the scoring tools read is still the inserted text.
        XCTAssertEqual(row["output"] as? String, "Send 15, not 50.")
    }

    func testARejectedChunkLeavesNullTextAndNamesTheRule() async throws {
        let corpus = CorpusCapture(folder: folder, defaults: defaults)
        _ = await corpus.begin(bundleID: "com.microsoft.VSCode")
        _ = await corpus.finish(
            output: "Do not deploy this to production until Monday.",
            fedBuffers: 40, finalize: 0.1, insert: 0.02, polish: 0.5,
            polishOutcome: "landed", chunkCount: 1, failedChunks: 1,
            texts: CorpusCapture.Texts(
                asrRaw: "do not deploy this to production until Monday",
                afterDeterministic: "Do not deploy this to production until Monday.",
                modelOutput: nil,
                modelReason: "rejected:didNotStutter",
                modelChunks: ["rejected:didNotStutter"],
                inserted: nil,
                insertOutcome: "leftOnClipboard:no landing spot"))

        let row = try XCTUnwrap(try rows().first)
        XCTAssertTrue(row["modelOutput"] is NSNull, "a rejected chunk must store null, not the input")
        XCTAssertEqual(row["modelReason"] as? String, "rejected:didNotStutter")
        XCTAssertTrue(row["inserted"] is NSNull)
        XCTAssertEqual(row["insertOutcome"] as? String, "leftOnClipboard:no landing spot")
    }
}
