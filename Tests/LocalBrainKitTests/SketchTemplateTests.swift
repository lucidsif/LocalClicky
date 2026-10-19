import XCTest
@testable import LocalBrainKit

final class SketchTemplateTests: XCTestCase {
    private let sizes = [(1152, 720), (1152, 749), (1152, 648), (720, 1152)]

    private func shape(_ drawing: InkDrawing) -> ShapeTag {
        guard case .shape(let tag) = drawing else { fatalError("a sketch holds shapes only") }
        return tag
    }

    private func ticTacToe(_ board: String = SketchTemplate.defaultBoard, width: Int = 1152, height: Int = 720) -> SketchPlan {
        SketchTemplate.plan(.ticTacToe, imageWidth: width, imageHeight: height, board: board)!
    }

    func testTicTacToeIsAGridThenTheMovesInPlayOrder() {
        let kinds = ticTacToe().drawings.map { shape($0).kind }
        XCTAssertEqual(kinds, [.line, .line, .line, .line, .line, .line, .circle, .line, .line])
    }

    func testTheGridIsASquareOfHalfTheShorterSideInTheMiddle() {
        let lines = ticTacToe().drawings.prefix(4).map { shape($0).points }
        // 1152x720: a 360 px board, cells of 120 px, centred.
        XCTAssertEqual(lines[0], [CGPoint(x: 516, y: 180), CGPoint(x: 516, y: 540)])
        XCTAssertEqual(lines[1], [CGPoint(x: 636, y: 180), CGPoint(x: 636, y: 540)])
        XCTAssertEqual(lines[2], [CGPoint(x: 396, y: 300), CGPoint(x: 756, y: 300)])
        XCTAssertEqual(lines[3], [CGPoint(x: 396, y: 420), CGPoint(x: 756, y: 420)])
    }

    func testTheVerticalsSitAtThirdsOfTheHorizontalsSpan() {
        for (width, height) in sizes {
            let lines = ticTacToe(width: width, height: height).drawings.prefix(4).map { shape($0).points }
            let left = lines[2][0].x, right = lines[2][1].x
            XCTAssertEqual(lines[0][0].x, left + (right - left) / 3, accuracy: 0.5)
            XCTAssertEqual(lines[1][0].x, left + 2 * (right - left) / 3, accuracy: 0.5)
            let top = lines[0][0].y, bottom = lines[0][1].y
            XCTAssertEqual(lines[2][0].y, top + (bottom - top) / 3, accuracy: 0.5)
            XCTAssertEqual(lines[3][0].y, top + 2 * (bottom - top) / 3, accuracy: 0.5)
        }
    }

    func testEachXStaysInsideItsCellAndTheOHasItsRingPointRightOfItsCentre() {
        let drawings = ticTacToe().drawings
        let cell = CGRect(x: 396, y: 180, width: 120, height: 120)   // top left
        let centreCell = CGRect(x: 516, y: 300, width: 120, height: 120)
        let bottomRight = CGRect(x: 636, y: 420, width: 120, height: 120)
        for (indices, rect) in [([4, 5], centreCell), ([7, 8], bottomRight)] {
            for index in indices {
                for point in shape(drawings[index]).points { XCTAssertTrue(rect.contains(point), "\(index) \(point)") }
            }
        }
        let ring = shape(drawings[6])
        XCTAssertEqual(ring.kind, .circle)
        XCTAssertTrue(cell.contains(ring.points[0]))
        XCTAssertTrue(cell.contains(ring.points[1]))
        XCTAssertGreaterThan(ring.points[1].x, ring.points[0].x)
        XCTAssertEqual(ring.points[1].y, ring.points[0].y)
    }

