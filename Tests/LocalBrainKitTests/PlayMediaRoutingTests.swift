import XCTest
@testable import LocalBrainKit

final class PlayMediaRoutingTests: XCTestCase {
    private let context = ConversationRouter.Context(visionModeSelected: true, screenAvailable: true,
                                                     previousTurnUsedScreen: false, hasConversationHistory: false)

    private func route(_ words: String) -> ConversationRoute {
        ConversationRouter.route(transcript: words, context: context)
    }

    func testPlayAVideoOnYouTubeRoutesToPlayMedia() {
        for words in ["go to youtube and play lucid dreams by juice wrld", "play lucid dreams on youtube",
                      "open youtube and play a video"] {
            XCTAssertEqual(route(words), .playMedia, words)
        }
    }

    func testTheRealTranscriptWithoutTheWordYouTubeRoutesToPlayMedia() {
        let words = "I want you to play the Backstreet Boys. I want it that Way song."
        XCTAssertEqual(route(words), .playMedia)
        XCTAssertEqual(DrawingRouting.route(transcript: words, context: context, hasUsableInk: false,
                                            drawingEnabled: true), .playMedia)
    }

    func testRequestFramesWithoutYouTubeRouteToPlayMedia() {
        for words in ["can you play lucid dreams", "could you play lucid dreams", "please play lucid dreams",
                      "play lucid dreams for me", "i'd like you to play lucid dreams",
                      "i want you to play lucid dreams", "hey clicky, can you play lucid dreams"] {
            XCTAssertEqual(route(words), .playMedia, words)
        }
    }

    func testTalkAboutPlayingAndBarePlayDoNotRoute() {
        // A bare "play X" still needs the word youtube; the router only takes a play verb without it
        // inside an explicit request frame.
        for words in ["i play guitar", "we played football", "they watch youtube a lot", "play the video",
                      "can you play the video", "let's play a game", "the play was good", "play lucid dreams",
                      "can you play lucid dreams on netflix", "i want you to watch lucid dreams"] {
            XCTAssertNotEqual(route(words), .playMedia, words)
        }
    }

    func testNeighbouringRoutesAreUnchanged() {
        XCTAssertEqual(route("play despacito on spotify"), .spotify)
        XCTAssertEqual(route("search youtube for cats"), .text)
        XCTAssertEqual(route("open youtube"), .browserCommand)
        XCTAssertNotEqual(route("play the video"), .playMedia)
    }

    func testAPointingQuestionStaysPointing() {
        XCTAssertEqual(route("where do i click to play the video on youtube"), .screenPoint)
    }

    func testDrawingRoutingPassesPlayMediaThrough() {
        for words in ["go to youtube and play lucid dreams", "open youtube and play a video"] {
            XCTAssertEqual(DrawingRouting.route(transcript: words, context: context, hasUsableInk: false,
                                                drawingEnabled: true), .playMedia, words)
        }
    }
}
