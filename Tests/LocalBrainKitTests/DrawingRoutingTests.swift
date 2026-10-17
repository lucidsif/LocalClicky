import XCTest
@testable import LocalBrainKit

final class DrawingRoutingTests: XCTestCase {
    private func context(vision: Bool = true, screen: Bool = true) -> ConversationRouter.Context {
        ConversationRouter.Context(visionModeSelected: vision, screenAvailable: screen,
                                   previousTurnUsedScreen: false, hasConversationHistory: false)
    }

    private func route(_ words: String, enabled: Bool = true, ink: Bool = false,
                       vision: Bool = true, screen: Bool = true) -> ConversationRoute {
        DrawingRouting.route(transcript: words, context: context(vision: vision, screen: screen),
                             hasUsableInk: ink, drawingEnabled: enabled)
    }

    // MARK: - the trigger

    func testDrawingWordsTrigger() {
        for words in ["circle the save button", "can you circle that for me", "draw a circle around the error",
                      "draw an arrow to the menu", "outline this", "underline the second word",
                      "highlight the total", "highlight that line", "mark the login field",
                      "mark this one", "show me where the settings are", "draw it on my screen",
                      "draw on the screen", "circle all the links", "Highlight the Price."] {
            XCTAssertTrue(DrawingIntent.wantsDrawing(words), words)
        }
    }

    func testOrdinaryUsesOfTheWordsDoNotTrigger() {
        for words in ["what is a bookmark", "open the drawer", "i left a remark", "what is the circle of fifths",
                      "outline the steps to bake bread", "what's the highlight of the video",
                      "mark it as read", "mark this done", "how do i withdraw cash", "what is a market",
                      "draw conclusions from the data", "tell me a joke"] {
            XCTAssertFalse(DrawingIntent.wantsDrawing(words), words)
        }
    }

    // MARK: - the route

    func testEnabledDrawingWordsGoToTheDrawRoute() {
        XCTAssertEqual(route("circle the save button"), .screenDraw)
        XCTAssertEqual(route("highlight the total"), .screenDraw)
        XCTAssertEqual(route("show me where the settings are"), .screenDraw)
        XCTAssertEqual(route("draw an arrow to the menu"), .screenDraw)
    }

    func testDrawingBeatsThePointingKeywords() {
        // "highlight the" and "show me where" are pointing phrases for the
        // normal router; with drawing on they draw.
        XCTAssertEqual(InkRouting.route(transcript: "highlight the total", context: context(), hasUsableInk: false), .screenPoint)
        XCTAssertEqual(route("highlight the total"), .screenDraw)
    }

    func testDrawingTurnWithInk() {
        XCTAssertEqual(route("circle the thing i circled", ink: true), .screenDraw)
        XCTAssertEqual(route("what is this", ink: true), .screen)
    }

    func testClickWinsOverDrawing() {
        XCTAssertEqual(route("click the button i circled", ink: true), .screenClick)
        XCTAssertEqual(route("click the highlighted link"), .screenClick)
    }

    func testActionRoutesAreNeverTakenOver() {
        XCTAssertEqual(route("open spotify and mark my calendar"), InkRouting.route(
            transcript: "open spotify and mark my calendar", context: context(), hasUsableInk: false))
        XCTAssertEqual(route("set a timer for 4 minutes and mark it"), .setTimer)
    }

    func testNoScreenMeansNoDrawing() {
        XCTAssertEqual(route("circle the save button", vision: false), .text)
        XCTAssertEqual(route("circle the save button", screen: false), .text)
    }

    func testDrawingOffIsExactlyTheInkRoute() {
        let phrases = ["circle the save button", "highlight the total", "show me where the settings are",
                       "where do i click to save", "what does this button do", "what's 3 times 5",
                       "click the submit button", "point at the search bar", "open the notes app",
                       "draw a circle around the error", "mark this one", "explain this error",
                       "which button do i press to save", "what's on my screen right now"]
        for words in phrases {
            for ink in [false, true] {
                for vision in [true, false] {
                    XCTAssertEqual(route(words, enabled: false, ink: ink, vision: vision),
                                   InkRouting.route(transcript: words, context: context(vision: vision), hasUsableInk: ink),
                                   "\(words) ink=\(ink) vision=\(vision)")
                }
            }
        }
    }

    // MARK: - the prompt

    func testDrawPromptHasTheSizeBothTagFormsAndTheCircleRule() {
        let prompt = LocalPrompts.screenDrawResponse(imageWidthInPixels: 1152, imageHeightInPixels: 748)
        XCTAssertTrue(prompt.contains("1152x748"))
        XCTAssertTrue(prompt.contains("[SHAPE:"))
        XCTAssertTrue(prompt.contains("[HIGHLIGHT:"))
        XCTAssertTrue(prompt.contains("the first point is the centre, the second is one point on the ring"))
        XCTAssertTrue(prompt.contains("just outside the thing"))
        XCTAssertTrue(prompt.contains("say what the mark is on"))
    }

    func testDrawPromptsExampleParsesAndHasNoDashesOrEmoji() {
        let prompt = LocalPrompts.screenDrawResponse(imageWidthInPixels: 1152, imageHeightInPixels: 748)
        XCTAssertFalse(prompt.contains("\u{2014}"))
        XCTAssertFalse(prompt.contains("\u{2013}"))
        let example = prompt.components(separatedBy: "example:\n").last ?? ""
        let parsed = ShapeTagParser.parse(from: example)
        XCTAssertEqual(parsed.drawings.count, 2)
        XCTAssertEqual(parsed.spokenText, "that is the save button, circled.\nand this line is the error message.")
    }

    func testThePointPromptsAreUntouched() {
        // The route prompts for pointing and clicking must not mention drawing.
        XCTAssertFalse(LocalPrompts.screenPointResponse(imageWidthInPixels: 1, imageHeightInPixels: 1).contains("SHAPE"))
        XCTAssertFalse(LocalPrompts.screenClickResponse(imageWidthInPixels: 1, imageHeightInPixels: 1).contains("SHAPE"))
    }
}
