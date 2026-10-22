import XCTest
@testable import LocalBrainKit

final class SpeechMarkSchedulerTests: XCTestCase {
    private typealias Scheduler = SpeechMarkScheduler<String>

    func testConstants() {
        XCTAssertEqual(SpeechMarkTiming.lead, 0.15)
        XCTAssertEqual(SpeechMarkTiming.startTimeout, 1.5)
    }

    func testTagThenSentenceShowsWhenItsClipStarts() {
        var s = Scheduler()
        s.markClosed("circle", at: 10.0)
        let clip = s.sentenceQueued()
        XCTAssertEqual(s.release(at: 10.4), [], "waits for the clip, not the tag")
        s.clipStarted(id: clip, at: 10.6)
        XCTAssertEqual(s.release(at: 10.6), ["circle"])
        XCTAssertFalse(s.hasPending)
    }

    func testClipStartWithLookaheadShowsOneLeadBeforeTheWords() {
        var s = Scheduler()
        s.markClosed("circle", at: 0)
        let clip = s.sentenceQueued()
        s.clipStarted(id: clip, audibleIn: 0.18, at: 1.0)
        XCTAssertEqual(s.release(at: 1.0), [])
        XCTAssertEqual(s.release(at: 1.0 + 0.18 - 0.15 - 0.001), [])
        XCTAssertEqual(s.release(at: 1.0 + 0.18 - 0.15 + 0.001), ["circle"])
    }

    func testLookaheadShorterThanTheLeadShowsAtOnce() {
        var s = Scheduler()
        s.markClosed("circle", at: 0)
        let clip = s.sentenceQueued()
        s.clipStarted(id: clip, audibleIn: 0.1, at: 1.0)
        XCTAssertEqual(s.release(at: 1.0), ["circle"])
    }

    func testTwoBeatsBindToTheirOwnSentences() {
        var s = Scheduler()
        s.markClosed("m1", at: 0.0)
        let c1 = s.sentenceQueued()
        s.markClosed("m2", at: 0.5)
        let c2 = s.sentenceQueued()
        XCTAssertNotEqual(c1, c2)

        s.clipStarted(id: c1, at: 0.7)
        XCTAssertEqual(s.release(at: 0.7), ["m1"])
        XCTAssertEqual(s.release(at: 1.0), [], "m2 waits for the second clip")
        s.clipStarted(id: c2, at: 2.0)
        XCTAssertEqual(s.release(at: 2.0), ["m2"])
    }

    func testTwoTagsBeforeOneSentenceShowTogether() {
        var s = Scheduler()
        s.markClosed("a", at: 0)
        s.markClosed("b", at: 0.1)
        let clip = s.sentenceQueued()
        s.clipStarted(id: clip, at: 0.5)
        XCTAssertEqual(s.release(at: 0.5), ["a", "b"])
    }

    func testSentenceWithNoTagIsIgnored() {
        var s = Scheduler()
        let first = s.sentenceQueued()
        s.markClosed("m", at: 1.0)
        let second = s.sentenceQueued()
        s.clipStarted(id: first, at: 1.1)
        XCTAssertEqual(s.release(at: 1.1), [], "the earlier sentence is not this mark's")
        s.clipStarted(id: second, at: 1.3)
        XCTAssertEqual(s.release(at: 1.3), ["m"])
    }

    func testTagWithNoSentenceShowsAfterTheTimeout() {
        var s = Scheduler()
        s.markClosed("lonely", at: 5.0)
        XCTAssertEqual(s.release(at: 6.49), [])
        XCTAssertEqual(s.nextDueTime, 6.5)
        XCTAssertEqual(s.release(at: 6.5), ["lonely"])
    }

    func testClipThatNeverStartsTimesOut() {
        var s = Scheduler()
        s.markClosed("m", at: 2.0)
        _ = s.sentenceQueued()
        XCTAssertEqual(s.release(at: 3.4), [])
        XCTAssertEqual(s.release(at: 3.5), ["m"])
    }

    func testLateStartAfterTheTimeoutDoesNothingTwice() {
        var s = Scheduler()
        s.markClosed("m", at: 0)
        let clip = s.sentenceQueued()
        XCTAssertEqual(s.release(at: 1.6), ["m"])
        s.clipStarted(id: clip, at: 2.0)
        XCTAssertEqual(s.release(at: 2.0), [])
        XCTAssertEqual(s.releasedCount, 1)
    }

    func testStartBeforeTheTimeoutWinsOverTheTimeout() {
        var s = Scheduler()
        s.markClosed("m", at: 0)
        let clip = s.sentenceQueued()
        s.clipStarted(id: clip, at: 0.3)
        XCTAssertEqual(s.nextDueTime, 0.3)
    }

    func testMarksLeaveInClosingOrderEvenWhenALaterClipStartsFirst() {
        var s = Scheduler()
        s.markClosed("first", at: 0.0)
        let c1 = s.sentenceQueued()
        s.markClosed("second", at: 0.2)
        let c2 = s.sentenceQueued()
        s.clipStarted(id: c2, at: 0.5)
        XCTAssertEqual(s.release(at: 0.5), [], "first has not started and has not timed out")
        s.clipStarted(id: c1, at: 0.6)
        XCTAssertEqual(s.release(at: 0.6), ["first", "second"])
    }

    func testUnrelatedClipStartIsIgnored() {
        var s = Scheduler()
        s.markClosed("m", at: 0)
        _ = s.sentenceQueued()
        s.clipStarted(id: 999, at: 0.1)
        XCTAssertEqual(s.release(at: 0.2), [])
    }

