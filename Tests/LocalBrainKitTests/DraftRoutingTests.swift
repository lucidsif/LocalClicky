import XCTest
@testable import LocalBrainKit

/// The exact transcripts from the brief, lowercase as the router sees them, plus the send refusal and Bear.
final class DraftRoutingTests: XCTestCase {
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

    func testTheOwnersExactDraftRequestsRouteToDrafts() {
        for words in ["open a gmail draft and tell x i will get back to him", "draft a reply to bob in my gmail",
                      "use the current draft on screen not create new draft"] {
            XCTAssertEqual(route(words), .draftEmail, words)
            XCTAssertEqual(route(words, textContext), .draftEmail, "text mode: \(words)")
            XCTAssertEqual(drawingRoute(words), .draftEmail, "drawing on: \(words)")
        }
    }

    func testOpeningGmailInTheBrowserStaysABrowserOpen() {
        XCTAssertEqual(route("open up, my gmail in the browser"), .browserCommand)
        XCTAssertEqual(route("Open up, my Gmail in the browser"), .browserCommand)
    }

    func testAFragmentIsNotADraft() {
        XCTAssertNotEqual(route("john in the email"), .draftEmail)
        XCTAssertEqual(route("john in the email", textContext), .text)
    }

    func testAGistThatMentionsPlayOrYoutubeStillRoutesToDrafts() {
        XCTAssertEqual(route("draft an email to bob in gmail saying let's play soccer on youtube tonight"), .draftEmail)
    }

    func testClickingSendIsRefusedNotClicked() {
        for words in ["click send", "press the send button", "click the send email button"] {
            XCTAssertEqual(route(words), .refuseSend, words)
            XCTAssertEqual(drawingRoute(words), .refuseSend, "drawing on: \(words)")
        }
        XCTAssertEqual(route("click the submit button"), .screenClick)
    }

    func testBearNotesRoute() {
        XCTAssertEqual(route("write a note in bear saying the plumber comes on thursday"), .bearNote)
    }

    func testOpenDraftBrowserCompose() {
        // The older compose rule still stands for requests the draft planner does not claim.
        XCTAssertEqual(route("go to my gmail and open up a draft"), .browserCommand)
    }
}
