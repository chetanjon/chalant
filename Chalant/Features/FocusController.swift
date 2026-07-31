import SwiftUI

@MainActor
final class CountdownController: ObservableObject {
    @Published var remaining = 0
    @Published var isActive = false
    /// Fires with the minutes when the countdown runs all the way
    /// down; an early stop never reports.
    var onComplete: ((Int) -> Void)?
    private var timer: Timer?
    private var total = 0
    /// When this countdown is actually due. Ticks were being counted,
    /// one per fire, which meant a Mac that slept owed nothing for the
    /// time it was away: a 25 minute session across a closed lid came
    /// back with 25 minutes still to go. The stopwatch already measures
    /// against the wall clock for the same reason; this does too now.
    private var deadline: Date?

    /// 0...1 through the countdown, for the shared ring treatment.
    var progress: Double {
        guard total > 0 else { return 0 }
        return 1 - Double(remaining) / Double(total)
    }

    func start(minutes: Int) {
        remaining = max(1, minutes) * 60
        total = remaining
        deadline = Date().addingTimeInterval(TimeInterval(remaining))
        isActive = true
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common, not the default mode: a menu held open or a window
        // being resized parks a default-mode timer, and a countdown
        // that stops counting while you look at a menu is a bug you
        // only notice afterwards.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        isActive = false
        remaining = 0
    }

    private func tick() {
        guard let deadline else { return }
        // Derived, never decremented, so a missed or late fire costs
        // nothing and sleeping costs exactly what it should.
        remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        if remaining <= 0 {
            let minutes = total / 60
            stop()
            NSSound.beep()
            onComplete?(minutes)
        }
    }

    var display: String {
        String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

/// A real stopwatch, not a timer in disguise: stop HOLDS the reading
/// on screen, start rolls again from where it stood, and only reset
/// clears it (user, 2026-07-22, "that's a timer not a stopwatch").
/// Time is measured against the wall clock, not tick counts: a Mac
/// that sleeps mid-run still owes the truth on wake (review-caught;
/// counted ticks silently lost every slept second).
@MainActor
final class StopwatchController: ObservableObject {
    /// Visible somewhere: running, or paused with its reading held.
    @Published var isActive = false
    @Published var isRunning = false
    /// UI heartbeat; the reading itself derives from dates.
    @Published private var tick = 0
    private var anchor: Date?
    private var banked = 0
    private var timer: Timer?

    var elapsed: Int {
        banked + (anchor.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0)
    }

    /// Fresh start from idle; resume from a pause.
    func start() {
        if !isActive { banked = 0 }
        anchor = Date()
        isActive = true
        isRunning = true
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick += 1 }
        }
        timer.tolerance = 0.1
        self.timer = timer
    }

    /// The one pause/play flip both buttons share.
    func toggle() {
        if isRunning { pause() } else { start() }
    }

    /// Freeze and hand back the reading; the reading stays on screen.
    @discardableResult
    func pause() -> String {
        banked = elapsed
        anchor = nil
        timer?.invalidate()
        timer = nil
        isRunning = false
        return display
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        isActive = false
        isRunning = false
        anchor = nil
        banked = 0
    }

    var display: String {
        let total = elapsed
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
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

    /// Fires with the work minutes when a work phase runs to zero.
    /// Skip jumps straight to advance() and stop() never gets here,
    /// so neither ever counts.
    var onWorkPhaseComplete: ((Int) -> Void)?

    /// Fires with the round it closed when a break runs to zero on
    /// its own, which now also ends the session. A skipped break
    /// stays silent: the user is present.
    var onBreakComplete: ((Int) -> Void)?

    /// Shared ambience owner, focus drives it, never a private engine.
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

    /// When the current phase is due, nil while paused. Same lesson as
    /// the countdown above: counting ticks meant a Mac that slept owed
    /// nothing for the time it was away.
    private var deadline: Date?

    /// Position within the 4-round pomodoro set, 1-based.
    var roundInSet: Int {
        (cycle - 1) % cyclesPerLongRest + 1
    }

    func start(work: Int = 25) {
        workMinutes = max(1, work)
        cycle = 1
        phase = .work
        beginPhase(seconds: workMinutes * 60)
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
            // Hold the reading; the deadline stops meaning anything
            // until the session is picked back up.
            deadline = nil
            ambience.pause()
        } else {
            deadline = Date().addingTimeInterval(TimeInterval(remaining))
            if phase == .work { ambience.resume() }
        }
    }

    /// Jump to the next phase immediately.
    func skip() {
        guard isActive else { return }
        advance()
    }

    /// Test seam: drag the deadline into the past so the next tick
    /// sees an expired phase, without waiting out real minutes.
    func expirePhaseNow() {
        guard isActive else { return }
        deadline = .distantPast
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        isActive = false
        isPaused = false
        ambience.stop()
    }

    /// Every phase change goes through here so the reading and the
    /// clock it is derived from can never disagree.
    private func beginPhase(seconds: Int) {
        remaining = seconds
        phaseTotal = seconds
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
    }

    private func run() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common so a held-open menu or a live resize cannot park the
        // session, the way the default mode does.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !isPaused, let deadline else { return }
        // Derived, never decremented: a late or missed fire costs
        // nothing, and time asleep costs exactly what it should.
        remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
        guard remaining <= 0 else { return }
        // A phase that runs all the way down ends the session. It used
        // to roll into the next phase, then the next cycle, on its own,
        // forever; a user who stepped away came back to a machine still
        // grinding rounds (user, 2026-07-31). One start, one bout: the
        // next one begins only when the user asks. Skip stays live
        // while a session runs, the user is present when they press it.
        let finishedWork = phase == .work
        stop()
        if finishedWork {
            onWorkPhaseComplete?(workMinutes)
        } else {
            onBreakComplete?(roundInSet)
        }
        NSSound.beep()
    }

    /// Explicit skips only; the clock running out never lands here.
    private func advance() {
        if phase == .work {
            phase = .rest
            let longBreak = cycle % cyclesPerLongRest == 0
            beginPhase(seconds: (longBreak ? longRestMinutes : restMinutes) * 60)
            ambience.pause()
        } else {
            cycle += 1
            phase = .work
            beginPhase(seconds: workMinutes * 60)
            if !isPaused { ambience.resume() }
        }
    }

    var display: String {
        String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
