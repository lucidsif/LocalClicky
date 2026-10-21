import XCTest
@testable import LocalBrainKit

@MainActor
private final class PageFakeWorld: DraftRunWorld {
    var log: [String] = []
    var lines: [String] = []
    var said: [String] = []
    var opened: [ComposeTarget.Opening] = []
    var summary: DraftRunSummary?
    var stopRequested = false
    var clock = 0.0
    var generate: DraftWriter.Generate = { _, _ in "Hi Bob, I will get back to you soon." }

    var gate = PageGate.Result(readable: true, milliseconds: 420)
    var bodies: [ComposeBodyRef] = [ComposeBodyRef(index: 0, isEmpty: true)]
    var fillWorks = true
    var filled: [(text: String, appending: Bool)] = []
    var messageFound = true
    var thread = ThreadReading(items: [.text("Bob"), .text("Are you free?"), .button("Reply")], hasReplyButton: true)
    var replyPressed = true
    var appendAnswer = true
    var stopWhenAsked = false
    var asked = false
    var endCalls = 0

    func show(_ state: DraftRunState, line: String) async { log.append("show:" + state.logName); lines.append(line) }
    func say(_ line: String) async { said.append(line) }
    func makeGenerator() -> DraftWriter.Generate {
        log.append("writer")
        return generate
    }
    func open(_ opening: ComposeTarget.Opening) async -> Bool { log.append("open"); opened.append(opening); return true }
    func isStopRequested() -> Bool { stopRequested }
    func now() -> Double { clock += 0.01; return clock }
    func finished(_ summary: DraftRunSummary) { self.summary = summary }

    func beginPageAccess(service: EmailService) async { log.append("begin") }
    func awaitPage(service: EmailService, seconds: Double) async -> PageGate.Result { log.append("gate"); return gate }
    func endPageAccess(service: EmailService) { endCalls += 1; log.append("end") }
    func composeBodies(service: EmailService, seconds: Double) async -> [ComposeBodyRef] { log.append("bodies"); return bodies }
    func fillBody(_ body: ComposeBodyRef, text: String, appending: Bool, service: EmailService) async -> Bool {
        log.append("fill")
        filled.append((text, appending))
        return fillWorks
    }
    func openMessage(from person: Recipient, service: EmailService, seconds: Double) async -> Bool { log.append("row"); return messageFound }
    func readThread(service: EmailService) async -> ThreadReading { log.append("thread"); return thread }
    func pressReply(service: EmailService) async -> Bool { log.append("reply"); return replyPressed }
    func askToAppend() async -> Bool {
        asked = true
        log.append("ask")
        if stopWhenAsked { stopRequested = true }
        return appendAnswer
    }
}

@MainActor
final class DraftPageRunTests: XCTestCase {
    private let openDraft = "use the current draft in gmail and tell him i will get back to him"
    private let reply = "draft a reply to bob in my gmail saying i will get back to him"

    private func run(_ words: String, _ world: PageFakeWorld) async -> DraftRunState {
        await DraftRunDriver(request: EmailDraftPlanner.request(from: words)!, world: world).run()
    }

    private func ready(_ state: DraftRunState, file: StaticString = #filePath, line: UInt = #line) -> DraftReady? {
        guard case .ready(let ready) = state else { XCTFail("\(state)", file: file, line: line); return nil }
        return ready
    }

    // MARK: - The open draft

    func testAnEmptyOpenDraftIsFilledAndNothingNewIsOpened() async {
        let world = PageFakeWorld()
        let final = await run(openDraft, world)
        let result = ready(final)
        XCTAssertEqual(result?.fill, .filledOpenDraft)
        XCTAssertNil(result?.degradation)
        XCTAssertTrue(world.opened.isEmpty)
        XCTAssertEqual(world.filled.count, 1)
        XCTAssertFalse(world.filled[0].appending)
        XCTAssertEqual(world.summary?.bodyMode, "set")
        XCTAssertEqual(world.summary?.pageReadable, true)
        XCTAssertEqual(world.summary?.gateMs, 420)
        XCTAssertTrue(world.lines.last!.hasSuffix("it is not sent. press send yourself."))
    }

    func testTheWriterRunsBeforeAnyPageStep() async {
        let world = PageFakeWorld()
        _ = await run(openDraft, world)
        let writer = world.log.firstIndex(of: "writer")!
        let begin = world.log.firstIndex(of: "begin")!
        XCTAssertLessThan(writer, begin)
        XCTAssertLessThan(writer, world.log.firstIndex(of: "gate")!)
    }

    func testBeginsAccessThenLooksForThePageAndAlwaysEnds() async {
        let world = PageFakeWorld()
        _ = await run(openDraft, world)
        XCTAssertLessThan(world.log.firstIndex(of: "begin")!, world.log.firstIndex(of: "gate")!)
        XCTAssertEqual(world.endCalls, 1)
        XCTAssertEqual(world.log.last, "show:ready")
        XCTAssertLessThan(world.log.firstIndex(of: "end")!, world.log.lastIndex(of: "show:ready")!)
    }

