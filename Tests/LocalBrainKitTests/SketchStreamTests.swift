import XCTest
@testable import LocalBrainKit

/// A step sketch read while it streams: each step is handed over as soon as it is complete, a tag or a
/// marker cut off at a chunk boundary is never read early, and the result equals the whole-reply parse.
final class SketchStreamTests: XCTestCase {
    private let reply = """
        sure.
        [STEP] pull up beside the car in front, about a door's width away.
        [SHAPE:line:150,720;850,720:curb]
        [SHAPE:polygon:160,600;380,600;380,700;160,700:car behind]
        [SHAPE:polygon:600,470;800,470;800,560;600,560:you]

        [STEP] back up slowly and turn the wheel all the way toward the curb.
        [SHAPE:curve:600,515;520,545;470,610]
        [SHAPE:arrow:520,548;470,590]
        [STEP] straighten the wheel and keep backing in.
        [SHAPE:polygon:390,610;590,610;590,705;390,705:final spot]
        [SHAPE:arrow:500,560;500,650]
        """

    /// Feeds `text` in pieces of `size` characters. Returns the steps with the accumulated length at which
    /// each was handed over, and the stream.
    private func stream(_ text: String, size: Int, maxSteps: Int = SketchLimits.maxSteps,
                        maxTags: Int = SketchLimits.maxStepTags) -> (steps: [(step: SketchStep, at: Int)], stream: SketchStepStream) {
        let stream = SketchStepStream(maxSteps: maxSteps, maxTags: maxTags)
        var emitted: [(step: SketchStep, at: Int)] = []
        var accumulated = ""
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            accumulated += text[index..<end]
            index = end
            for step in stream.feed(accumulated: accumulated) { emitted.append((step, accumulated.count)) }
        }
        for step in stream.finish(accumulated: accumulated) { emitted.append((step, accumulated.count)) }
        return (emitted, stream)
    }

    func testEveryChunkSizeGivesTheSameStepsAsTheWholeReply() {
        let whole = SketchStepParser.parse(reply)
        XCTAssertEqual(whole.steps.count, 3)
        for size in [1, 2, 3, 5, 7, 11, 16, 40, 1000] {
            let result = stream(reply, size: size)
            XCTAssertEqual(result.steps.map(\.step), whole.steps, "chunk size \(size)")
            XCTAssertEqual(result.stream.reply, whole, "chunk size \(size)")
        }
    }

    func testStepOneIsHandedOverBeforeStepTwosTextArrives() throws {
        let secondWords = try XCTUnwrap(reply.range(of: "back up slowly"))
        let thirdWords = try XCTUnwrap(reply.range(of: "straighten the wheel"))
        let secondTextStart = reply.distance(from: reply.startIndex, to: secondWords.lowerBound)
        let thirdTextStart = reply.distance(from: reply.startIndex, to: thirdWords.lowerBound)
        for size in [1, 2, 3, 4, 9] {
            let result = stream(reply, size: size)
            XCTAssertEqual(result.steps.count, 3)
            XCTAssertLessThanOrEqual(result.steps[0].at, secondTextStart + size, "step 1 before step 2's words, chunk \(size)")
            XCTAssertLessThanOrEqual(result.steps[1].at, thirdTextStart + size, "step 2 before step 3's words, chunk \(size)")
            XCTAssertGreaterThan(result.steps[0].at, 0)
        }
    }

    func testAPartialMarkerOrTagIsNeverReadEarly() {
        let stream = SketchStepStream()
        let head = "[STEP] go on.\n[SHAPE:line:100,100;200,200:road]\n"
        XCTAssertEqual(stream.feed(accumulated: head), [], "the step is still open")
        for partial in ["[", "[S", "[STE", "[STEP", "[STEP "] {
            XCTAssertEqual(stream.feed(accumulated: head + partial), [], "marker cut off: \(partial)")
        }
        let done = stream.feed(accumulated: head + "[STEP]")
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].sentence, "go on.")
        XCTAssertEqual(done[0].shapes.count, 1)
        // Half a tag of the next step: nothing, and the half tag is not counted.
        XCTAssertEqual(stream.feed(accumulated: head + "[STEP] then stop.\n[SHAPE:circle:500,500;5"), [])
        let last = stream.finish(accumulated: head + "[STEP] then stop.\n[SHAPE:circle:500,500;5")
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(last[0].sentence, "then stop.")
        XCTAssertTrue(last[0].shapes.isEmpty, "a tag the stream ended in the middle of is not drawn")
        XCTAssertEqual(stream.reply.droppedTags, 0)
    }

    func testAStepIsReturnedOnceAndFinishIsIdempotent() {
        let stream = SketchStepStream()
        let text = "[STEP] one.\n[SHAPE:line:1,1;9,9]\n[STEP] two.\n[SHAPE:line:2,2;8,8]"
        XCTAssertEqual(stream.feed(accumulated: text).count, 1)
        XCTAssertEqual(stream.feed(accumulated: text).count, 0)
        XCTAssertEqual(stream.finish(accumulated: text).count, 1)
        XCTAssertEqual(stream.finish(accumulated: text).count, 0)
        XCTAssertEqual(stream.reply.steps.map(\.sentence), ["one.", "two."])
    }

    func testAReplyWithNoMarkerIsOneStepAtTheEnd() {
        let text = "[SHAPE:circle:500,500;550,500]\nthis is a circle."
        for size in [1, 4, 100] {
            let result = stream(text, size: size)
            XCTAssertEqual(result.steps.count, 1)
            XCTAssertEqual(result.steps.first?.step, SketchStepParser.parse(text).steps.first)
        }
    }

    func testTagsBeforeTheFirstMarkerAreAStepButWordsAreNot() {
        let tagged = "[SHAPE:line:1,1;9,9]\n[STEP] then this."
        let wordsOnly = "ok here goes.\n[STEP] then this."
        for size in [1, 6] {
            XCTAssertEqual(stream(tagged, size: size).steps.map(\.step), SketchStepParser.parse(tagged).steps)
            XCTAssertEqual(stream(tagged, size: size).steps.count, 2)
            XCTAssertEqual(stream(wordsOnly, size: size).steps.map(\.step), SketchStepParser.parse(wordsOnly).steps)
            XCTAssertEqual(stream(wordsOnly, size: size).steps.count, 1)
        }
    }

    func testLimitsMatchTheWholeReplyWhenStreamed() {
        var many = ""
        for index in 1...9 { many += "[STEP] step \(index).\n[SHAPE:line:\(index),1;\(index),9]\n[SHAPE:arrow:1,\(index);9,\(index)]\n" }
        let whole = SketchStepParser.parse(many, maxSteps: 4, maxTags: 5)
        XCTAssertEqual(whole.steps.count, 4)
        XCTAssertGreaterThan(whole.droppedTags, 0)
        for size in [1, 5, 13] {
            let result = stream(many, size: size, maxSteps: 4, maxTags: 5)
            XCTAssertEqual(result.steps.map(\.step), whole.steps, "chunk size \(size)")
            XCTAssertEqual(result.stream.reply, whole, "chunk size \(size)")
        }
    }

    func testInvalidTagsAreCountedTheSameStreamedOrWhole() {
        let text = "[STEP] a.\n[SHAPE:blob:1,1;2,2]\n[HIGHLIGHT:1,1;5,5]\n[SHAPE:line:1,1;9,9]\n[STEP] b.\n[SHAPE:line:2,2;3,3]"
        let whole = SketchStepParser.parse(text)
        XCTAssertEqual(whole.droppedTags, 2)
        XCTAssertEqual(stream(text, size: 3).stream.reply, whole)
    }

    func testTagsButNoSentenceStillNeedTheDrawnSentenceAtTheEnd() {
        let text = "[STEP]\n[SHAPE:line:1,1;9,9]\n[STEP]\n[SHAPE:arrow:2,2;8,8]"
        let result = stream(text, size: 4)
        XCTAssertEqual(result.steps.map(\.step.sentence), ["", ""])
        XCTAssertTrue(SketchStepParser.needsDrawnSentence(result.stream.reply))
        XCTAssertEqual(SketchStepParser.parse(text).steps[0].sentence, SketchLimits.drawnSentence)
        XCTAssertFalse(SketchStepParser.needsDrawnSentence(SketchStepParser.parse(reply)))
    }

    /// The app's order for each handed-over step: close its marks, then queue its sentence. Step 1's marks
    /// show when its clip starts while step 2 has not been read yet, and step 2's never before its own clip.
    func testStreamedStepsBindMarksToTheirOwnSentenceInHoldMode() {
        var scheduler = SpeechMarkScheduler<String>(holdsBoundMarks: true)
        let stream = SketchStepStream()
        var clips: [Int] = []
        var accumulated = ""
        var shown: [String] = []
        var now = 0.0
        func handle(_ steps: [SketchStep]) {
            for step in steps {
                for shape in step.shapes { scheduler.markClosed(shape.label ?? "unlabelled", at: now) }
                if !step.sentence.isEmpty { clips.append(scheduler.sentenceQueued()) }
            }
        }
        // Everything up to the second marker arrives.
        accumulated = "[STEP] first.\n[SHAPE:line:1,1;9,9:one]\n[STEP]"
        handle(stream.feed(accumulated: accumulated))
        XCTAssertEqual(clips.count, 1, "step 1 queued while step 2 is still unwritten")
        XCTAssertEqual(scheduler.release(at: now), [], "not before its clip")
        now = 20
        XCTAssertEqual(scheduler.release(at: now), [], "no timeout in hold mode")
        scheduler.clipStarted(id: clips[0], at: now)
        shown += scheduler.release(at: now)
        XCTAssertEqual(shown, ["one"])
        // Step 2 streams in later; its marks wait for its own clip, which starts after step 1 ends.
        accumulated += " second.\n[SHAPE:line:2,2;8,8:two]\n[STEP] third.\n[SHAPE:line:3,3;7,7:three]"
        handle(stream.feed(accumulated: accumulated))
        handle(stream.finish(accumulated: accumulated))
        XCTAssertEqual(clips.count, 3)
        now = 25
        XCTAssertEqual(scheduler.release(at: now), [], "step 2's marks wait for step 2's clip")
        scheduler.clipStarted(id: clips[1], at: now)
        XCTAssertEqual(scheduler.release(at: now), ["two"])
        scheduler.clipStarted(id: clips[2], at: 30)
        XCTAssertEqual(scheduler.release(at: 30), ["three"])
    }

    // MARK: - the kept badge

    func testTheKeptBadgeTextAndContrast() {
        XCTAssertEqual(KeptBadge.text, "Kept. Say clear to remove.")
        XCTAssertGreaterThanOrEqual(KeptBadge.worstCaseContrast, SketchLabelStyle.requiredContrast)
        XCTAssertFalse(KeptBadge.text.contains("\u{2014}"))
    }

    func testTheBadgeSitsJustBelowTheKeptSketchAndStaysOnScreen() {
        let screen = CGSize(width: 1000, height: 800)
        let sketch = CGRect(x: 300, y: 200, width: 200, height: 300)
        let centre = KeptBadge.position(sketchBounds: sketch, screen: screen)
        XCTAssertEqual(centre.x, 400)
        XCTAssertEqual(centre.y, 500 + KeptBadge.gapBelowSketch + KeptBadge.estimatedHeight / 2)
        // A sketch against the bottom edge: the pill is pulled up onto the screen.
        let low = KeptBadge.position(sketchBounds: CGRect(x: 300, y: 600, width: 200, height: 195), screen: screen)
        XCTAssertLessThanOrEqual(low.y + KeptBadge.estimatedHeight / 2, 800)
        // A sketch against the left edge: pushed in by half the pill's width.
        let left = KeptBadge.position(sketchBounds: CGRect(x: 0, y: 100, width: 20, height: 50), screen: screen)
        XCTAssertGreaterThan(left.x, 100)
        let right = KeptBadge.position(sketchBounds: CGRect(x: 980, y: 100, width: 20, height: 50), screen: screen)
        XCTAssertLessThan(right.x, 900)
    }

    func testTheKeptSketchBoundsCoverEveryPointOfEveryMark() {
        func geometry(_ points: [(Double, Double)]) -> MarkGeometry {
            MarkGeometry(passes: [[MarkSubpath(points: points.map { CGPoint(x: $0.0, y: $0.1) }, isClosed: false)]])
        }
        XCTAssertNil(KeptBadge.bounds(of: []))
        XCTAssertNil(KeptBadge.bounds(of: [MarkGeometry(passes: [[]])]))
        let bounds = KeptBadge.bounds(of: [geometry([(100, 200), (150, 260)]), geometry([(90, 300), (400, 250)])])
        XCTAssertEqual(bounds, CGRect(x: 90, y: 200, width: 310, height: 100))
    }
}
