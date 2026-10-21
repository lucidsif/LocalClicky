import XCTest
@testable import LocalBrainKit

/// Pins the route every existing kind of request takes today, so the draft, Bear, custom-site and send-refusal
/// routes added next to them cannot take one over. Each row is a transcript and the route it has always had.
final class VoiceRoutingRegressionTests: XCTestCase {
    private let screenContext = ConversationRouter.Context(visionModeSelected: true, screenAvailable: true,
                                                           previousTurnUsedScreen: false, hasConversationHistory: false)
    private let textContext = ConversationRouter.Context(visionModeSelected: false, screenAvailable: false,
                                                         previousTurnUsedScreen: false, hasConversationHistory: false)

    private func route(_ words: String, _ context: ConversationRouter.Context? = nil) -> ConversationRoute {
        ConversationRouter.route(transcript: words, context: context ?? screenContext)
    }

    private func drawingRoute(_ words: String) -> ConversationRoute {
        DrawingRouting.route(transcript: words, context: screenContext, hasUsableInk: false, drawingEnabled: true)
    }

    private func assertRoutes(_ expected: ConversationRoute, _ transcripts: [String],
                              file: StaticString = #filePath, line: UInt = #line) {
        for words in transcripts {
            XCTAssertEqual(route(words), expected, words, file: file, line: line)
            XCTAssertEqual(drawingRoute(words), expected, "drawing on: \(words)", file: file, line: line)
        }
    }

    func testPlayMediaKeepsItsRoute() {
        assertRoutes(.playMedia, ["go to youtube and play lucid dreams by juice wrld", "play lucid dreams on youtube",
                                  "I want you to play the Backstreet Boys. I want it that Way song.",
                                  "can you play lucid dreams"])
    }

    func testSpotifyKeepsItsRoute() {
        assertRoutes(.spotify, ["play despacito on spotify", "pause spotify", "next song on spotify"])
    }

    func testBrowserOpensKeepTheirRoute() {
        assertRoutes(.browserCommand, ["Open up, my Gmail in the browser", "open a new tab and go to gmail", "open youtube",
                                       "go to github.com", "open google maps", "search the web for cats"])
        XCTAssertEqual(route("Open up, my Gmail in the browser", textContext), .browserCommand)
    }

    func testAppLaunchKeepsItsRoute() {
        assertRoutes(.openApp, ["launch spotify", "open the notes app", "launch the calculator app", "open terminal"])
    }

    func testScreenClickKeepsItsRoute() {
        assertRoutes(.screenClick, ["click the submit button", "press the save button", "tap on the settings icon"])
    }

    func testPointingKeepsItsRoute() {
        assertRoutes(.screenPoint, ["where do i click to open settings", "where is the save button", "point at the search box"])
    }

    func testSketchAndDrawKeepTheirRoutes() {
        XCTAssertEqual(drawingRoute("draw a tic tac toe board"), .screenSketch)
        XCTAssertEqual(drawingRoute("circle the save button"), .screenDraw)
    }

    func testTheOtherActionRoutesKeepTheirs() {
        assertRoutes(.setTimer, ["set a timer for 4 minutes"])
        assertRoutes(.webReach, ["what's the weather", "look it up online"])
        assertRoutes(.copyLastAnswer, ["copy your answer"])
        assertRoutes(.showText, ["give me the capital of france in text"])
    }

    func testChatFallbackKeepsItsRoute() {
        // A fragment that names an email but gives no command is chat, with or without the screen.
        for words in ["John in the email", "what's three times five", "tell me a joke", "john smith"] {
            XCTAssertEqual(route(words, textContext), .text, words)
        }
        XCTAssertEqual(route("John in the email"), .text)
        XCTAssertEqual(drawingRoute("John in the email"), .text)
        XCTAssertEqual(route("what am i looking at"), .screen)
    }
}
