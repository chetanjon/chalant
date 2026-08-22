import XCTest

@testable import ChalantDictationCore

/// The budget must be real. For three days (2026-08-18 to 08-21) every
/// bounded wait in the dictation pipeline ended within microseconds of the
/// model's reply, whatever the budget said, and it read as executor
/// starvation. It was structure: a task group does not return until every
/// child has finished, and a child awaiting another task's value cannot be
/// cancelled. These tests pin the wait that actually returns at the budget.
final class DeadlineTests: XCTestCase {
    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    func testTheBudgetExpiresWithoutWaitingForTheTask() async {
        let slow = Task<String, Never> {
            try? await Task.sleep(for: .seconds(3))
            return "late"
        }
        let started = ContinuousClock.now
        let value = await Deadline.value(of: slow, within: .milliseconds(100))
        let elapsed = seconds(started.duration(to: .now))
        slow.cancel()
        XCTAssertNil(value)
        // The old wait took the task's full 3 s here. Generous slack for CI.
        XCTAssertLessThan(elapsed, 1.0, "the wait outlived its budget: \(elapsed)s")
    }

    func testAValueInsideTheBudgetComesBackPromptly() async {
        let quick = Task<Int, Never> {
            try? await Task.sleep(for: .milliseconds(50))
            return 7
        }
        let started = ContinuousClock.now
        let value = await Deadline.value(of: quick, within: .seconds(5))
        let elapsed = seconds(started.duration(to: .now))
        XCTAssertEqual(value, 7)
        XCTAssertLessThan(elapsed, 2.0, "waited for the budget instead of the value: \(elapsed)s")
    }

    func testAnAlreadyFinishedTaskComesBackAtOnce() async {
        let done = Task<String, Never> { "done" }
        _ = await done.value
        let value = await Deadline.value(of: done, within: .seconds(5))
        XCTAssertEqual(value, "done")
    }

    func testTheTaskIsNotCancelledByAnExpiredBudget() async {
        // A late cleanup still lands in the polisher's cache for the
        // hearing pass; the budget gives up on waiting, not on the work.
        let late = Task<String, Never> {
            try? await Task.sleep(for: .milliseconds(300))
            return Task.isCancelled ? "cancelled" : "still landed"
        }
        let value = await Deadline.value(of: late, within: .milliseconds(50))
        XCTAssertNil(value)
        let eventually = await late.value
        XCTAssertEqual(eventually, "still landed")
    }
}
