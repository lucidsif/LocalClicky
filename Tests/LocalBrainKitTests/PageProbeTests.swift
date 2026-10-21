import XCTest
@testable import LocalBrainKit

final class PageProbeTests: XCTestCase {
    // MARK: - Request words

    func testTheFirstWordOfTheRequestFileDecidesTheProbe() {
        XCTAssertEqual(ProbeWord(requestContents: "chrome\n"), .chrome)
        XCTAssertEqual(ProbeWord(requestContents: "  Fastmail please"), .fastmail)
        XCTAssertEqual(ProbeWord(requestContents: "mailto, then"), .mailto)
        XCTAssertEqual(ProbeWord(requestContents: "COMPOSE"), .compose)
    }

    func testAnEmptyOrUnknownRequestIsNoProbe() {
        XCTAssertNil(ProbeWord(requestContents: ""))
        XCTAssertNil(ProbeWord(requestContents: "\n\n"))
        XCTAssertNil(ProbeWord(requestContents: "safari"))
        XCTAssertNil(ProbeWord(requestContents: "please chrome"))
    }

    func testTheMailtoSampleHasNoRecipientAndNothingPrivate() {
        XCTAssertEqual(ProbeSamples.mailtoURL, "mailto:?subject=clicky%20probe&body=clicky%20probe%2C%20safe%20to%20delete")
        XCTAssertTrue(ProbeSamples.mailtoURL.hasPrefix("mailto:?"))
    }

    // MARK: - Matchers

    func testTheAddressBarIsATextFieldNamedForIt() {
        XCTAssertTrue(PageProbeMatcher.isAddressBar(role: "AXTextField", title: nil, description: "Address and search bar"))
        XCTAssertTrue(PageProbeMatcher.isAddressBar(role: "AXTextField", title: "Address bar", description: nil))
        XCTAssertTrue(PageProbeMatcher.isAddressBar(role: "AXTextField", title: nil, description: "Omnibox"))
        XCTAssertFalse(PageProbeMatcher.isAddressBar(role: "AXTextArea", title: nil, description: "Address and search bar"))
        XCTAssertFalse(PageProbeMatcher.isAddressBar(role: "AXTextField", title: "Search mail", description: "To recipients"))
        XCTAssertFalse(PageProbeMatcher.isAddressBar(role: nil, title: nil, description: nil))
    }

    func testTheComposeBodyIsATextAreaDescribedAsMessageBody() {
        XCTAssertTrue(PageProbeMatcher.isComposeBody(role: "AXTextArea", description: "Message Body"))
        XCTAssertTrue(PageProbeMatcher.isComposeBody(role: "AXTextField", description: "message body, edit text"))
        XCTAssertFalse(PageProbeMatcher.isComposeBody(role: "AXButton", description: "Message Body"))
        XCTAssertFalse(PageProbeMatcher.isComposeBody(role: "AXTextArea", description: "Subject"))
        XCTAssertFalse(PageProbeMatcher.isComposeBody(role: "AXTextArea", description: nil))
    }

    func testSavedIndicatorMatchesSavedAndDraftSaved() {
        XCTAssertTrue(PageProbeMatcher.isSavedIndicator("Saved"))
        XCTAssertTrue(PageProbeMatcher.isSavedIndicator("Draft saved"))
        XCTAssertFalse(PageProbeMatcher.isSavedIndicator("Saving..."))
        XCTAssertFalse(PageProbeMatcher.isSavedIndicator(nil))
    }

    // MARK: - Stop reason

    func testAFoundWebAreaIsFoundWhateverElseHappened() {
        XCTAssertEqual(WalkStopReason.decide(foundWebArea: true, stoppedEarly: true, deadlinePassed: true, hitDepthLimit: true), .found)
    }

    func testAnEarlyStopIsTheDeadlineOrTheNodeBudget() {
        XCTAssertEqual(WalkStopReason.decide(foundWebArea: false, stoppedEarly: true, deadlinePassed: true, hitDepthLimit: false), .deadline)
        XCTAssertEqual(WalkStopReason.decide(foundWebArea: false, stoppedEarly: true, deadlinePassed: false, hitDepthLimit: false), .maxNodes)
    }

