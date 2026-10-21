import XCTest
@testable import LocalBrainKit

final class WebContentAccessTests: XCTestCase {
    private typealias Access = WebContentAccess<Int>
    private let unsupported = Access.attributeUnsupportedCode
    private let ok = Access.successCode

    func testUnsupportedCodeIsTheChromeAnswerSeenInTheRealRun() {
        XCTAssertEqual(unsupported, -25205)
    }

    func testManualSuccessIsTheWholeStory() {
        var access = Access()
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setManual)
        access.recordManual(code: ok, for: 1)
        XCTAssertEqual(access.mode(for: 1), .manual)
        XCTAssertNil(access.nextAction(for: 1, now: 100))
        XCTAssertNil(access.finish(1, voiceOverOn: false), "nothing was set on AXEnhancedUserInterface, so nothing is restored")
    }

    func testOneTransientManualErrorRetriesAfterTheGapAndStaysOnManual() {
        var access = Access(retryGapSeconds: 0.5)
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setManual)
        access.recordManual(code: -25204, for: 1)
        XCTAssertNil(access.nextAction(for: 1, now: 0.2))
        XCTAssertFalse(access.isSettled(for: 1))
        XCTAssertEqual(access.nextAction(for: 1, now: 0.5), .setManual)
        access.recordManual(code: ok, for: 1)
        XCTAssertEqual(access.mode(for: 1), .manual)
        XCTAssertTrue(access.isSettled(for: 1))
    }

    func testTwoManualCannotCompleteErrorsMoveOnToEnhanced() {
        var access = Access(retryGapSeconds: 0.5)
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setManual)
        access.recordManual(code: -25204, for: 1)
        XCTAssertEqual(access.nextAction(for: 1, now: 0.5), .setManual)
        access.recordManual(code: -25204, for: 1)
        // The second failure ends manual: the next call is the enhanced one, with no further gap.
        XCTAssertEqual(access.nextAction(for: 1, now: 0.5), .setEnhanced(readPreviousFirst: true))
        access.recordPrevious(false, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        XCTAssertEqual(access.mode(for: 1), .enhanced)
        XCTAssertEqual(access.finish(1, voiceOverOn: false), false)
    }

    func testAnyNonZeroCodeCountsAsAManualFailure() {
        var access = Access(retryGapSeconds: 0)
        for code in [Int32(-25211), Int32(-25201)] {
            XCTAssertEqual(access.nextAction(for: 1, now: 0), .setManual)
            access.recordManual(code: code, for: 1)
        }
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setEnhanced(readPreviousFirst: true))
    }

    func testUnsupportedOnTheFirstTryGoesStraightToEnhanced() {
        var access = Access()
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setManual)
        access.recordManual(code: unsupported, for: 1)
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setEnhanced(readPreviousFirst: true))
    }

    func testZeroOnTheFirstTryStaysManual() {
        var access = Access()
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: ok, for: 1)
        XCTAssertNil(access.nextAction(for: 1, now: 0))
        XCTAssertTrue(access.isSettled(for: 1))
    }

    func testManualFailuresAreForgottenAtTheEndOfTheRun() {
        var access = Access(retryGapSeconds: 0)
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: -25204, for: 1)
        _ = access.finish(1, voiceOverOn: false)
        // A new run needs two fresh failures again.
        XCTAssertEqual(access.nextAction(for: 1, now: 1), .setManual)
        access.recordManual(code: -25204, for: 1)
        XCTAssertEqual(access.nextAction(for: 1, now: 1), .setManual)
    }

    func testSettledOnlyWhenACallWorkedOrTheLastResortGaveUp() {
        var access = Access()
        XCTAssertFalse(access.isSettled(for: 1))
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: unsupported, for: 1)
        XCTAssertFalse(access.isSettled(for: 1))
        _ = access.nextAction(for: 1, now: 0)
        access.recordPrevious(false, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: unsupported, for: 1)
        XCTAssertTrue(access.isSettled(for: 1))
    }

    func testUnsupportedMovesToEnhancedAtOnceAndRemembersThePreviousValueFirst() {
        var access = Access()
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setManual)
        access.recordManual(code: unsupported, for: 1)
        // No waiting for the retry gap: the next call is the enhanced one.
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setEnhanced(readPreviousFirst: true))
        access.recordPrevious(false, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        XCTAssertEqual(access.mode(for: 1), .enhanced)
        XCTAssertNil(access.nextAction(for: 1, now: 100), "done: no more calls while the run goes on")
        XCTAssertEqual(access.finish(1, voiceOverOn: false), false)
    }

    func testFinishIsIdempotentAndForgetsTheBrowser() {
        var access = Access()
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: unsupported, for: 1)
        _ = access.nextAction(for: 1, now: 0)
        access.recordPrevious(false, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        XCTAssertEqual(access.finish(1, voiceOverOn: false), false)
        XCTAssertNil(access.finish(1, voiceOverOn: false))
        XCTAssertEqual(access.mode(for: 1), .none)
        // A later run starts from scratch: manual first again, and a new previous value is read.
        XCTAssertEqual(access.nextAction(for: 1, now: 0.1), .setManual)
        access.recordManual(code: unsupported, for: 1)
        XCTAssertEqual(access.nextAction(for: 1, now: 0.1), .setEnhanced(readPreviousFirst: true))
    }

    func testAnAlreadyTrueValueIsNeverChangedOrRestored() {
        var access = Access()
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: unsupported, for: 1)
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setEnhanced(readPreviousFirst: true))
        access.recordPrevious(true, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        XCTAssertNil(access.finish(1, voiceOverOn: false), "VoiceOver had it on, so it stays on")
    }

    func testAnUnreadablePreviousValueCountsAsFalse() {
        var access = Access()
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: unsupported, for: 1)
        _ = access.nextAction(for: 1, now: 0)
        access.recordPrevious(nil, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        XCTAssertEqual(access.finish(1, voiceOverOn: false), false)
    }

    func testAFailedSetRetriesWithoutReadingAgainAndStillRestoresTheFirstValue() {
        var access = Access(retryGapSeconds: 0.5)
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: unsupported, for: 1)
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setEnhanced(readPreviousFirst: true))
        access.recordPrevious(false, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: -25204, for: 1)
        XCTAssertNil(access.nextAction(for: 1, now: 0.2))
        XCTAssertEqual(access.nextAction(for: 1, now: 0.5), .setEnhanced(readPreviousFirst: false))
        // A second report must not overwrite the first (a set that timed out may have landed).
        access.recordPrevious(true, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        XCTAssertEqual(access.finish(1, voiceOverOn: false), false)
    }

    func testEnhancedUnsupportedGivesUpAndRestoresNothing() {
        var access = Access()
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: unsupported, for: 1)
        XCTAssertEqual(access.nextAction(for: 1, now: 0), .setEnhanced(readPreviousFirst: true))
        access.recordPrevious(false, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: unsupported, for: 1)
        XCTAssertNil(access.nextAction(for: 1, now: 100))
        XCTAssertEqual(access.mode(for: 1), .none)
        XCTAssertNil(access.finish(1, voiceOverOn: false))
    }

    func testBrowsersAreIndependent() {
        var access = Access()
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: unsupported, for: 1)
        _ = access.nextAction(for: 1, now: 0)
        access.recordPrevious(false, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        XCTAssertEqual(access.nextAction(for: 2, now: 0), .setManual)
        access.recordManual(code: ok, for: 2)
        XCTAssertEqual(access.mode(for: 1), .enhanced)
        XCTAssertEqual(access.mode(for: 2), .manual)
        XCTAssertNil(access.finish(2, voiceOverOn: false))
        XCTAssertEqual(access.mode(for: 1), .enhanced)
        XCTAssertEqual(access.finish(1, voiceOverOn: false), false)
    }

    func testFinishWithoutAnyCallIsNothing() {
        var access = Access()
        XCTAssertNil(access.finish(7, voiceOverOn: false))
        XCTAssertEqual(access.mode(for: 7), .none)
    }

    func testModeNamesAreTheLoggedWords() {
        XCTAssertEqual([WebContentAccessMode.manual, .enhanced, .none].map(\.rawValue), ["manual", "enhanced", "none"])
    }

    // MARK: - VoiceOver owns the attribute

    private func enhancedRun(previous: Bool?, voiceOverAtStart: Bool) -> Access {
        var access = Access()
        _ = access.nextAction(for: 1, now: 0)
        access.recordManual(code: unsupported, for: 1)
        _ = access.nextAction(for: 1, now: 0)
        access.recordPrevious(previous, voiceOverOn: voiceOverAtStart, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        return access
    }

    func testAnUnreadablePreviousValueCountsAsTrueWhileVoiceOverIsOn() {
        var access = enhancedRun(previous: nil, voiceOverAtStart: true)
        XCTAssertNil(access.finish(1, voiceOverOn: true))
        // Even if VoiceOver is off by the end, it was on at the start, so nothing is set back to false.
        var again = enhancedRun(previous: nil, voiceOverAtStart: true)
        XCTAssertNil(again.finish(1, voiceOverOn: false))
    }

    func testVoiceOverOnAtTheEndSkipsTheRestoreEvenIfItWasOffAtTheStart() {
        var access = enhancedRun(previous: false, voiceOverAtStart: false)
        XCTAssertNil(access.finish(1, voiceOverOn: true))
        XCTAssertNil(access.finish(1, voiceOverOn: false), "and the browser is forgotten")
    }

    func testVoiceOverOnAtTheStartSkipsTheRestoreEvenWhenTheValueReadFalse() {
        var access = enhancedRun(previous: false, voiceOverAtStart: true)
        XCTAssertNil(access.finish(1, voiceOverOn: false))
    }

    func testWithVoiceOverOffTheRestoreStillHappens() {
        var access = enhancedRun(previous: false, voiceOverAtStart: false)
        XCTAssertEqual(access.finish(1, voiceOverOn: false), false)
        var unreadable = enhancedRun(previous: nil, voiceOverAtStart: false)
        XCTAssertEqual(unreadable.finish(1, voiceOverOn: false), false)
    }

    func testVoiceOverAtStartIsForgottenAfterFinish() {
        var access = enhancedRun(previous: nil, voiceOverAtStart: true)
        _ = access.finish(1, voiceOverOn: false)
        _ = access.nextAction(for: 1, now: 1)
        access.recordManual(code: unsupported, for: 1)
        _ = access.nextAction(for: 1, now: 1)
        access.recordPrevious(false, voiceOverOn: false, for: 1)
        access.recordEnhanced(code: ok, for: 1)
        XCTAssertEqual(access.finish(1, voiceOverOn: false), false, "a later run with VoiceOver off restores normally")
    }
}
