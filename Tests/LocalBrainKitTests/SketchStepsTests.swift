import CryptoKit
import XCTest
@testable import LocalBrainKit

final class SketchStepsTests: XCTestCase {
    /// A recorded-style reply for "sketch out how to do parallel parking": 3 steps, 9 tags, 4 labels, with the
    /// untidiness a small model adds (a blank line, a preamble word, a label that is too long).
    private let parallelParking = """
        sure.
        [STEP] pull up beside the car in front, about a door's width away.
        [SHAPE:line:150,720;850,720:curb]
        [SHAPE:polygon:160,600;380,600;380,700;160,700:car behind]
        [SHAPE:polygon:620,600;840,600;840,700;620,700:car in front of you right now]
        [SHAPE:polygon:600,470;800,470;800,560;600,560:you]

        [STEP] back up slowly and turn the wheel all the way toward the curb.
        [SHAPE:curve:600,515;520,545;470,610]
        [SHAPE:arrow:520,548;470,590]
        [STEP] when you are at a 45 degree angle, straighten the wheel and keep backing in.
        [SHAPE:polygon:390,610;590,610;590,705;390,705]
        [SHAPE:arrow:500,560;500,650]
        [SHAPE:circle:490,655;510,655]
        """

    func testParallelParkingParsesIntoThreeStepsWithTheirOwnTags() throws {
        let reply = SketchStepParser.parse(parallelParking)
        XCTAssertEqual(reply.steps.count, 3)
        XCTAssertEqual(reply.steps.map { $0.shapes.count }, [4, 2, 3])
        XCTAssertEqual(reply.tagCount, 9)
        XCTAssertEqual(reply.labelCount, 4)
        XCTAssertEqual(reply.droppedTags, 0)
        XCTAssertEqual(reply.steps[0].sentence, "pull up beside the car in front, about a door's width away.")
        XCTAssertEqual(reply.steps[1].sentence, "back up slowly and turn the wheel all the way toward the curb.")
        XCTAssertEqual(reply.steps[2].sentence, "when you are at a 45 degree angle, straighten the wheel and keep backing in.")
        XCTAssertEqual(reply.steps[0].shapes.map(\.kind), [.line, .polygon, .polygon, .polygon])
        XCTAssertEqual(reply.steps[1].shapes.map(\.kind), [.curve, .arrow])
        XCTAssertEqual(reply.steps[2].shapes.map(\.kind), [.polygon, .arrow, .circle])
        XCTAssertEqual(reply.steps[0].shapes.map(\.label), ["curb", "car behind", "car in front of", "you"])
        XCTAssertNil(reply.steps[1].shapes[0].label)
        XCTAssertEqual(reply.steps[0].shapes[0].points, [CGPoint(x: 150, y: 720), CGPoint(x: 850, y: 720)])
    }

    func testALabelIsCutToFourWords() {
        let reply = SketchStepParser.parse("[STEP] here.\n[SHAPE:line:200,200;800,200:one two three four five six]")
        XCTAssertEqual(reply.steps[0].shapes[0].label, "one two three four")
    }

    func testTagsPastTheTotalAreDroppedNotGuessed() {
        var text = ""
        for step in 1...4 { // 4 steps of 8 tags: 32 tags, 24 allowed
            text += "[STEP] step \(step).\n"
            for index in 0..<8 { text += "[SHAPE:line:\(200 + index),200;\(300 + index),\(step)00]\n" }
        }
        let reply = SketchStepParser.parse(text)
        XCTAssertEqual(reply.tagCount, SketchLimits.maxStepTags)
        XCTAssertEqual(reply.droppedTags, 8)
        XCTAssertEqual(reply.steps.map { $0.shapes.count }, [8, 8, 8, 0], "the first 24 tags in written order stay")
        XCTAssertEqual(reply.steps[3].sentence, "step 4.", "the step that lost its tags is still spoken")
    }