    func testATreeThatRanOutIsMaxDepthOrExhausted() {
        XCTAssertEqual(WalkStopReason.decide(foundWebArea: false, stoppedEarly: false, deadlinePassed: false, hitDepthLimit: true), .maxDepth)
        XCTAssertEqual(WalkStopReason.decide(foundWebArea: false, stoppedEarly: false, deadlinePassed: false, hitDepthLimit: false), .exhausted)
    }

    func testStopReasonNamesAreTheLoggedWords() {
        XCTAssertEqual([WalkStopReason.found, .maxNodes, .maxDepth, .deadline, .exhausted].map(\.rawValue),
                       ["found", "maxNodes", "maxDepth", "deadline", "exhausted"])
    }

    // MARK: - Telemetry budget

    func testTelemetryIsWrittenAtMostTwicePerSecond() {
        var budget = WalkTelemetryBudget(startedAt: 100)
        XCTAssertTrue(budget.shouldLog(now: 100))
        XCTAssertFalse(budget.shouldLog(now: 100.3))
        XCTAssertTrue(budget.shouldLog(now: 100.5))
    }

    func testTelemetryStopsTenSecondsAfterTheStart() {
        var budget = WalkTelemetryBudget(startedAt: 0)
        XCTAssertTrue(budget.shouldLog(now: 10))
        XCTAssertFalse(budget.shouldLog(now: 10.6))
    }

    func testTelemetryIsCappedAtTwentyEvents() {
        var budget = WalkTelemetryBudget(startedAt: 0)
        var written = 0
        for step in 0..<40 where budget.shouldLog(now: Double(step) * 0.25) { written += 1 }
        XCTAssertEqual(written, 20)
        XCTAssertFalse(budget.shouldLog(now: 9.9))
    }

    // MARK: - Window match

    func testAWindowIsOnScreenWhenACGWindowHasItsBounds() {
        let axFrame = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let cg = [CGRect(x: 0, y: 0, width: 30, height: 30), CGRect(x: 101, y: 50, width: 1199, height: 802)]
        XCTAssertEqual(WindowBoundsMatcher.onScreenBounds(matching: axFrame, among: cg), cg[1])
    }

    func testAWindowWithNoMatchingCGWindowIsNotOnScreen() {
        let axFrame = CGRect(x: 100, y: 50, width: 1200, height: 800)
        XCTAssertNil(WindowBoundsMatcher.onScreenBounds(matching: axFrame, among: [CGRect(x: 100, y: 50, width: 900, height: 800)]))
        XCTAssertNil(WindowBoundsMatcher.onScreenBounds(matching: axFrame, among: []))
        XCTAssertNil(WindowBoundsMatcher.onScreenBounds(matching: .zero, among: [.zero]))
    }

    // MARK: - Result

    func testTheResultJSONAlwaysHasEveryKeyAndUsesNullForUnknowns() {
        let object = ProbeResult(word: "chrome", ts: "2026-10-21T10:00:00Z").jsonObject
        XCTAssertEqual(Set(object.keys), ["word", "ts", "axMode", "codes", "webAreaFound", "webAreaChildCount",
                                          "firstWebAreaMs", "omnibox", "notes"])
        XCTAssertTrue(object["webAreaChildCount"] is NSNull)
        XCTAssertTrue(object["firstWebAreaMs"] is NSNull)
        XCTAssertTrue(object["omnibox"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object))
    }

    func testTheResultJSONCarriesTheValuesItWasGiven() {
        let result = ProbeResult(word: "fastmail", ts: "t", axMode: "manual", codes: [0], webAreaFound: true,
                                 webAreaChildCount: 7, firstWebAreaMs: 420, omnibox: "https://example.com", notes: ["n"])
        let object = result.jsonObject
        XCTAssertEqual(object["webAreaChildCount"] as? Int, 7)
        XCTAssertEqual(object["firstWebAreaMs"] as? Int, 420)
        XCTAssertEqual(object["omnibox"] as? String, "https://example.com")
        XCTAssertEqual(object["codes"] as? [Int], [0])
    }
}
