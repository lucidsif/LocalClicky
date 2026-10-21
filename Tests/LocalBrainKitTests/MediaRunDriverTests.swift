import CoreGraphics
import XCTest
@testable import LocalBrainKit

/// A world with a fake clock (sleeping advances it) that counts what the driver asks of it.
@MainActor
private final class FakeWorld: MediaRunWorld {
    static let label = "Juice WRLD Lucid Dreams Forget Me Official Video"
    static let link = LinkCandidate(label: label, url: "https://www.youtube.com/watch?v=abc123",
                                    frame: CGRect(x: 100, y: 200, width: 300, height: 20))
    static let resultsURL = "https://www.youtube.com/results?search_query=lucid+dreams"
    static let watchURL = "https://www.youtube.com/watch?v=abc123"

    static let directResult = DirectResult(videoID: "abc123abcde", title: label)
    static let directWatchURL = directResult.watchURL

    var clock = 0.0
    /// What the direct search returns; empty (the default) sends the run down the page path.
    var directList: [DirectResult] = []
    var directFinished: [DirectResult?] = []
    var directStopped: [Bool] = []
    var watchOpenedAt = 0.0
    var pressedAt = 0.0
    var watchOpens: [String] = []
    /// What happened, in order, for tests about what comes before what.
    var events: [String] = []
    var chromeInstalled = true
    var consentAnswer = MediaRunEvent.consentYes
    var pageURLs: (FakeWorld) -> String? = { $0.linkPressed ? watchURL : resultsURL }
    var linkList: (FakeWorld) -> [LinkCandidate] = { _ in [link] }
    var buttons: (FakeWorld) -> [String] = { _ in ["Pause (k)"] }
    var interruptWhen: (FakeWorld) -> MediaRunEvent? = { _ in nil }
    var duringAsk: (FakeWorld) -> Void = { _ in }
    var queuedInterrupt: MediaRunEvent?
    /// While set, show() for the opening (or searching) state does not return until releaseOpeningLine().
    var holdOpeningLine = false
    var holdSearchingLine = false
    var directCalls = 0
    private var openingLineRelease: CheckedContinuation<Void, Never>?
    var openCount = 0
    var browserRunning = true
    var openFailedWaits: [Double] = []

    var askCount = 0
    var linkPressCount = 0
    var playPressCount = 0
    var linksCalls = 0
    var pageURLCalls = 0
    var shown: [(state: MediaRunState, line: String)] = []
    var records: [StepRecord] = []

    var linkPressed: Bool { linkPressCount > 0 }

    var watchOpened: Bool { !watchOpens.isEmpty }

    func directResults(query: String) async -> [DirectResult] {
        directCalls += 1
        events.append("direct")
        return directList
    }
    func directSearchFinished(chosen: DirectResult?, stoppedDuringLookup: Bool) {
        directFinished.append(chosen)
        directStopped.append(stoppedDuringLookup)
    }
    func openWatchPage(_ url: String) async -> Bool {
        events.append("openWatch")
        guard chromeInstalled else { return false }
        watchOpenedAt = clock
        watchOpens.append(url)
        return true
    }

    func browserIsRunning() -> Bool { browserRunning }
    func openFailed(waitedSeconds: Double) { openFailedWaits.append(waitedSeconds) }
    func openSearchPage(_ url: String) async -> Bool { openCount += 1; return chromeInstalled }
    func pageURL() async -> String? { pageURLCalls += 1; return pageURLs(self) }
    func links() async -> [LinkCandidate] { linksCalls += 1; return linkList(self) }
    func buttonLabels() async -> [String] { buttons(self) }
    func press(_ link: LinkCandidate) async -> ActionEffect? {
        linkPressCount += 1
        pressedAt = clock
        return .unverifiable
    }
    func pressButton(at index: Int) async -> ActionEffect { playPressCount += 1; return .unverifiable }

    func askConsent(_ link: LinkCandidate, timeout: Double) async -> MediaRunEvent {
        askCount += 1
        events.append("ask")
        duringAsk(self)
        clock += 1
        return consentAnswer
    }

    func show(_ state: MediaRunState, line: String) async {
        shown.append((state, line))
        if (state == .opening && holdOpeningLine) || (state == .searching && holdSearchingLine) {
            await withCheckedContinuation { openingLineRelease = $0 }
        }
    }

    func releaseOpeningLine() {
        openingLineRelease?.resume()
        openingLineRelease = nil
    }