    func testStepsPastTheLimitAreDropped() {
        var text = ""
        for step in 1...8 { text += "[STEP] step \(step).\n[SHAPE:line:200,200;800,\(step)00]\n" }
        let reply = SketchStepParser.parse(text)
        XCTAssertEqual(reply.steps.count, SketchLimits.maxSteps)
        XCTAssertEqual(reply.tagCount, SketchLimits.maxSteps)
        XCTAssertEqual(reply.droppedTags, 2)
        XCTAssertEqual(reply.steps.last?.sentence, "step 6.")
    }

    func testInvalidTagsAndHighlightsAreDroppedAndCounted() {
        let text = "[STEP] a.\n[SHAPE:line:200,200]\n[SHAPE:blob:1,1;2,2]\n[HIGHLIGHT:100,100,200,200]\n[SHAPE:line:200,200;800,200:ok]"
        let reply = SketchStepParser.parse(text)
        XCTAssertEqual(reply.tagCount, 1)
        XCTAssertEqual(reply.droppedTags, 3)
    }

    func testAReplyWithNoMarkerIsOneStep() {
        // The old shape: tags, then one sentence.
        let reply = SketchStepParser.parse("[SHAPE:polygon:350,500;650,500;650,750;350,750]\n[SHAPE:polygon:330,500;500,350;670,500]\nhere is a small house.")
        XCTAssertEqual(reply.steps.count, 1)
        XCTAssertEqual(reply.steps[0].shapes.count, 2)
        XCTAssertEqual(reply.steps[0].sentence, "here is a small house.")
    }

    func testMarkerVariantsAndTagsBeforeTheFirstMarker() {
        let reply = SketchStepParser.parse("[SHAPE:line:200,200;800,200]\n[step 1] first.\n[SHAPE:line:200,300;800,300]\n[STEP:2] second.")
        XCTAssertEqual(reply.steps.count, 3)
        XCTAssertEqual(reply.steps.map(\.sentence), ["", "first.", "second."])
        XCTAssertEqual(reply.steps.map { $0.shapes.count }, [1, 1, 0])
    }

    func testTagsWithNoSentenceGetTheDrawnSentence() {
        let reply = SketchStepParser.parse("[STEP]\n[SHAPE:line:200,200;800,200]")
        XCTAssertEqual(reply.steps.count, 1)
        XCTAssertEqual(reply.steps[0].sentence, SketchLimits.drawnSentence)
    }

    func testATagCutOffByTheTokenCapIsNotSpoken() {
        let reply = SketchStepParser.parse("[STEP] here is a line.\n[SHAPE:line:200,200;800,200]\n[STEP] and more.\n[SHAPE:line:200,300;8")
        XCTAssertEqual(reply.steps.map(\.sentence), ["here is a line.", "and more."])
        XCTAssertEqual(reply.tagCount, 1)
    }

    func testAReplyWithNoValidTagIsEmpty() {
        XCTAssertTrue(SketchStepParser.parse("i cannot do that").isEmpty)
        XCTAssertTrue(SketchStepParser.parse("").isEmpty)
        XCTAssertTrue(SketchStepParser.parse("[STEP] hmm.\n[SHAPE:line:1]").isEmpty)
    }

    // MARK: the prompt

    func testTheStepPromptsExampleIsTheFixtureShape() {
        let prompt = SketchPrompts.stepSketch
        let example = prompt.components(separatedBy: "\"sketch out how to do parallel parking\":\n").last ?? ""
        let reply = SketchStepParser.parse(example)
        XCTAssertEqual(reply.steps.count, 3)
        XCTAssertEqual(reply.tagCount, 9)
        XCTAssertEqual(reply.labelCount, 4)
        XCTAssertEqual(reply.droppedTags, 0)
        // The whole figure is inside the 150..850 box the prompt asks for.
        for point in reply.steps.flatMap(\.shapes).flatMap(\.points) {
            XCTAssertTrue((150...850).contains(point.x) && (150...850).contains(point.y), "\(point)")
        }
    }