    func testAnOpenDraftWithTextIsAddedToOnlyAfterAYes() async {
        let world = PageFakeWorld()
        world.bodies = [ComposeBodyRef(index: 0, isEmpty: false)]
        let result = ready(await run(openDraft, world))
        XCTAssertTrue(world.asked)
        XCTAssertEqual(result?.fill, .addedToOpenDraft)
        XCTAssertTrue(world.filled[0].appending)
        XCTAssertEqual(world.summary?.bodyMode, "append")
    }

    func testANoLeavesTheOpenDraftAlone() async {
        let world = PageFakeWorld()
        world.bodies = [ComposeBodyRef(index: 0, isEmpty: false)]
        world.appendAnswer = false
        let final = await run(openDraft, world)
        XCTAssertEqual(final, .handoff(.declinedAppend))
        XCTAssertTrue(world.filled.isEmpty)
        XCTAssertTrue(world.opened.isEmpty)
        XCTAssertEqual(world.endCalls, 1)
    }

    func testTwoOpenDraftsFallBackToANewOne() async {
        let world = PageFakeWorld()
        world.bodies = [ComposeBodyRef(index: 0, isEmpty: true), ComposeBodyRef(index: 1, isEmpty: true)]
        let result = ready(await run(openDraft, world))
        XCTAssertEqual(result?.degradation, .moreThanOneOpenDraft)
        XCTAssertEqual(world.opened.count, 1)
        XCTAssertTrue(world.filled.isEmpty)
        XCTAssertEqual(world.summary?.bodiesFound, 2)
    }

    func testNoComposeBodyFallsBackToANewDraftWithTheReason() async {
        let world = PageFakeWorld()
        world.bodies = []
        let result = ready(await run(openDraft, world))
        XCTAssertEqual(result?.degradation, .openDraftUnreadable)
        XCTAssertTrue(world.lines.last!.hasPrefix("i can not read the open draft yet, so i opened a new one."))
        XCTAssertEqual(world.opened.count, 1)
    }

    func testAnUnreadablePageFallsBackAndLogsTheGate() async {
        let world = PageFakeWorld()
        world.gate = PageGate.Result(readable: false, milliseconds: 4000)
        let result = ready(await run(openDraft, world))
        XCTAssertEqual(result?.degradation, .openDraftUnreadable)
        XCTAssertEqual(world.opened.count, 1)
        XCTAssertFalse(world.log.contains("bodies"))
        XCTAssertEqual(world.summary?.pageReadable, false)
        XCTAssertEqual(world.summary?.gateMs, 4000)
        XCTAssertEqual(world.endCalls, 1)
    }

    func testAFillThatDoesNotReadBackFallsBackToANewDraft() async {
        let world = PageFakeWorld()
        world.fillWorks = false
        let result = ready(await run(openDraft, world))
        XCTAssertEqual(result?.degradation, .openDraftUnreadable)
        XCTAssertEqual(world.opened.count, 1)
    }

    func testNothingToPutInTheOpenDraftAsksWhatToWrite() async {
        let world = PageFakeWorld()
        let final = await run("use the current draft on screen in gmail not create new draft", world)
        XCTAssertEqual(final, .handoff(.nothingToWrite))
        XCTAssertTrue(world.filled.isEmpty)
    }

    // MARK: - Replies

    func testAReplyFindsTheMessagePressesReplyAndFillsTheBody() async {
        let world = PageFakeWorld()
        let result = ready(await run(reply, world))
        XCTAssertEqual(result?.fill, .filledReply)
        XCTAssertEqual(world.opened.count, 1)
        XCTAssertEqual(world.opened[0].url, "https://mail.google.com/mail/u/0/#search/from%3Abob")
        XCTAssertEqual(world.opened[0].bundleIdentifier, "com.google.Chrome")
        let order = ["writer", "begin", "open", "gate", "row", "thread", "reply", "bodies", "fill"]
        XCTAssertEqual(order.map { world.log.firstIndex(of: $0)! }, order.map { world.log.firstIndex(of: $0)! }.sorted())
        XCTAssertEqual(world.summary?.bodyMode, "reply")
        XCTAssertEqual(world.summary?.replyContextChars, "Bob\nAre you free?".count)
        XCTAssertEqual(world.endCalls, 1)
        XCTAssertTrue(world.lines.last!.contains("reply is open in gmail"))
    }

    func testAReplyWithTheStudioOffUsesTheGistAsTheBody() async {
        let world = PageFakeWorld()
        world.generate = { _, _ in throw OllamaError.httpStatus(503, "studio connection is off") }
        _ = await run(reply, world)
        XCTAssertEqual(world.said, ["the studio model is off, so the body is your words."])
        XCTAssertEqual(world.summary?.writer, "fallback")
        XCTAssertEqual(world.filled.count, 1)
        XCTAssertFalse(world.filled[0].text.isEmpty)
        XCTAssertGreaterThan(world.summary?.replyContextChars ?? 0, 0)
    }

