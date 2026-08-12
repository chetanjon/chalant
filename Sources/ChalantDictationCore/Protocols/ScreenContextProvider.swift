import Foundation

/// Words visible on screen, as bias candidates.
///
/// Part 2 §5: Screen Recording has no Info.plist key and is granted at the
/// first ScreenCaptureKit call, so this is not to be attempted until the
/// accuracy lift is actually measured. The seam exists now so the measurement
/// can be wired later without touching the pipeline.
public protocol ScreenContextProvider: Sendable {
    func keywords() async -> [String]
}
