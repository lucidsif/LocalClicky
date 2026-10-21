import XCTest
@testable import LocalBrainKit

final class AgentRunTests: XCTestCase {
    func testCapsDefaults() {
        let caps = AgentCaps()
        XCTAssertEqual(caps.maxSteps, 8)
        XCTAssertEqual(caps.wallClockSeconds, 45.0)
        XCTAssertEqual(caps.retriesPerRung, 1)
        XCTAssertEqual(caps.consentTimeoutSeconds, 20.0)
        XCTAssertEqual(caps.pageLoadSeconds, 6.0)
        XCTAssertEqual(caps.pageLoadColdSeconds, 15.0)
        XCTAssertEqual(caps.verifySeconds, 6.0)
    }

    func testStepRecordEncodesWithStableKeys() throws {
        let record = StepRecord(runId: "r1", task: "play", index: 2, step: "press", rung: "ax-press",
                                effect: .confirmed, consent: ConsentRecord(shown: true, answer: "yes", millis: 1500),
                                millisSinceStart: 4200, outcome: "ok")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["runId", "task", "index", "step", "rung", "effect", "consent",
                                          "millisSinceStart", "outcome"])
        XCTAssertEqual(object["effect"] as? String, "confirmed")
        let consent = try XCTUnwrap(object["consent"] as? [String: Any])
        XCTAssertEqual(Set(consent.keys), ["shown", "answer", "millis"])
        XCTAssertEqual(try JSONDecoder().decode(StepRecord.self, from: data), record)
    }

    func testOptionalFieldsAreOmittedWhenNil() throws {
        let record = StepRecord(runId: "r1", task: "play", index: 0, step: "open", millisSinceStart: 0, outcome: "ok")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["runId", "task", "index", "step", "millisSinceStart", "outcome"])
    }
}
