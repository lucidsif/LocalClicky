import CoreGraphics
import XCTest
@testable import LocalBrainKit

final class MediaRunMachineTests: XCTestCase {
    private let caps = AgentCaps()
    private let link = LinkCandidate(label: "Lucid Dreams", url: "https://www.youtube.com/watch?v=abc", frame: .zero)
    private let direct = DirectResult(videoID: "4fndeDfaWCg", title: "Lucid Dreams")

    private func next(_ state: MediaRunState, _ event: MediaRunEvent, steps: Int = 0) -> MediaRunState {
        MediaRunMachine.next(state, event, caps: caps, stepsTaken: steps)
    }

    private var allEvents: [MediaRunEvent] {
        [.pageLoaded, .pageTimeout, .offDomain, .located(link), .notFound, .consentYes, .consentNo,
         .consentTimeout, .targetConfirmed, .targetChanged, .pressed(.confirmed), .pressed(.noop),
         .watchPageWithPause, .watchPageNoPause, .notWatchPage, .playPressed(.confirmed),
         .userInput, .pushToTalk, .stopButton, .timeUp, .chromeMissing,
         .directFound(direct), .directUnavailable, .videoOpened, .cannotConfirm]
    }

    private var allStates: [MediaRunState] {
        [.searching, .opening, .locating, .asking(link), .askingDirect(direct), .openingVideo(direct), .pressing(link),
         .verifying(attempt: 0), .verifying(attempt: 1),
         .playing, .opened, .handoff(.noResult), .stopped(.declined), .capped(.time)]
    }

    // MARK: - the happy path

    func testHappyPath() {
        var state = MediaRunState.opening
        state = next(state, .pageLoaded)
        XCTAssertEqual(state, .locating)
        state = next(state, .located(link))
        XCTAssertEqual(state, .asking(link))
        state = next(state, .consentYes)
        XCTAssertEqual(state, .pressing(link))
        state = next(state, .targetConfirmed)
        XCTAssertEqual(state, .pressing(link))
        state = next(state, .pressed(.confirmed))
        XCTAssertEqual(state, .verifying(attempt: 0))
        state = next(state, .watchPageWithPause)
        XCTAssertEqual(state, .playing)
    }

    func testDirectHappyPath() {
        var state = MediaRunState.searching
        state = next(state, .directFound(direct))
        XCTAssertEqual(state, .askingDirect(direct))
        state = next(state, .consentYes)
        XCTAssertEqual(state, .openingVideo(direct))
        state = next(state, .videoOpened)
        XCTAssertEqual(state, .verifying(attempt: 0))
        XCTAssertEqual(next(state, .watchPageWithPause), .playing)
        XCTAssertEqual(next(state, .cannotConfirm), .opened)
    }

    func testSearchingFallsBackToThePagePath() {
        XCTAssertEqual(next(.searching, .directUnavailable), .opening)
        XCTAssertEqual(next(.searching, .pageLoaded), .searching)
    }

    func testAskingDirectAnswersLikeAsking() {
        XCTAssertEqual(next(.askingDirect(direct), .consentNo), .stopped(.declined))
        XCTAssertEqual(next(.askingDirect(direct), .consentTimeout), .stopped(.consentTimeout))
        for event in [MediaRunEvent.userInput, .pushToTalk, .stopButton, .offDomain, .pageLoaded] {
            XCTAssertEqual(next(.askingDirect(direct), event), .askingDirect(direct), "\(event)")
        }
    }

    func testOpeningVideo() {
        XCTAssertEqual(next(.openingVideo(direct), .chromeMissing), .handoff(.chromeMissing))
        XCTAssertEqual(next(.openingVideo(direct), .userInput), .stopped(.userInput))
        XCTAssertEqual(next(.openingVideo(direct), .consentYes), .openingVideo(direct))
    }

    func testCannotConfirmMeansOpenedOnlyWhileVerifying() {
        XCTAssertEqual(next(.verifying(attempt: 1), .cannotConfirm), .opened)
        XCTAssertEqual(next(.locating, .cannotConfirm), .locating)
        XCTAssertEqual(next(.verifying(attempt: 0), .notWatchPage), .handoff(.didNotOpen))
    }

    // MARK: - each state

    func testOpening() {
        XCTAssertEqual(next(.opening, .pageTimeout), .handoff(.didNotOpen))
        XCTAssertEqual(next(.opening, .offDomain), .handoff(.offDomain))
        XCTAssertEqual(next(.opening, .chromeMissing), .handoff(.chromeMissing))
    }

