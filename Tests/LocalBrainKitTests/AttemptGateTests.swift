import XCTest
@testable import LocalBrainKit

final class AttemptGateTests: XCTestCase {
    func testFirstCallAttempts() {
        var gate = AttemptGate<Int>(minimumGapSeconds: 0.5)
        XCTAssertTrue(gate.shouldAttempt(1, now: 100))
    }

    func testSuccessIsDoneForever() {
        var gate = AttemptGate<Int>(minimumGapSeconds: 0.5)
        XCTAssertTrue(gate.shouldAttempt(1, now: 100))
        gate.recordSuccess(1)
        XCTAssertFalse(gate.shouldAttempt(1, now: 100.1))
        XCTAssertFalse(gate.shouldAttempt(1, now: 10_000))
    }

    func testFailureRetriesOnlyAfterTheGap() {
        var gate = AttemptGate<Int>(minimumGapSeconds: 0.5)
        XCTAssertTrue(gate.shouldAttempt(1, now: 100))
        XCTAssertFalse(gate.shouldAttempt(1, now: 100.25))
        XCTAssertFalse(gate.shouldAttempt(1, now: 100.49))
        XCTAssertTrue(gate.shouldAttempt(1, now: 100.5))
        // The gap restarts from the latest attempt.
        XCTAssertFalse(gate.shouldAttempt(1, now: 100.75))
        XCTAssertTrue(gate.shouldAttempt(1, now: 101.0))
    }

    func testFailureKeepsRetryingUntilASuccess() {
        var gate = AttemptGate<Int>(minimumGapSeconds: 0.5)
        for step in 0..<5 { XCTAssertTrue(gate.shouldAttempt(1, now: Double(step))) }
        gate.recordSuccess(1)
        XCTAssertFalse(gate.shouldAttempt(1, now: 10))
    }

    func testKeysAreIndependent() {
        var gate = AttemptGate<Int>(minimumGapSeconds: 0.5)
        XCTAssertTrue(gate.shouldAttempt(1, now: 100))
        gate.recordSuccess(1)
        XCTAssertTrue(gate.shouldAttempt(2, now: 100.1))
        XCTAssertFalse(gate.shouldAttempt(2, now: 100.2))
    }

    func testForgetStartsTheKeyOverButLeavesOthers() {
        var gate = AttemptGate<Int>(minimumGapSeconds: 0.5)
        _ = gate.shouldAttempt(1, now: 100)
        gate.recordSuccess(1)
        _ = gate.shouldAttempt(2, now: 100)
        gate.forget(1)
        XCTAssertTrue(gate.shouldAttempt(1, now: 100.1))
        XCTAssertFalse(gate.shouldAttempt(2, now: 100.1))
    }
}
