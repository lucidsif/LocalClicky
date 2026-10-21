import XCTest
@testable import LocalBrainKit

@MainActor
private final class FakeDraftWorld: DraftRunWorld {
    var lines: [(String, String)] = []
    var said: [String] = []
    var opened: [ComposeTarget.Opening] = []
    var openSucceeds = true
    var stopRequested = false
    var clock = 0.0
    var step = 0.0
    var generate: DraftWriter.Generate = { _, _ in "Hi Bob, I will get back to you soon." }
    var summary: DraftRunSummary?

    func show(_ state: DraftRunState, line: String) async { lines.append((String(describing: state), line)) }
    func say(_ line: String) async { said.append(line) }
    func makeGenerator() -> DraftWriter.Generate { generate }
    func open(_ opening: ComposeTarget.Opening) async -> Bool { opened.append(opening); return openSucceeds }
    func isStopRequested() -> Bool { stopRequested }
    func now() -> Double { clock += step; return clock }
    func finished(_ summary: DraftRunSummary) { self.summary = summary }
}

@MainActor
final class DraftRunDriverTests: XCTestCase {
    private func request(_ words: String) -> EmailDraftRequest { EmailDraftPlanner.request(from: words)! }

    private func run(_ words: String, _ world: FakeDraftWorld) async -> DraftRunState {
        await DraftRunDriver(request: request(words), world: world).run()
    }

    func testModelBodyOpensAGmailDraftAndNeverSends() async {
        let world = FakeDraftWorld()
        let final = await run("draft an email to bob@example.com in gmail saying i will get back to him", world)
        guard case .ready(let ready) = final else { return XCTFail("\(final)") }
        XCTAssertEqual(ready.service, .gmail)
        XCTAssertNil(ready.degradation)
        XCTAssertEqual(world.opened.count, 1)
        XCTAssertTrue(world.opened[0].url.contains("view=cm"))
        XCTAssertTrue(world.opened[0].url.contains("bob%40example.com"))
        XCTAssertTrue(world.said.isEmpty)
        XCTAssertEqual(world.summary?.writer, "model")
        XCTAssertTrue(world.lines.last!.1.hasSuffix("it is not sent. press send yourself."))
    }

    func testStudioOffUsesTheGistAndSaysSo() async {
        let world = FakeDraftWorld()
        world.generate = { _, _ in throw OllamaError.httpStatus(503, "studio connection is off") }
        let final = await run("draft an email to bob@example.com in gmail saying i will get back to him", world)
        guard case .ready = final else { return XCTFail("\(final)") }
        XCTAssertEqual(world.said, ["the studio model is off, so the body is your words."])
        XCTAssertEqual(world.summary?.writer, "fallback")
        XCTAssertEqual(world.summary?.fallbackReason, "studio-off")
        XCTAssertEqual(world.opened.count, 1)
        XCTAssertGreaterThan(world.summary?.bodyChars ?? 0, 0)
    }

    func testNoServiceStopsAndAsksWhich() async {
        let world = FakeDraftWorld()
        let final = await run("draft an email to bob", world)
        XCTAssertEqual(final, .handoff(.needsService))
        XCTAssertTrue(world.opened.isEmpty)
        XCTAssertTrue(world.lines.last!.1.contains("gmail or fastmail"))
    }

    func testNameOnlyLeavesTheToFieldEmptyAndSaysSo() async {
        let world = FakeDraftWorld()
        let final = await run("draft a reply to bob in my gmail", world)
        guard case .ready(let ready) = final else { return XCTFail("\(final)") }
        XCTAssertEqual(ready.degradation, .replyUnsupported)
        XCTAssertTrue(world.lines.last!.1.contains("to field is empty"))
        XCTAssertTrue(world.lines.last!.1.contains("new draft"))
    }

    func testUseTheOpenDraftDegradesToANewDraftOutLoud() async {
        let world = FakeDraftWorld()
        let final = await run("use the current draft on screen in gmail not create new draft", world)
        guard case .ready(let ready) = final else { return XCTFail("\(final)") }
        XCTAssertEqual(ready.degradation, .openDraftUnreadable)
        XCTAssertTrue(world.lines.last!.1.contains("opened a new one"))
    }

    func testStopBeforeOpeningOpensNothing() async {
        let world = FakeDraftWorld()
        world.stopRequested = true
        let final = await run("draft an email to bob@example.com in gmail saying hi", world)
        XCTAssertEqual(final, .stopped)
        XCTAssertTrue(world.opened.isEmpty)
    }

    func testOpenFailureIsAHandoff() async {
        let world = FakeDraftWorld()
        world.openSucceeds = false
        let final = await run("draft an email to bob@example.com in fastmail saying hi", world)
        XCTAssertEqual(final, .handoff(.cannotOpen(.fastmail)))
        XCTAssertEqual(world.summary?.opened, false)
    }

    func testWallClockCapStopsBeforeOpening() async {
        let world = FakeDraftWorld()
        world.step = 100
        let final = await run("draft an email to bob@example.com in gmail saying hi", world)
        XCTAssertEqual(final, .handoff(.timeUp))
        XCTAssertTrue(world.opened.isEmpty)
    }

    func testTheSummaryCarriesNoAddressAndNoWords() async {
        let world = FakeDraftWorld()
        _ = await run("draft an email to bob@example.com in gmail saying i will get back to him", world)
        let text = "\(world.summary!.logFields)"
        XCTAssertFalse(text.contains("bob@example.com"))
        XCTAssertFalse(text.contains("get back"))
    }

    func testServiceAnswerParsing() {
        XCTAssertEqual(EmailDraftPlanner.serviceAnswer(from: "gmail"), .gmail)
        XCTAssertEqual(EmailDraftPlanner.serviceAnswer(from: "use fastmail please"), .fastmail)
        XCTAssertNil(EmailDraftPlanner.serviceAnswer(from: "what time is it"))
        XCTAssertEqual(request("draft an email to bob").withService(.gmail).service, .gmail)
    }

    func testNarrationHasNoEmDashes() {
        let r = request("draft an email to bob@example.com in gmail saying hi")
        for state in [DraftRunState.understanding, .finding, .writing, .opening, .stopped, .handoff(.timeUp),
                      .handoff(.needsService), .ready(DraftReady(service: .gmail, recipient: r.recipient, degradation: nil))] {
            XCTAssertFalse(DraftNarration.line(for: state).contains("\u{2014}"))
        }
    }
}