    func testAReplyOnAnUnreadablePageIsANewDraftWithTheOldReason() async {
        let world = PageFakeWorld()
        world.gate = PageGate.Result(readable: false, milliseconds: 4000)
        let result = ready(await run(reply, world))
        XCTAssertEqual(result?.degradation, .replyUnsupported)
        XCTAssertEqual(world.opened.count, 2, "the search, then the new compose")
        XCTAssertTrue(world.opened[1].url.contains("view=cm"))
        XCTAssertEqual(world.endCalls, 1)
    }

    func testNoMessageFromThePersonIsAHandoffWithTheExactLine() async {
        let world = PageFakeWorld()
        world.messageFound = false
        let final = await run(reply, world)
        XCTAssertEqual(final, .handoff(.noMessage("bob")))
        XCTAssertEqual(world.lines.last,
                       "i could not find a message from bob in gmail. say the address for a new draft, or open the message and ask again.")
        XCTAssertTrue(world.filled.isEmpty)
        XCTAssertEqual(world.endCalls, 1)
        XCTAssertEqual(world.opened.count, 1, "no new draft is opened behind the handoff")
    }

    func testNoReplyButtonIsTheSameHandoff() async {
        let world = PageFakeWorld()
        world.thread = ThreadReading(items: [.text("Bob")], hasReplyButton: false)
        let final = await run(reply, world)
        XCTAssertEqual(final, .handoff(.noMessage("bob")))
        XCTAssertFalse(world.log.contains("reply"))
    }

    func testAReplyPressThatFailsIsTheSameHandoff() async {
        let world = PageFakeWorld()
        world.replyPressed = false
        let final = await run(reply, world)
        XCTAssertEqual(final, .handoff(.noMessage("bob")))
    }

    func testAReplyWithNoComposeBodyAfterTheReplyPressIsAHandoff() async {
        let world = PageFakeWorld()
        world.bodies = []
        let final = await run(reply, world)
        XCTAssertEqual(final, .handoff(.noMessage("bob")))
    }

    func testAReplyUsesAnAddressForTheSearchWhenOneWasHeard() async {
        let world = PageFakeWorld()
        _ = await run("draft a reply to bob@example.com in gmail saying thanks", world)
        XCTAssertEqual(world.opened.first?.url, "https://mail.google.com/mail/u/0/#search/from%3Abob%40example.com")
    }

    func testAFastmailReplyReadsNoPageAndSaysWhy() async {
        let world = PageFakeWorld()
        let result = ready(await run("draft a reply to bob in my fastmail saying thanks", world))
        XCTAssertEqual(result?.degradation, .fastmailReplyUnsupported)
        XCTAssertFalse(world.log.contains("begin"))
        XCTAssertTrue(world.lines.last!.hasPrefix("i can not reply in fastmail yet, so this is a new draft."))
        XCTAssertEqual(world.opened.count, 1)
    }

    // MARK: - Every path ends the access and logs no text

    func testStopDuringThePageStepsStillEndsTheAccess() async {
        let world = PageFakeWorld()
        world.bodies = [ComposeBodyRef(index: 0, isEmpty: false)]
        world.stopWhenAsked = true
        let final = await run(openDraft, world)
        XCTAssertEqual(final, .stopped)
        XCTAssertTrue(world.filled.isEmpty)
        XCTAssertEqual(world.endCalls, 1)
    }

    func testTheSummaryHoldsNoPageTextNoMessageAndNoAddress() async {
        let world = PageFakeWorld()
        _ = await run("draft a reply to bob@example.com in gmail saying i will get back to him", world)
        let text = "\(world.summary!.logFields)"
        for secret in ["bob@example.com", "get back", "Are you free"] { XCTAssertFalse(text.contains(secret), secret) }
        XCTAssertNotNil(world.summary?.logFields["pageReadable"])
        XCTAssertNotNil(world.summary?.logFields["gateMs"])
        XCTAssertNotNil(world.summary?.logFields["replyContextChars"])
    }

    func testANewDraftNeverTouchesThePage() async {
        let world = PageFakeWorld()
        _ = await run("draft an email to bob@example.com in gmail saying hi", world)
        for step in ["begin", "gate", "bodies", "fill", "row", "thread", "reply"] { XCTAssertFalse(world.log.contains(step), step) }
        XCTAssertEqual(world.endCalls, 0)
    }

    func testNoEmDashesInTheNewLines() {
        let states: [DraftRunState] = [.readingPage, .findingMessage, .filling, .handoff(.noMessage("bob")),
                                       .handoff(.declinedAppend), .handoff(.nothingToWrite)]
        for state in states { XCTAssertFalse(DraftNarration.line(for: state).contains("\u{2014}")) }
    }
}
