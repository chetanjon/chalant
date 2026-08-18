import SwiftUI
import XCTest
@testable import Chalant

/// The first-run tour's shape, and a way to look at a card without driving
/// the island (whose synthetic clicks are unsafe beside a person's browser).
@MainActor
final class WelcomeTourTests: XCTestCase {

    /// Law 5: the dictation card exists only where dictation does. On a Mac
    /// without the engine the tour is the four cards it always was, and the
    /// "debug welcome <n>" hook clamps to the same count.
    func testTheDictationCardExistsOnlyWhereDictationDoes() {
        XCTAssertEqual(WelcomeView.stepCount, Dictation.isSupported ? 5 : 4)
    }

    /// The card names the same gesture Settings does, because both read it
    /// off `VoiceDoor`. If that line ever changes shape, this is the test
    /// that says the tour still tells the truth.
    func testTheGestureLineIsTheOneSettingsShows() throws {
        let line = try XCTUnwrap(VoiceDoor.dictationLine(available: true))
        XCTAssertTrue(line.localizedCaseInsensitiveContains("option"))
        XCTAssertTrue(line.localizedCaseInsensitiveContains("hold"))
    }

    /// Renders the dictation card to a PNG when `CHALANT_TOUR_RENDER` names a
    /// directory, so it can be looked at against the design laws without a
    /// single synthetic click. Skipped otherwise: a test that writes files
    /// nobody asked for is litter.
    func testRenderTheDictationCardForALook() throws {
        guard let dir = ProcessInfo.processInfo.environment["CHALANT_TOUR_RENDER"] else {
            throw XCTSkip("set CHALANT_TOUR_RENDER=<dir> to write the render")
        }
        try XCTSkipUnless(Dictation.isSupported, "no dictation card on this macOS")
        let model = NotchViewModel()
        model.welcomeStep = 2
        let view = WelcomeView(model: model)
            .frame(width: 560)
            .padding(24)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("welcome-dictation-card.png")
        try png.write(to: url)
        XCTAssertGreaterThan(png.count, 10_000)
    }
}