    func testEveryPointIsInsideTheImageForEveryFigureAndSize() {
        let figures: [SketchFigure] = [.ticTacToe, .box, .line, .arrow, .circle, .triangle, .star, .smiley, .cross, .check]
        for (width, height) in sizes {
            let frame = CGRect(x: 0, y: 0, width: width, height: height)
            for figure in figures {
                let plan = SketchTemplate.plan(figure, imageWidth: width, imageHeight: height, board: "XOXOXOXOX")!
                XCTAssertFalse(plan.drawings.isEmpty)
                for drawing in plan.drawings {
                    for point in shape(drawing).points {
                        XCTAssertTrue(frame.contains(point), "\(figure) \(width)x\(height) \(point)")
                    }
                }
            }
        }
    }

    func testAnEmptyBoardIsJustTheGrid() {
        XCTAssertEqual(ticTacToe("....").drawings.count, 4)
        XCTAssertEqual(ticTacToe(".........").drawings.count, 4)
        XCTAssertEqual(ticTacToe("....").spokenSentence, "here is a tic tac toe board in the middle of your screen, with no moves yet.")
    }

    func testTheSentenceNamesEveryMoveByItsCell() {
        XCTAssertEqual(ticTacToe().spokenSentence,
                       "here is a tic tac toe board in the middle of your screen, with an x in the centre, an o in the top left and an x in the bottom right.")
        XCTAssertEqual(ticTacToe("....X....").spokenSentence,
                       "here is a tic tac toe board in the middle of your screen, with an x in the centre.")
    }

    func testSmileyHasAFaceTwoEyesAndAMouthBelowTheEyes() {
        let drawings = SketchTemplate.plan(.smiley, imageWidth: 1152, imageHeight: 720)!.drawings
        XCTAssertEqual(drawings.map { shape($0).kind }, [.circle, .circle, .circle, .curve])
        let eyeY = shape(drawings[1]).points[0].y
        for point in shape(drawings[3]).points { XCTAssertGreaterThan(point.y, eyeY) }
    }

    func testEverySentenceNamesTheFigureAndIsLowercaseWithoutDashes() {
        let figures: [SketchFigure] = [.ticTacToe, .box, .line, .arrow, .circle, .triangle, .star, .smiley, .cross, .check]
        for figure in figures {
            let sentence = SketchTemplate.plan(figure, imageWidth: 1152, imageHeight: 720)!.spokenSentence
            XCTAssertTrue(sentence.hasPrefix("here is a"), sentence)
            XCTAssertEqual(sentence, sentence.lowercased())
            XCTAssertFalse(sentence.contains("\u{2014}"))
        }
        XCTAssertFalse(SketchTemplate.unsupportedSentence.contains("\u{2014}"))
    }

    func testNoPlanForAFreeformFigure() {
        XCTAssertNil(SketchTemplate.plan(.freeform("house"), imageWidth: 1152, imageHeight: 720))
    }

    func testAFreeformSketchAdmitsShapesUpToTheCapAndNoHighlights() {
        let shapeTag = ShapeTag(kind: .line, points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)], label: nil, screenNumber: nil)
        let highlight = HighlightTag(rect: CGRect(x: 1, y: 1, width: 5, height: 5), label: nil, screenNumber: nil)
        XCTAssertEqual(SketchLimits.maxTags, 8)
        XCTAssertTrue(SketchLimits.admits(.shape(shapeTag), alreadyClosed: 0))
        XCTAssertTrue(SketchLimits.admits(.shape(shapeTag), alreadyClosed: 7))
        XCTAssertFalse(SketchLimits.admits(.shape(shapeTag), alreadyClosed: 8))
        XCTAssertFalse(SketchLimits.admits(.highlight(highlight), alreadyClosed: 0))
    }

    func testTheSketchHoldIsTenSecondsAndTheSentencesAreSpeakable() {
        XCTAssertEqual(SketchTiming.holdSeconds, 10)
        XCTAssertEqual(SketchLimits.failureSentence, "i could not draw that one.")
        XCTAssertEqual(SketchLimits.freeformAnswerMaxTokens, 400)
    }

    func testTheArrowPointsUp() {
        let points = shape(SketchTemplate.plan(.arrow, imageWidth: 1152, imageHeight: 720)!.drawings[0]).points
        XCTAssertLessThan(points[1].y, points[0].y)
    }
}