    func pendingInterrupt() -> MediaRunEvent? {
        defer { queuedInterrupt = nil }
        return queuedInterrupt ?? interruptWhen(self)
    }

    func sleep(seconds: Double) async { clock += seconds }
    func now() -> Double { clock }
    func record(_ record: StepRecord) { records.append(record) }
}

@MainActor
final class MediaRunDriverTests: XCTestCase {
    private let request = MediaRequest(query: "lucid dreams",
                                       searchURL: "https://www.youtube.com/results?search_query=lucid+dreams",
                                       domainLock: "youtube.com")

    private func run(_ world: FakeWorld, caps: AgentCaps = AgentCaps()) async -> MediaRunState {
        await MediaRunDriver(request: request, caps: caps, world: world).run()
    }

    // MARK: - the happy path

    func testHappyPathEndsPlayingWithOneAskAndOnePress() async {
        let world = FakeWorld()
        let final = await run(world)
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.askCount, 1)
        XCTAssertEqual(world.linkPressCount, 1)
        XCTAssertEqual(world.playPressCount, 0)
        XCTAssertEqual(world.shown.map(\.state), [.searching, .opening, .locating, .asking(FakeWorld.link),
                                                  .pressing(FakeWorld.link), .verifying(attempt: 0), .playing])
        XCTAssertEqual(world.shown.map(\.line).first, "looking up lucid dreams on youtube.")
        XCTAssertEqual(world.shown.map(\.line)[1], "opening youtube for lucid dreams in the background.")
        XCTAssertEqual(world.shown.map(\.line).last, "playing lucid dreams on youtube.")
    }

    func testPageOpensWhileTheOpeningLineIsStillBeingSpoken() async {
        let world = FakeWorld()
        world.holdOpeningLine = true
        let driver = MediaRunDriver(request: request, world: world)
        let running = Task { await driver.run() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(world.openCount, 1)
        // The opening line is still being spoken, so nothing after it has been shown.
        XCTAssertEqual(world.shown.map(\.state), [.searching, .opening])
        world.releaseOpeningLine()
        let final = await running.value
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.shown.map(\.state), [.searching, .opening, .locating, .asking(FakeWorld.link),
                                                  .pressing(FakeWorld.link), .verifying(attempt: 0), .playing])
    }

    func testAForegroundRequestSaysSoInTheOpeningLine() async {
        let world = FakeWorld()
        let foreground = MediaRequest(query: "lucid dreams", searchURL: request.searchURL,
                                      domainLock: "youtube.com", foreground: true)
        let final = await MediaRunDriver(request: foreground, world: world).run()
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.shown.map(\.line)[1], "opening youtube for lucid dreams.")
    }

    func testRecordsAreNumberedInOrderAndTimed() async {
        let world = FakeWorld()
        _ = await run(world)
        XCTAssertEqual(world.records.map(\.index), Array(1...world.records.count))
        XCTAssertEqual(world.records.map(\.millisSinceStart), world.records.map(\.millisSinceStart).sorted())
        XCTAssertEqual(world.records.last?.step, "playing")
        let consent = world.records.compactMap(\.consent)
        XCTAssertEqual(consent.map(\.answer), ["yes"])
        XCTAssertEqual(world.records.first { $0.step == "verifying0" }?.effect, .unverifiable)
    }

    func testPageTextNeverReachesALineOrARecord() async {
        for tweak: (FakeWorld) -> Void in [
            { _ in },
            { $0.consentAnswer = .consentNo },
            { $0.linkList = { _ in [FakeWorld.link] }; $0.buttons = { _ in ["Play"] } },
        ] {
            let world = FakeWorld()
            tweak(world)
            _ = await run(world)
            for line in world.shown.map(\.line) {
                XCTAssertFalse(line.contains("Juice"), line)
            }
            for record in world.records {
                XCTAssertFalse("\(record)".contains("Juice"), "\(record)")
            }
        }
    }

    // MARK: - the direct path

    private func directWorld(readable: Bool = true) -> FakeWorld {
        let world = FakeWorld()
        world.directList = [FakeWorld.directResult]
        world.pageURLs = { readable && $0.watchOpened ? FakeWorld.directWatchURL : nil }
        return world
    }

    func testDirectPathAsksAboutTheNamedVideoAndOpensItOnlyAfterTheYes() async {
        let world = directWorld()
        let final = await run(world)
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.events, ["direct", "ask", "openWatch"])
        XCTAssertEqual(world.openCount, 0, "the results page is never opened on the direct path")
        XCTAssertEqual(world.watchOpens, [FakeWorld.directWatchURL])
        XCTAssertEqual(world.linkPressCount, 0)
        XCTAssertEqual(world.directFinished, [FakeWorld.directResult])
        XCTAssertEqual(world.shown.map(\.state), [.searching, .askingDirect(FakeWorld.directResult),
                                                  .openingVideo(FakeWorld.directResult), .verifying(attempt: 0), .playing])
        XCTAssertEqual(world.shown.map(\.line), [
            "looking up lucid dreams on youtube.",
            "should i play \(FakeWorld.label) on youtube? say yes, or press return.",
            "opening the video in the background.",
            "checking that it plays.",
            "playing lucid dreams on youtube.",
        ])
    }

    func testTheTitleIsInTheAskingLineOnlyAndNeverInARecord() async {
        let world = directWorld()
        _ = await run(world)
        XCTAssertEqual(world.shown.filter { $0.line.contains("Juice") }.map(\.state), [.askingDirect(FakeWorld.directResult)])
        for record in world.records { XCTAssertFalse("\(record)".contains("Juice"), "\(record)") }
        XCTAssertEqual(world.records.compactMap(\.consent).map(\.answer), ["yes"])
    }

    func testTheSearchPageIsFetchedWhileTheSearchingLineIsStillBeingSpoken() async {
        let world = directWorld()
        world.holdSearchingLine = true
        let driver = MediaRunDriver(request: request, world: world)
        let running = Task { await driver.run() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(world.directCalls, 1)
        XCTAssertEqual(world.shown.map(\.state), [.searching])
        world.releaseOpeningLine()
        let final = await running.value
        XCTAssertEqual(final, .playing)
    }

    func testDirectPathWithAnUnreadablePageEndsOpenedNotPlaying() async {
        let world = directWorld(readable: false)
        let final = await run(world)
        XCTAssertEqual(final, .opened)
        XCTAssertEqual(world.watchOpens.count, 1)
        XCTAssertEqual(world.shown.last?.line, "i opened the video for lucid dreams in chrome, but i can't tell whether it started.")
        XCTAssertFalse(world.shown.last?.line.contains("playing") ?? true)
        XCTAssertEqual(world.records.first { $0.step == "verifying0" }?.effect, .unverifiable)
        XCTAssertEqual(world.records.last?.step, "opened")
        XCTAssertGreaterThanOrEqual(world.clock, AgentCaps().verifySeconds)
    }

    func testAnotherWatchPageDoesNotCountAsThisVideoPlaying() async {
        let world = directWorld()
        world.pageURLs = { $0.watchOpened ? "https://www.youtube.com/watch?v=someoneelse" : nil }
        let final = await run(world)
        XCTAssertEqual(final, .opened)
    }

    func testDirectPathPressesPlayOnceWhenThePageIsReadableButNotPlaying() async {
        let world = directWorld()
        world.buttons = { $0.playPressCount > 0 ? ["Pause (k)"] : ["Play (k)"] }
        let final = await run(world)
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.playPressCount, 1)
        let stuck = directWorld()
        stuck.buttons = { _ in ["Play (k)"] }
        let stuckFinal = await run(stuck)
        XCTAssertEqual(stuckFinal, .handoff(.didNotStart))
    }

    func testDeclineOpensNothing() async {
        for answer in [MediaRunEvent.consentNo, .consentTimeout] {
            let world = directWorld()
            world.consentAnswer = answer
            let final = await run(world)
            XCTAssertEqual(final, answer == .consentNo ? .stopped(.declined) : .stopped(.consentTimeout))
            XCTAssertTrue(world.watchOpens.isEmpty)
            XCTAssertEqual(world.openCount, 0)
        }
    }

    func testAStopAfterTheYesButBeforeTheOpenOpensNothing() async {
        let world = directWorld()
        world.interruptWhen = { $0.askCount > 0 ? .stopButton : nil }
        let final = await run(world)
        XCTAssertEqual(final, .stopped(.stopButton))
        XCTAssertTrue(world.watchOpens.isEmpty)
    }

    func testAStopWhileSearchingOpensNothing() async {
        let world = directWorld()
        world.interruptWhen = { _ in .userInput }
        let final = await run(world)
        XCTAssertEqual(world.directStopped, [true])
        XCTAssertEqual(final, .stopped(.userInput))
        XCTAssertEqual(world.askCount, 0)
        XCTAssertTrue(world.watchOpens.isEmpty)
        XCTAssertEqual(world.openCount, 0)
    }

    // MARK: - cold browser verify window

    /// The watch page is readable `seconds` after it was opened.
    private func directWorldReadableAfter(_ seconds: Double, running: Bool) -> FakeWorld {
        let world = FakeWorld()
        world.directList = [FakeWorld.directResult]
        world.browserRunning = running
        world.pageURLs = { $0.watchOpened && $0.clock - $0.watchOpenedAt >= seconds ? FakeWorld.directWatchURL : nil }
        return world
    }

    func testColdBrowserVerifiesForTheColdWindowAfterADirectOpen() async {
        let cold = directWorldReadableAfter(10, running: false)
        let coldFinal = await run(cold)
        XCTAssertEqual(coldFinal, .playing)
        let warm = directWorldReadableAfter(10, running: true)
        let warmFinal = await run(warm)
        XCTAssertEqual(warmFinal, .opened)
    }

    func testColdBrowserVerifyIsStillBoundedByTheWallClock() async {
        let world = directWorldReadableAfter(1000, running: false)
        let caps = AgentCaps(wallClockSeconds: 12)
        let final = await run(world, caps: caps)
        XCTAssertEqual(final, .capped(.time))
        XCTAssertLessThan(world.clock, caps.pageLoadColdSeconds + 12)
    }

    func testColdBrowserVerifiesForTheColdWindowAfterAPress() async {
        func world(running: Bool) -> FakeWorld {
            let world = FakeWorld()
            world.browserRunning = running
            // The results page is readable at once; the watch page only 10 s after the press.
            world.pageURLs = { world in
                guard world.linkPressed else { return FakeWorld.resultsURL }
                return world.clock - world.pressedAt >= 10 ? FakeWorld.watchURL : FakeWorld.resultsURL
            }
            return world
        }
        let cold = world(running: false)
        let coldFinal = await run(cold)
        XCTAssertEqual(coldFinal, .playing)
        let warm = world(running: true)
        let warmFinal = await run(warm)
        XCTAssertEqual(warmFinal, .handoff(.didNotOpen))
    }

    func testChromeMissingAfterTheYesHandsOff() async {
        let world = directWorld()
        world.chromeInstalled = false
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.chromeMissing))
    }

    func testNoDirectResultFallsBackToThePagePath() async {
        let world = FakeWorld()
        let final = await run(world)
        XCTAssertEqual(world.directStopped, [false])
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.directFinished.count, 1)
        XCTAssertNil(world.directFinished[0] ?? nil)
        XCTAssertEqual(world.openCount, 1)
        XCTAssertTrue(world.watchOpens.isEmpty)
        XCTAssertEqual(world.linkPressCount, 1)
    }

    func testTheQueryPicksAmongDirectResults() async {
        let world = directWorld()
        let other = DirectResult(videoID: "zzzzzzzzzzz", title: "Something unrelated")
        world.directList = [other, FakeWorld.directResult]
        _ = await run(world)
        XCTAssertEqual(world.directFinished, [FakeWorld.directResult])
        XCTAssertEqual(world.watchOpens, [FakeWorld.directWatchURL])
    }

    // MARK: - consent

    func testDeclineStopsWithoutPressing() async {
        let world = FakeWorld()
        world.consentAnswer = .consentNo
        let final = await run(world)
        XCTAssertEqual(final, .stopped(.declined))
        XCTAssertEqual(world.linkPressCount, 0)
        XCTAssertEqual(world.shown.last?.line, "okay, i won't play it.")
    }

    func testConsentTimeoutStopsWithoutPressing() async {
        let world = FakeWorld()
        world.consentAnswer = .consentTimeout
        let final = await run(world)
        XCTAssertEqual(final, .stopped(.consentTimeout))
        XCTAssertEqual(world.linkPressCount, 0)
    }

    func testInterruptDuringAskingIsIgnored() async {
        let world = FakeWorld()
        world.duringAsk = { $0.queuedInterrupt = .userInput }
        let final = await run(world)
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.linkPressCount, 1)
    }

    // MARK: - the target

    func testTargetMovedAfterConsentHandsOffWithoutPressing() async {
        let world = FakeWorld()
        world.linkList = { world in
            let moved = LinkCandidate(label: FakeWorld.label, url: FakeWorld.link.url,
                                      frame: FakeWorld.link.frame.offsetBy(dx: 0, dy: 50))
            return world.askCount == 0 ? [FakeWorld.link] : [moved]
        }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.targetChanged))
        XCTAssertEqual(world.linkPressCount, 0)
    }

    func testTargetGoneAfterConsentHandsOffWithoutPressing() async {
        let world = FakeWorld()
        world.linkList = { $0.askCount == 0 ? [FakeWorld.link] : [] }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.targetChanged))
        XCTAssertEqual(world.linkPressCount, 0)
    }

    func testSmallMoveAfterConsentStillPresses() async {
        let world = FakeWorld()
        world.linkList = { world in
            let nudged = LinkCandidate(label: FakeWorld.label, url: FakeWorld.link.url,
                                       frame: FakeWorld.link.frame.offsetBy(dx: 0, dy: 6))
            return world.askCount == 0 ? [FakeWorld.link] : [nudged]
        }
        let final = await run(world)
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.linkPressCount, 1)
    }

    func testSameTargetToleratesEightPointsPerEdgeAndNoMore() {
        let link = FakeWorld.link
        func moved(_ dx: CGFloat, width: CGFloat = 0) -> LinkCandidate {
            LinkCandidate(label: link.label, url: link.url,
                          frame: CGRect(x: link.frame.minX + dx, y: link.frame.minY,
                                        width: link.frame.width + width, height: link.frame.height))
        }
        XCTAssertTrue(MediaRunDriver.isSameTarget(moved(8), link))
        XCTAssertFalse(MediaRunDriver.isSameTarget(moved(9), link))
        XCTAssertFalse(MediaRunDriver.isSameTarget(moved(0, width: 9), link))
        let otherLabel = LinkCandidate(label: "x", url: link.url, frame: link.frame)
        XCTAssertFalse(MediaRunDriver.isSameTarget(otherLabel, link))
    }

    // MARK: - verifying

    func testNoPauseThenPlayPressWorks() async {
        let world = FakeWorld()
        world.buttons = { $0.playPressCount > 0 ? ["Pause (k)"] : ["Play (k)"] }
        let final = await run(world)
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.playPressCount, 1)
        XCTAssertEqual(world.linkPressCount, 1)
        XCTAssertTrue(world.records.contains { $0.step == "playPress" })
    }

    func testNoPauseTwiceHandsOffDidNotStart() async {
        let world = FakeWorld()
        world.buttons = { _ in ["Play (k)"] }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.didNotStart))
        XCTAssertEqual(world.playPressCount, 1)
    }

    func testPlayButtonNotFoundStillPollsAgainThenHandsOff() async {
        let world = FakeWorld()
        world.buttons = { _ in ["Settings"] }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.didNotStart))
        XCTAssertEqual(world.playPressCount, 0)
    }

    func testPageThatNeverBecomesAWatchPageHandsOffDidNotOpen() async {
        let world = FakeWorld()
        world.pageURLs = { _ in FakeWorld.resultsURL }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.didNotOpen))
        XCTAssertEqual(world.linkPressCount, 1)
    }

    func testInterruptDuringVerifyingStops() async {
        let world = FakeWorld()
        world.interruptWhen = { $0.linkPressed ? .userInput : nil }
        let final = await run(world)
        XCTAssertEqual(final, .stopped(.userInput))
    }

    func testPushToTalkDuringVerifyingStops() async {
        let world = FakeWorld()
        world.interruptWhen = { $0.linkPressed ? .pushToTalk : nil }
        let final = await run(world)
        XCTAssertEqual(final, .stopped(.pushToTalk))
    }

    func testStopButtonDuringVerifyingStopsWithTheStopLine() async {
        let world = FakeWorld()
        world.interruptWhen = { $0.linkPressed ? .stopButton : nil }
        let final = await run(world)
        XCTAssertEqual(final, .stopped(.stopButton))
        XCTAssertEqual(world.shown.last?.line, "stopped.")
    }

    // MARK: - opening and locating

    func testNeverReachingTheResultsPageHandsOffDidNotOpen() async {
        let world = FakeWorld()
        world.pageURLs = { _ in "https://www.google.com/" }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.didNotOpen))
        XCTAssertEqual(world.askCount, 0)
        XCTAssertGreaterThanOrEqual(world.clock, AgentCaps().pageLoadSeconds)
    }

    /// The results page appears at `seconds` of fake clock after the open.
    private func worldWithResultsAt(seconds: Double) -> FakeWorld {
        let world = FakeWorld()
        world.pageURLs = { $0.linkPressed ? FakeWorld.watchURL : ($0.clock >= seconds ? FakeWorld.resultsURL : nil) }
        return world
    }

    func testColdStartWaitsForTheColdCapAndReachesThePlayingFlow() async {
        let world = worldWithResultsAt(seconds: 10)
        world.browserRunning = false
        let final = await run(world)
        XCTAssertEqual(final, .playing)
        XCTAssertEqual(world.askCount, 1)
        XCTAssertTrue(world.openFailedWaits.isEmpty)
    }

    func testWarmBrowserStillTimesOutAtTheShortCap() async {
        let world = worldWithResultsAt(seconds: 10)
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.didNotOpen))
        XCTAssertEqual(world.askCount, 0)
        XCTAssertLessThan(world.clock, AgentCaps().pageLoadColdSeconds)
        XCTAssertEqual(world.openFailedWaits.count, 1)
        XCTAssertGreaterThanOrEqual(world.openFailedWaits[0], AgentCaps().pageLoadSeconds)
    }

    func testColdStartThatNeverLoadsTimesOutAtTheColdCapAndReportsOnce() async {
        let world = FakeWorld()
        world.browserRunning = false
        world.pageURLs = { _ in nil }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.didNotOpen))
        XCTAssertGreaterThanOrEqual(world.clock, AgentCaps().pageLoadColdSeconds)
        XCTAssertEqual(world.openFailedWaits.count, 1)
        XCTAssertGreaterThanOrEqual(world.openFailedWaits[0], AgentCaps().pageLoadColdSeconds)
    }

    func testTheWallClockStillBoundsAColdStart() async {
        let world = FakeWorld()
        world.browserRunning = false
        world.pageURLs = { _ in nil }
        let caps = AgentCaps(wallClockSeconds: 8)
        let final = await run(world, caps: caps)
        XCTAssertEqual(final, .capped(.time))
        XCTAssertLessThan(world.clock, caps.pageLoadColdSeconds)
        XCTAssertTrue(world.openFailedWaits.isEmpty)
    }

    func testNoVideoLinksHandsOffNoResultAfterTheRetries() async {
        let world = FakeWorld()
        world.linkList = { _ in [] }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.noResult))
        XCTAssertEqual(world.linksCalls, 1 + MediaRunDriver.locateRetries)
        XCTAssertEqual(world.askCount, 0)
    }

    func testLinksThatAppearOnARetryAreUsed() async {
        let world = FakeWorld()
        world.linkList = { $0.linksCalls < 3 ? [] : [FakeWorld.link] }
        let final = await run(world)
        XCTAssertEqual(final, .playing)
    }

    func testOffDomainPageAfterTheResultsLoadedHandsOff() async {
        let world = FakeWorld()
        world.pageURLs = { $0.pageURLCalls == 1 ? FakeWorld.resultsURL : "https://example.com/ad" }
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.offDomain))
        XCTAssertEqual(world.askCount, 0)
    }

    func testChromeMissingHandsOff() async {
        let world = FakeWorld()
        world.chromeInstalled = false
        let final = await run(world)
        XCTAssertEqual(final, .handoff(.chromeMissing))
        XCTAssertEqual(world.shown.last?.line, "i need google chrome for this, and i can't find it.")
    }

    // MARK: - caps

    func testWallClockCapsTheRun() async {
        let world = FakeWorld()
        world.pageURLs = { _ in nil }
        let final = await run(world, caps: AgentCaps(wallClockSeconds: 3))
        XCTAssertEqual(final, .capped(.time))
    }

    func testWallClockExpiringDuringAskingPressesNothing() async {
        let world = FakeWorld()
        world.duringAsk = { $0.clock += 100 }
        let final = await run(world)
        XCTAssertEqual(final, .capped(.time))
        XCTAssertEqual(world.linkPressCount, 0)
    }

    func testStepCapStopsTheRun() async {
        let world = FakeWorld()
        let final = await run(world, caps: AgentCaps(maxSteps: 1))
        XCTAssertEqual(final, .capped(.steps))
        XCTAssertEqual(world.linkPressCount, 0)
    }
}