    func testTheStepPromptStatesTheLimitsAndHasNoDashesOrNewTag() {
        let prompt = SketchPrompts.stepSketch
        XCTAssertTrue(prompt.contains("0 to 1000"))
        XCTAssertTrue(prompt.contains("between 150 and 850"))
        XCTAssertTrue(prompt.contains("never more than \(SketchLimits.maxSteps)"))
        XCTAssertTrue(prompt.contains("at most \(SketchLimits.maxStepTags) tags"))
        XCTAssertTrue(prompt.contains("at most \(SketchLimits.maxLabelWords) words"))
        XCTAssertFalse(prompt.contains("HIGHLIGHT"))
        XCTAssertFalse(prompt.contains("[LABEL"))
        XCTAssertFalse(prompt.contains("\u{2014}"))
        XCTAssertFalse(prompt.contains("\u{2013}"))
    }

    func testTheOldSketchPromptIsStillThere() {
        // LocalPrompts.swift is pinned by sha256 elsewhere; the step prompt is a separate string.
        XCTAssertNotEqual(SketchPrompts.stepSketch, LocalPrompts.screenSketchResponse)
    }

    // MARK: labels

    private func overlay(_ kind: ShapeKind, _ points: [(Double, Double)]) -> OverlayDrawing {
        .shape(kind: kind, points: points.map { CGPoint(x: $0.0, y: $0.1) })
    }

    func testALabelSitsAboveTheTopEdgeOfAClosedShapeAndAtTheCentreOfALine() throws {
        let bounds = CGSize(width: 1000, height: 800)
        let polygon = try XCTUnwrap(SketchLabelPlacement.label(for: overlay(.polygon, [(400, 300), (600, 300), (600, 400), (400, 400)]),
                                                              text: "you", bounds: bounds))
        XCTAssertEqual(polygon.position.x, 500)
        XCTAssertEqual(polygon.position.y, 300 - SketchLabelPlacement.gapAboveTopEdge)
        let circle = try XCTUnwrap(SketchLabelPlacement.label(for: overlay(.circle, [(500, 500), (550, 500)]), text: "spot", bounds: bounds))
        XCTAssertEqual(circle.position.y, 500 - 50 - SketchLabelPlacement.gapAboveTopEdge)
        let line = try XCTUnwrap(SketchLabelPlacement.label(for: overlay(.line, [(100, 600), (500, 600)]), text: "curb", bounds: bounds))
        XCTAssertEqual(line.position, CGPoint(x: 300, y: 600))
        let curve = try XCTUnwrap(SketchLabelPlacement.label(for: overlay(.curve, [(100, 200), (200, 100), (300, 200)]), text: "path", bounds: bounds))
        XCTAssertEqual(curve.position, CGPoint(x: 200, y: 100 - SketchLabelPlacement.gapAboveTopEdge))
    }

    func testALabelStaysOnTheScreenAndEmptyOnesAreNil() {
        let bounds = CGSize(width: 1000, height: 800)
        let nearTop = SketchLabelPlacement.label(for: overlay(.polygon, [(5, 2), (50, 2), (50, 40)]), text: "edge", bounds: bounds)
        XCTAssertEqual(Double(nearTop?.position.y ?? -1), SketchLabelPlacement.verticalMargin)
        XCTAssertGreaterThan(nearTop?.position.x ?? 0, 20, "pushed in from the left edge by half its width")
        let farRight = SketchLabelPlacement.label(for: overlay(.line, [(990, 400), (1000, 400)]), text: "right side", bounds: bounds)
        XCTAssertLessThan(farRight?.position.x ?? 2000, 1000 - 20)
        XCTAssertNil(SketchLabelPlacement.label(for: overlay(.line, [(1, 1), (2, 2)]), text: nil, bounds: bounds))
        XCTAssertNil(SketchLabelPlacement.label(for: overlay(.line, [(1, 1), (2, 2)]), text: "  ", bounds: bounds))
        XCTAssertNil(SketchLabelPlacement.label(for: .highlight(rect: CGRect(x: 1, y: 1, width: 5, height: 5)), text: "x", bounds: bounds))
    }

    func testTheLabelBackingGivesAtLeast45To1OnAnyBackground() {
        XCTAssertGreaterThanOrEqual(SketchLabelStyle.worstCaseContrast, SketchLabelStyle.requiredContrast)
        XCTAssertGreaterThan(SketchLabelStyle.worstCaseContrast, 10)
    }
}