    func testCancelDropsEverythingWaiting() {
        var s = Scheduler()
        s.markClosed("a", at: 0)
        let clip = s.sentenceQueued()
        s.markClosed("b", at: 0.1)
        XCTAssertEqual(s.cancel(), 2)
        s.clipStarted(id: clip, at: 0.2)
        XCTAssertEqual(s.release(at: 5.0), [])
        XCTAssertFalse(s.hasPending)
        XCTAssertEqual(s.closedCount, 2)
        XCTAssertEqual(s.releasedCount, 0)
    }

    func testNothingPendingHasNoDueTime() {
        XCTAssertNil(Scheduler().nextDueTime)
    }

    // MARK: Box

    func testBoxUsesItsClockAndCancelBlocksLaterMarks() {
        let clock = ClockBox()
        let box = SpeechMarkSchedulerBox<String>(firstClipID: 100, clock: { clock.now })
        clock.now = 10
        box.markClosed("m")
        let id = box.sentenceQueued()
        XCTAssertEqual(id, 100)
        clock.now = 10.2
        box.clipStarted(id: id)
        XCTAssertEqual(box.release(), ["m"])
        XCTAssertFalse(box.isDone, "input not finished yet")
        box.finishInput()
        XCTAssertTrue(box.isDone)

        let other = SpeechMarkSchedulerBox<String>(clock: { clock.now })
        other.markClosed("x")
        other.cancel()
        other.markClosed("y")
        XCTAssertTrue(other.isDone)
        XCTAssertEqual(other.closedCount, 1)
        XCTAssertEqual(other.release(), [])
    }

    // MARK: - hold mode (step sketches)

    func testHoldModeKeepsAStepsMarksUntilItsOwnClipStarts() {
        var s = Scheduler(holdsBoundMarks: true)
        // A step sketch closes every step's marks and queues every sentence at once.
        s.markClosed("step1-a", at: 0)
        s.markClosed("step1-b", at: 0)
        let c1 = s.sentenceQueued()
        s.markClosed("step2-a", at: 0)
        let c2 = s.sentenceQueued()
        s.markClosed("step3-a", at: 0)
        let c3 = s.sentenceQueued()

        XCTAssertEqual(s.release(at: 30), [], "no timeout while the clips have not started")
        s.clipStarted(id: c1, at: 31)
        XCTAssertEqual(s.release(at: 31), ["step1-a", "step1-b"])
        XCTAssertEqual(s.release(at: 60), [], "step 2 waits for its sentence")
        s.clipStarted(id: c2, at: 36)
        XCTAssertEqual(s.release(at: 36), ["step2-a"])
        s.clipStarted(id: c3, at: 40)
        XCTAssertEqual(s.release(at: 40), ["step3-a"])
        XCTAssertFalse(s.hasPending)
    }

    func testDefaultModeStillTimesTheSameCaseOut() {
        // The reason hold mode exists: without it step 3 would show during step 1.
        var s = Scheduler()
        s.markClosed("step1", at: 0)
        _ = s.sentenceQueued()
        s.markClosed("step3", at: 0)
        _ = s.sentenceQueued()
        XCTAssertEqual(s.release(at: 1.5), ["step1", "step3"])
    }

    func testHoldModeAClipThatNeverAnnouncesItselfIsOverWhenALaterOneStarts() {
        var s = Scheduler(holdsBoundMarks: true)
        s.markClosed("a", at: 0)
        _ = s.sentenceQueued()
        s.markClosed("b", at: 0)
        let c2 = s.sentenceQueued()
        s.clipStarted(id: c2, at: 5)
        XCTAssertEqual(s.release(at: 5), ["a", "b"])
    }

    func testHoldModeAMarkNoSentenceBoundStillTimesOut() {
        var s = Scheduler(holdsBoundMarks: true)
        s.markClosed("lonely", at: 5)
        XCTAssertEqual(s.release(at: 6.49), [])
        XCTAssertEqual(s.release(at: 6.5), ["lonely"])
    }

    func testFlushEndsTheWaitInOrder() {
        var s = Scheduler(holdsBoundMarks: true)
        s.markClosed("a", at: 0)
        _ = s.sentenceQueued()
        s.markClosed("b", at: 0)
        _ = s.sentenceQueued()
        XCTAssertEqual(s.release(at: 100), [])
        XCTAssertEqual(s.nextDueTime, .infinity)
        s.flush(at: 101)
        XCTAssertEqual(s.release(at: 101), ["a", "b"])
        XCTAssertEqual(s.releasedCount, 2)
    }

    func testBoxPassesHoldModeAndFlush() {
        let clock = ClockBox()
        let box = SpeechMarkSchedulerBox<String>(holdsBoundMarks: true, clock: { clock.now })
        XCTAssertTrue(box.isHolding)
        XCTAssertFalse(SpeechMarkSchedulerBox<String>().isHolding)
        box.markClosed("a")
        let clip = box.sentenceQueued()
        clock.now = 50
        XCTAssertEqual(box.release(), [])
        XCTAssertFalse(box.isSpeechQueued)
        box.markSpeechQueued()
        XCTAssertTrue(box.isSpeechQueued)
        box.finishInput()
        box.flush()
        XCTAssertEqual(box.release(), ["a"])
        box.clipStarted(id: clip)
        XCTAssertTrue(box.isDone)
    }

    func testBoxKeepsStreamOrderUnderConcurrentUse() {
        let box = SpeechMarkSchedulerBox<Int>()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for index in 0..<200 { box.markClosed(index); _ = box.sentenceQueued() }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<200 { _ = box.release() }
        }
        group.wait()
        XCTAssertEqual(box.closedCount, 200)
    }
}

private final class ClockBox: @unchecked Sendable {
    var now: Double = 0
}
