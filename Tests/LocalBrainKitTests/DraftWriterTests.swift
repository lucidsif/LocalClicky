import XCTest
@testable import LocalBrainKit

final class DraftWriterTests: XCTestCase {
    private func write(gist: String = "i will get back to him", recipient: Recipient = .nameOnly("X"),
                       timeout: Double = 5, generate: @escaping DraftWriter.Generate) async -> DraftBody {
        await DraftWriter.write(gist: gist, recipient: recipient, timeoutSeconds: timeout, generate: generate)
    }

    // MARK: - The model path

    func testTheModelsBodyIsUsed() async {
        let body = await write { _, _ in "Hi X,\nI will get back to you soon." }
        XCTAssertEqual(body.text, "Hi X,\nI will get back to you soon.")
        XCTAssertTrue(body.usedModel)
        XCTAssertNil(body.fallbackReason)
    }

    func testThePromptCarriesTheNameAndTheGistButNeverAnAddress() async {
        let seen = Box()
        _ = await write(recipient: .address("bob@example.com")) { system, user in
            seen.system = system; seen.user = user; return "ok"
        }
        XCTAssertEqual(seen.system, DraftPrompts.system)
        XCTAssertEqual(seen.user, "gist: i will get back to him")
        XCTAssertFalse(seen.user.contains("bob@example.com"))
        let named = Box()
        _ = await write { system, user in named.user = user; return "ok" }
        XCTAssertEqual(named.user, "recipient name: X\ngist: i will get back to him")
    }

    func testTheModelNameIsAConfigValueDefaultingToTheStudioModel() {
        XCTAssertEqual(DraftWriter.defaultModel, "studio:clicky")
    }

    func testModelOutputIsCleaned() {
        XCTAssertEqual(DraftWriter.clean(modelOutput: "  \"Hi Bob,\nThanks.\"  "), "Hi Bob,\nThanks.")
        XCTAssertEqual(DraftWriter.clean(modelOutput: "Subject: hello\nHi Bob,\nThanks."), "Hi Bob,\nThanks.")
        XCTAssertEqual(DraftWriter.clean(modelOutput: "```\nHi Bob,\nThanks.\n```"), "Hi Bob,\nThanks.")
        XCTAssertEqual(DraftWriter.clean(modelOutput: "\u{201C}Hi.\u{201D}"), "Hi.")
    }

    func testOutputIsCutAtTwoThousandCharactersOnAWord() {
        let long = String(repeating: "word ", count: 1000)
        let cleaned = DraftWriter.clean(modelOutput: long)
        XCTAssertLessThanOrEqual(cleaned.count, DraftWriter.maxBodyCharacters)
        XCTAssertTrue(cleaned.hasSuffix("word"))
    }

    // MARK: - The fallback path (the Studio connection is off)

    func testA503FromTheGatewayFallsBackToTheGistAndSaysTheStudioIsOff() async {
        let body = await write { _, _ in
            throw OllamaError.httpStatus(503, #"{"error":"studio connection is off","speakable":"the studio connection is off"}"#)
        }
        XCTAssertFalse(body.usedModel)
        XCTAssertEqual(body.fallbackReason, .studioOff)
        XCTAssertEqual(body.text, "I will get back to him.")
        XCTAssertEqual(DraftWriter.spokenLine(for: .studioOff), "the studio model is off, so the body is your words.")
    }

    func testTheStudioOffTextAloneAlsoCounts() async {
        let body = await write { _, _ in throw OllamaError.httpStatus(500, "The Studio connection is off") }
        XCTAssertEqual(body.fallbackReason, .studioOff)
    }

    func testAnyOtherFailureFallsBackWithAnHonestLine() async {
        let unreachable = await write { _, _ in throw OllamaError.serverUnreachable }
        XCTAssertEqual(unreachable.fallbackReason, .failed)
        XCTAssertEqual(unreachable.text, "I will get back to him.")
        let busy = await write { _, _ in throw OllamaError.httpStatus(500, "boom") }
        XCTAssertEqual(busy.fallbackReason, .failed)
        XCTAssertEqual(DraftWriter.spokenLine(for: .failed), "the writer did not answer, so the body is your words.")
    }

    func testTheSpokenFallbackLinesAreShort() {
        for reason in [DraftFallbackReason.studioOff, .failed, .emptyOutput, .timedOut, .cancelled] {
            XCTAssertLessThanOrEqual(DraftWriter.spokenLine(for: reason).split(separator: " ").count, 12, reason.rawValue)
            XCTAssertFalse(DraftWriter.spokenLine(for: reason).contains("\u{2014}"))
        }
    }

    func testAnEmptyModelAnswerFallsBack() async {
        let body = await write { _, _ in "  \n " }
        XCTAssertEqual(body.fallbackReason, .emptyOutput)
        XCTAssertEqual(body.text, "I will get back to him.")
    }

    func testASlowModelTimesOutAndFallsBack() async {
        let body = await write(timeout: 0.05) { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "too late"
        }
        XCTAssertEqual(body.fallbackReason, .timedOut)
        XCTAssertEqual(body.text, "I will get back to him.")
    }

    func testACancelledCallIsReportedAsCancelled() async {
        let body = await write { _, _ in throw CancellationError() }
        XCTAssertEqual(body.fallbackReason, .cancelled)
    }

    // MARK: - The gist, lightly cleaned

    func testFallbackBodyCapitalisesAndEndsTheSentence() {
        XCTAssertEqual(DraftWriter.fallbackBody(gist: "i will get back to him"), "I will get back to him.")
        XCTAssertEqual(DraftWriter.fallbackBody(gist: "  thanks   for lunch! "), "Thanks for lunch!")
        XCTAssertEqual(DraftWriter.fallbackBody(gist: "i'm running late, i'll call you"), "I'm running late, I'll call you.")
        XCTAssertEqual(DraftWriter.fallbackBody(gist: "are you free tomorrow?"), "Are you free tomorrow?")
    }

    func testFallbackBodyOfNothingIsNothing() {
        XCTAssertEqual(DraftWriter.fallbackBody(gist: "   "), "")
    }

    func testFallbackBodyKeepsOtherWordsExactly() {
        XCTAssertEqual(DraftWriter.fallbackBody(gist: "send the file to maria and I"), "Send the file to maria and I.")
    }

    func testFallbackBodyIsCappedLikeAModelBody() {
        XCTAssertLessThanOrEqual(DraftWriter.fallbackBody(gist: String(repeating: "word ", count: 1000)).count,
                                 DraftWriter.maxBodyCharacters)
    }

    private final class Box: @unchecked Sendable {
        var system = ""
        var user = ""
    }
}