    func testLocating() {
        XCTAssertEqual(next(.locating, .notFound), .handoff(.noResult))
        XCTAssertEqual(next(.locating, .offDomain), .handoff(.offDomain))
    }

    func testAsking() {
        XCTAssertEqual(next(.asking(link), .consentNo), .stopped(.declined))
        XCTAssertEqual(next(.asking(link), .consentTimeout), .stopped(.consentTimeout))
    }

    func testAskingIgnoresInputPushToTalkAndOffDomain() {
        for event in [MediaRunEvent.userInput, .pushToTalk, .stopButton, .offDomain] {
            XCTAssertEqual(next(.asking(link), event), .asking(link), "\(event)")
        }
    }

    func testPressing() {
        XCTAssertEqual(next(.pressing(link), .targetChanged), .handoff(.targetChanged))
        XCTAssertEqual(next(.pressing(link), .pressed(.noop)), .verifying(attempt: 0))
    }

    func testVerifyingRetriesOncePressingPlayThenHandsOff() {
        var state = MediaRunState.verifying(attempt: 0)
        state = next(state, .watchPageNoPause)
        XCTAssertEqual(state, .verifying(attempt: 1))
        XCTAssertEqual(next(state, .playPressed(.confirmed)), .verifying(attempt: 1))
        XCTAssertEqual(next(state, .watchPageWithPause), .playing)
        XCTAssertEqual(next(state, .watchPageNoPause), .handoff(.didNotStart))
    }

    func testVerifyingHonoursTheRetryCap() {
        let none = AgentCaps(retriesPerRung: 0)
        XCTAssertEqual(MediaRunMachine.next(.verifying(attempt: 0), .watchPageNoPause, caps: none, stepsTaken: 0),
                       .handoff(.didNotStart))
    }

    func testVerifyingOffTheWatchPage() {
        XCTAssertEqual(next(.verifying(attempt: 0), .notWatchPage), .handoff(.didNotOpen))
        XCTAssertEqual(next(.verifying(attempt: 0), .offDomain), .handoff(.offDomain))
    }

    // MARK: - stops and caps

    func testUserInputAndPushToTalkStopEveryNonFinalNonAskingState() {
        for state in [MediaRunState.searching, .opening, .locating, .pressing(link), .openingVideo(direct),
                      .verifying(attempt: 0)] {
            XCTAssertEqual(next(state, .userInput), .stopped(.userInput), "\(state)")
            XCTAssertEqual(next(state, .pushToTalk), .stopped(.pushToTalk), "\(state)")
            XCTAssertEqual(next(state, .stopButton), .stopped(.stopButton), "\(state)")
        }
    }

    func testTimeUpCapsEveryNonFinalStateIncludingAsking() {
        for state in allStates where !state.isFinal {
            XCTAssertEqual(next(state, .timeUp), .capped(.time), "\(state)")
        }
    }

    func testStepCapAppliesToEveryNonFinalStateAndEvent() {
        for state in allStates where !state.isFinal {
            for event in allEvents where event != .timeUp {
                XCTAssertEqual(next(state, event, steps: caps.maxSteps), .capped(.steps), "\(state) \(event)")
            }
            XCTAssertEqual(next(state, .pageLoaded, steps: caps.maxSteps - 1) == .capped(.steps), false, "\(state)")
        }
    }

    func testFinalStatesAbsorbEveryEvent() {
        for state in allStates where state.isFinal {
            for event in allEvents {
                XCTAssertEqual(next(state, event), state, "\(state) \(event)")
                XCTAssertEqual(next(state, event, steps: 99), state, "\(state) \(event)")
            }
        }
    }

    func testIsFinal() {
        XCTAssertEqual(allStates.filter(\.isFinal).count, 5)
        XCTAssertTrue(MediaRunState.opened.isFinal)
        XCTAssertFalse(MediaRunState.asking(link).isFinal)
        XCTAssertFalse(MediaRunState.askingDirect(direct).isFinal)
    }

    func testUnrelatedEventsLeaveTheStateAlone() {
        XCTAssertEqual(next(.opening, .consentYes), .opening)
        XCTAssertEqual(next(.locating, .pressed(.confirmed)), .locating)
        XCTAssertEqual(next(.pressing(link), .watchPageWithPause), .pressing(link))
        XCTAssertEqual(next(.verifying(attempt: 0), .consentYes), .verifying(attempt: 0))
        XCTAssertEqual(next(.asking(link), .pageLoaded), .asking(link))
    }
}
