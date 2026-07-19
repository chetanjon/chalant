import SwiftUI

@MainActor
final class CountdownController: ObservableObject {
    @Published var remaining = 0
    @Published var isActive = false
    private var timer: Timer?
    private var total = 0

    /// 0...1 through the countdown, for the shared ring treatment.
    var progress: Double {
        guard total > 0 else { return 0 }
        return 1 - Double(remaining) / Double(total)
    }

    func start(minutes: Int) {
        remaining = max(1, minutes) * 60
        total = remaining
        isActive = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isActive = false
        remaining = 0
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            stop()
            NSSound.beep()
        }
    }

    var display: String {
        String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

@MainActor
final class FocusController: ObservableObject {
    enum Phase {
        case work
        case rest
    }

    @Published var isActive = false
    @Published var isPaused = false
    @Published var phase: Phase = .work
    @Published var remaining = 0
    @Published var cycle = 1
    @Published var noiseColor: NoiseEngine.NoiseColor = .brown

    /// Shared ambience owner — focus drives it, never a private engine.
    let ambience: AmbienceController

    init(ambience: AmbienceController) {
        self.ambience = ambience
    }
    private var timer: Timer?
    private(set) var workMinutes = 25
    private let restMinutes = 5
    private let longRestMinutes = 15
    private let cyclesPerLongRest = 4
    private var phaseTotal = 1

    /// 0...1 through the current work or rest phase.
    var progress: Double {
        guard phaseTotal > 0 else { return 0 }
        return 1 - Double(remaining) / Double(phaseTotal)
    }

    /// Position within the 4-round pomodoro set, 1-based.
    var roundInSet: Int {
        (cycle - 1) % cyclesPerLongRest + 1
    }

    func start(work: Int = 25) {
        workMinutes = max(1, work)
        cycle = 1
        phase = .work
        remaining = workMinutes * 60
        phaseTotal = remaining
        isActive = true
        isPaused = false
        // A soundscape the user already chose wins over the default.
        if let playing = ambience.active { noiseColor = playing }
        ambience.play(noiseColor)
        run()
    }

    func setNoise(_ color: NoiseEngine.NoiseColor) {
        noiseColor = color
        if !isActive || phase == .work {
            ambience.play(color)
        }
    }

    func muteNoise() {
        ambience.pause()
    }

    func togglePause() {
        guard isActive else { return }
        isPaused.toggle()
        if isPaused {
            ambience.pause()
        } else if phase == .work {
            ambience.resume()
        }
    }

    /// Jump to the next phase immediately.
    func skip() {
        guard isActive else { return }
        advance()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isActive = false
        isPaused = false
        ambience.stop()
    }

    private func run() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard !isPaused else { return }
        remaining -= 1
        guard remaining <= 0 else { return }
        advance()
        NSSound.beep()
    }

    private func advance() {
        if phase == .work {
            phase = .rest
            let longBreak = cycle % cyclesPerLongRest == 0
            remaining = (longBreak ? longRestMinutes : restMinutes) * 60
            ambience.pause()
        } else {
            cycle += 1
            phase = .work
            remaining = workMinutes * 60
            if !isPaused { ambience.resume() }
        }
        phaseTotal = remaining
    }

    var display: String {
        String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
