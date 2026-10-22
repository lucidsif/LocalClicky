import XCTest
@testable import LocalBrainKit

final class SketchIntentTests: XCTestCase {
    func testSketchRequestsMapToTheirFigure() {
        let cases: [(String, SketchFigure)] = [
            ("draw tic tac toe on the screen", .ticTacToe),
            ("draw a tic tac toe board", .ticTacToe),
            ("draw me a tic-tac-toe grid with some xs and os", .ticTacToe),
            ("draw noughts and crosses", .ticTacToe),
            ("draw a box in the middle of the screen", .box),
            ("draw a big arrow", .arrow),
            ("draw a big arrow pointing up", .arrow),
            ("draw a smiley face", .smiley),
            ("sketch a star", .star),
            ("draw a triangle", .triangle),
            ("draw a circle on my screen", .circle),
            ("draw a line", .line),
            ("draw a check mark", .check),
            ("draw an x", .cross),
            ("Draw a square.", .box),
            ("draw a house", .freeform("house")),
            ("sketch a flowchart with three boxes", .freeform("flowchart with three boxes")),
            ("doodle a cat", .freeform("cat")),
            ("draw a house in the top left corner", .freeform("house")),
        ]
        for (words, figure) in cases {
            XCTAssertEqual(SketchIntent.figure(words), figure, words)
        }
    }

    func testRequestsThatDrawAtSomethingAreNotSketches() {
        for words in ["circle the save button", "draw an arrow to the menu", "draw a box around the error",
                      "draw a line under the title", "draw on this", "draw it", "draw that", "mark this one",
                      "underline the second word", "highlight the total", "draw conclusions from the data",
                      "what did you draw", "open the drawer", "withdraw cash", "open the drawing app", "can you draw",
                      "draw attention to the error", "what is the circle of fifths", "tell me a joke",
                      "draw an arrow pointing at the menu", "draw a circle around it"] {
            XCTAssertNil(SketchIntent.figure(words), words)
        }
    }

    func testClearMarksWords() {
        for words in ["clear that", "clear that drawing", "erase the drawing", "wipe the board", "remove your marks",
                      "get rid of the drawing", "undo the sketch", "can you clear the screen please", "Clear that!"] {
            XCTAssertTrue(ClearMarksIntent.wants(words), words)
        }
        for words in ["clear my inbox", "clear the cache", "delete that email", "remove the app", "clear that email",
                      "draw a box", "what is clear", "undo that", "remove that", "get rid of that",
                      "can you undo that please", "remove that email"] {
            XCTAssertFalse(ClearMarksIntent.wants(words), words)
        }
    }

    // MARK: step sketches: the words

    func testDiagramAndIllustrateStartAFreeformSketchLikeDrawAndSketch() {
        let cases: [(String, SketchFigure)] = [
            ("diagram my morning routine", .freeform("my morning routine")),
            ("illustrate how a heart pumps blood", .freeform("heart pumps blood")),
            ("can you diagram the water cycle", .freeform("water cycle")),
            ("please illustrate a flowchart", .freeform("flowchart")),
            ("draw a diagram of the heart", .freeform("diagram of the heart")),
            ("sketch a house", .freeform("house")),
            ("draw a house", .freeform("house")),
        ]
        for (words, figure) in cases { XCTAssertEqual(SketchIntent.figure(words), figure, words) }
    }

    func testSketchOutHowToStripsTheFillerFromThePhrase() {
        let cases: [(String, SketchFigure)] = [
            ("sketch out how to do parallel parking", .freeform("parallel parking")),
            ("Sketch out how to do parallel parking for me", .freeform("parallel parking")),
            ("sketch me how to tie a tie", .freeform("tie a tie")),
            ("sketch how do i parallel park", .freeform("parallel park")),
            ("draw how to make a paper plane", .freeform("make a paper plane")),
            ("diagram how to change a tyre", .freeform("change a tyre")),
            ("sketch out a star", .star),
            ("sketch out the water cycle", .freeform("water cycle")),
        ]
        for (words, figure) in cases { XCTAssertEqual(SketchIntent.figure(words), figure, words) }
    }

    func testTemplatesAndTheNonDrawingIdiomsStayWhatTheyWere() {
        XCTAssertEqual(SketchIntent.figure("draw tic tac toe"), .ticTacToe)
        XCTAssertEqual(SketchIntent.figure("draw a smiley face"), .smiley)
        for words in ["draw up a contract", "draw conclusions", "draw attention to it", "draw attention to the error",
                      "how do i parallel park", "show me how to parallel park", "show me how to reset my password",
                      "show me how to box", "show me how to circle", "how to tie a tie",
                      "the diagram of the heart shows four chambers", "what does this diagram mean",
                      "that illustrates the point", "i like this diagram", "can you explain the diagram",
                      "illustrate", "diagram", "sketch out"] {
            XCTAssertNil(SketchIntent.figure(words), words)
        }
    }
}
