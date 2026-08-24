import Foundation
import FoundationModels

// Which executor does a respond starve? A warm respond runs from a detached
// task (as the app's polisher does) while three watchers measure, every 20 ms:
//   main   a block posted to the main queue from a raw thread: time until it runs
//   pool   a Task.detached posted from a raw thread: time until it runs
//   sleep  a Task.sleep(300 ms) started at respond start: time until it wakes
// Why (2026-08-21 verify run): the app's 0.73 s hard deadline waited 1.697 s
// and woke 70 µs after the model replied; the same moment for its inner
// Task.sleep budget and both dispatch-timer legs (main actor and pool).

let passage = "so um I was thinking that we should probably, like, move the review to Thursday because, you know, the draft is not going to be ready and, uh, Priya said she needs one more day for the numbers"

func respondFresh() async -> Double {
    let session = LanguageModelSession(instructions: CleanupPrompt.instructions(for: passage))
    let started = ContinuousClock.now
    _ = try? await session.respond(to: CleanupPrompt.framing(passage)).content
    return started.duration(to: .now).probeSeconds
}
extension Duration { var probeSeconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 } }
func fmt(_ s: Double) -> String { String(format: "%.3f", s) }

final class Gauge: @unchecked Sendable {
    let lock = NSLock()
    var maxMain = 0.0, maxPool = 0.0, posts = 0
    func note(main: Double? = nil, pool: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let main { maxMain = max(maxMain, main) }
        if let pool { maxPool = max(maxPool, pool) }
    }
}
let gauge = Gauge()
var running = true
let watcher = Thread {
    while running {
        let posted = Date()
        DispatchQueue.main.async { gauge.note(main: Date().timeIntervalSince(posted)) }
        Task.detached(priority: .userInteractive) { gauge.note(pool: Date().timeIntervalSince(posted)) }
        Thread.sleep(forTimeInterval: 0.02)
    }
}
watcher.start()

Task.detached {
    let warm = await respondFresh()
    try? await Task.sleep(for: .milliseconds(500))
    let idleMain = gauge.maxMain, idlePool = gauge.maxPool
    gauge.note(main: 0, pool: 0)
    async let sleeper: Double = {
        try? await Task.sleep(for: .milliseconds(100))
        let t0 = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(300), tolerance: .zero)
        return t0.duration(to: .now).probeSeconds
    }()
    let concurrent = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 1 : 1
    let r = await withTaskGroup(of: Double.self) { group -> Double in
        for _ in 0..<concurrent { group.addTask { await respondFresh() } }
        var longest = 0.0
        for await t in group { longest = max(longest, t) }
        return longest
    }
    let slept = await sleeper
    try? await Task.sleep(for: .milliseconds(200))
    running = false
    print("executors x\(concurrent)  warm-up=\(fmt(warm))  longest respond=\(fmt(r))  | idle: main=\(fmt(idleMain)) pool=\(fmt(idlePool))  | during: mainHopMax=\(fmt(gauge.maxMain)) poolHopMax=\(fmt(gauge.maxPool)) sleep300ms woke after=\(fmt(slept))")
    exit(0)
}
dispatchMain()
