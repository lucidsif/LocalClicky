//
//  MediaRunDriver.swift
//  LocalBrainKit
//
//  Runs one "play a video on youtube" run from start to a final state. Every side
//  effect (open the page, read links and buttons, press, ask the user, speak, wait)
//  goes through MediaRunWorld, so the whole flow is tested with a fake. The driver
//  owns the polling, the retries and the clocks; MediaRunMachine owns every
//  transition, so nothing here decides where a run goes next.
//
//  Page text (a link's label, a result's title) goes to the world's consent card. It is
//  never in a step record, and the only narration line that carries it is the question
//  before a direct open, which names the video the yes is for.
//
//  The run starts with a direct search (the results read from youtube's search page, nothing
//  opened). With a result it asks about that video and opens its watch page only after the yes.
//  With none it falls back to opening the results page in Chrome and reading it.
//

import CoreGraphics
import Foundation

@MainActor
public protocol MediaRunWorld: AnyObject {
    /// The video results read straight from youtube's search page, best first as the page ranks them.
    /// Empty when the fetch failed or nothing usable came back. Opens nothing in Chrome.
    func directResults(query: String) async -> [DirectResult]
    /// Called once after the driver chose among the direct results: the chosen one, or nil when none was
    /// usable. `stoppedDuringLookup` is true when a stop or the clock ended the run during the lookup, so
    /// the run does not fall back. For the world's log.
    func directSearchFinished(chosen: DirectResult?, stoppedDuringLookup: Bool)
    /// Opens a watch page in Chrome. False when Chrome is not installed.
    func openWatchPage(_ url: String) async -> Bool
    /// Whether Chrome is already running. Asked right before `openSearchPage`: a cold launch gets
    /// the longer `AgentCaps.pageLoadColdSeconds`.
    func browserIsRunning() -> Bool
    /// Opens the search page in Chrome. False when Chrome is not installed.
    func openSearchPage(_ url: String) async -> Bool
    /// The URL of the page in Chrome's front window, nil when it cannot be read.
    func pageURL() async -> String?
    /// The open step timed out after `waitedSeconds` (called once, only on that outcome), so the world
    /// can log what it sees.
    func openFailed(waitedSeconds: Double)
    func links() async -> [LinkCandidate]
    func buttonLabels() async -> [String]
    /// Presses the link, nil when the world no longer has it.
    func press(_ link: LinkCandidate) async -> ActionEffect?
    func pressButton(at index: Int) async -> ActionEffect
    /// Shows the consent card for the link and waits: consentYes, consentNo or consentTimeout.
    func askConsent(_ link: LinkCandidate, timeout: Double) async -> MediaRunEvent
    /// Shows (and speaks, or announces) the line for a state.
    func show(_ state: MediaRunState, line: String) async
    /// userInput, pushToTalk or stopButton since the last call, else nil.
    func pendingInterrupt() -> MediaRunEvent?
    func sleep(seconds: Double) async
    /// Seconds on a monotonic clock.
    func now() -> Double
    func record(_ record: StepRecord)
}

@MainActor
public final class MediaRunDriver {
    private let request: MediaRequest
    private let caps: AgentCaps
    private let world: MediaRunWorld

    private var state = MediaRunState.searching
    /// Set once the chosen video's watch page has been opened directly.
    private var openedDirectly: DirectResult?
    /// Whether the browser was already running when the run first opened anything. A browser that was
    /// not (a cold launch) gets the longer page-load window when verifying.
    private var browserWasRunning = true
    private var stepsTaken = 0
    private var recordCount = 0
    private var startedAt = 0.0
    private var resultsPageSeen = false
    private let runId = UUID().uuidString

    static let pollIntervalSeconds = 0.25
    /// Chrome may need a moment after being told an assistive client is reading.
    static let locateRetries = 3
    static let locateRetryGapSeconds = 0.5
    /// How far the page may move between locating the link and pressing it, per edge, in points.
    static let frameToleranceInPoints: CGFloat = 8

    public init(request: MediaRequest, caps: AgentCaps = AgentCaps(), world: MediaRunWorld) {
        self.request = request
        self.caps = caps
        self.world = world
    }

    public func run() async -> MediaRunState {
        startedAt = world.now()
        while !state.isFinal {
            switch state {
            case .searching: await search()
            case .opening: await openResultsPage()
            case .locating: await locate()
            case .asking(let link): await ask(link)
            case .askingDirect(let result): await ask(result.consentLink)
            case .openingVideo(let result): await openVideo(result)
            case .pressing(let link): await press(link)
            case .verifying(let attempt): await verify(attempt: attempt)
            case .playing, .opened, .handoff, .stopped, .capped: break
            }
        }
        return state
    }

    // MARK: - States

    /// Speaking the line takes seconds; the search page is fetched while it does. The line still
    /// finishes before the next state is shown. Nothing is opened in Chrome here.
    private func search() async {
        async let searchingLine: Void = announce()
        async let fetched = world.directResults(query: request.query)
        let results = await fetched
        await searchingLine
        let chosen = MediaResultPicker.bestResult(in: results, query: request.query)
        let stop = interruptOrTimeUp()
        world.directSearchFinished(chosen: chosen, stoppedDuringLookup: stop != nil)
        if let stop { return await apply(stop) }
        if let chosen { await apply(.directFound(chosen)) }
        // The opening line is said by the next state, so this change is not announced.
        else { await apply(.directUnavailable, announcing: false) }
    }

    /// The page path: speaking the opening line takes seconds, and the page starts loading while it does.
    private func openResultsPage() async {
        async let openingLine: Void = announce()
        let opened = await open()
        await openingLine
        await apply(opened)
    }

    /// After the yes: open the watch page. Nothing is opened before it, and a stop that came in while
    /// the line was spoken still wins.
    private func openVideo(_ result: DirectResult) async {
        if let stop = interruptOrTimeUp() { return await apply(stop) }
        await announce()
        if let stop = interruptOrTimeUp() { return await apply(stop) }
        stepsTaken += 1
        browserWasRunning = world.browserIsRunning()
        guard await world.openWatchPage(result.watchURL) else { return await apply(.chromeMissing) }
        openedDirectly = result
        await apply(.videoOpened, effect: .unverifiable)
    }

    private func open() async -> MediaRunEvent {
        let wasRunning = world.browserIsRunning()
        browserWasRunning = wasRunning
        let openedAt = world.now()
        guard await world.openSearchPage(request.searchURL) else { return .chromeMissing }
        stepsTaken += 1
        // A cold Chrome launch plus the results page takes longer; the wall clock still bounds the run.
        let event = await poll(seconds: wasRunning ? caps.pageLoadSeconds : caps.pageLoadColdSeconds) {
            guard let url = await self.world.pageURL() else { return nil }
            if self.isResultsPage(url) { return .pageLoaded }
            // Before the results page has loaded, whatever Chrome shows is the page it is leaving.
            return nil
        } ?? .pageTimeout
        if event == .pageLoaded { resultsPageSeen = true }
        if event == .pageTimeout { world.openFailed(waitedSeconds: world.now() - openedAt) }
        return event
    }

    private func locate() async {
        for attempt in 0...Self.locateRetries {
            if let stop = interruptOrTimeUp() { return await apply(stop) }
            if let off = offDomainEvent(url: await world.pageURL()) { return await apply(off) }
            if let link = MediaResultPicker.firstResult(in: await world.links(), query: request.query) {
                return await apply(.located(link))
            }
            if attempt < Self.locateRetries { await world.sleep(seconds: Self.locateRetryGapSeconds) }
        }
        await apply(.notFound)
    }

    private func ask(_ link: LinkCandidate) async {
        let askedAt = world.now()
        let remainingSeconds = caps.wallClockSeconds - (askedAt - startedAt)
        let answer = await world.askConsent(link, timeout: min(caps.consentTimeoutSeconds, max(remainingSeconds, 0)))
        let consent = ConsentRecord(shown: true, answer: Self.answerName(answer),
                                    millis: Int((world.now() - askedAt) * 1000))
        // Whatever the user did while the card was up was an answer, not a takeover.
        // The machine ignores it in this state, so it cannot leak into the next one.
        if let duringAsking = world.pendingInterrupt() { await apply(duringAsking) }
        if world.now() - startedAt >= caps.wallClockSeconds { return await apply(.timeUp) }
        // A yes is announced as "pressing" only once the target is confirmed (see press).
        await apply(answer, consent: consent, announcing: answer != .consentYes)
    }

    private func press(_ link: LinkCandidate) async {
        if let stop = interruptOrTimeUp() { return await apply(stop) }
        if let off = offDomainEvent(url: await world.pageURL()) { return await apply(off) }
        let current = await world.links().first { $0.url == link.url && $0.label == link.label }
        guard let current, Self.isSameTarget(current, link) else { return await apply(.targetChanged) }
        await apply(.targetConfirmed)
        await announce()
        if let stop = interruptOrTimeUp() { return await apply(stop) }
        stepsTaken += 1
        guard let effect = await world.press(link) else { return await apply(.targetChanged) }
        await apply(.pressed(effect), effect: effect)
    }

    private func verify(attempt: Int) async {
        if attempt > 0 { await pressPlayButton() }
        var sawWatchPage = false
        let direct = openedDirectly
        // A cold browser needs the longer window for the page to load and become readable; the wall clock still bounds it.
        let event = await poll(seconds: browserWasRunning ? caps.verifySeconds : caps.pageLoadColdSeconds) {
            let url = await self.world.pageURL()
            if let off = self.offDomainEvent(url: url) { return off }
            guard MediaPlaybackCheck.isWatchPage(url: url) else { return nil }
            // After a direct open only that video's page counts, not another watch tab.
            if let direct, MediaPlaybackCheck.videoID(inWatchURL: url) != direct.videoID { return nil }
            sawWatchPage = true
            let pausing = MediaPlaybackCheck.pauseButtonPresent(buttonLabels: await self.world.buttonLabels())
            return pausing ? .watchPageWithPause : nil
            // A page that cannot be read after a direct open is not a failure to open: the open was asked for.
        } ?? (sawWatchPage ? .watchPageNoPause : (direct == nil ? .notWatchPage : .cannotConfirm))
        await apply(event)
    }

    /// The one retry: the video page opened but is not playing, so press its Play button.
    private func pressPlayButton() async {
        guard let index = MediaPlaybackCheck.playButtonIndex(buttonLabels: await world.buttonLabels()) else { return }
        stepsTaken += 1
        let effect = await world.pressButton(at: index)
        record(step: "playPress", effect: effect, outcome: "pressed")
    }

    // MARK: - Moving between states

    /// Feeds one event to the machine. A change of state is recorded and, unless
    /// `announcing` is false, shown.
    private func apply(_ event: MediaRunEvent, effect: ActionEffect? = nil, consent: ConsentRecord? = nil,
                       announcing: Bool = true) async {
        let before = state
        state = MediaRunMachine.next(state, event, caps: caps, stepsTaken: stepsTaken)
        guard state != before else { return }
        record(step: Self.name(of: state), effect: effect, consent: consent,
               outcome: state.isFinal ? Self.name(of: state) : "entered")
        if announcing { await announce() }
    }

    private func announce() async {
        await world.show(state, line: AgentNarration.line(for: state, query: request.query, caps: caps,
                                                                foreground: request.foreground))
    }

    private func record(step: String, effect: ActionEffect? = nil, consent: ConsentRecord? = nil, outcome: String) {
        recordCount += 1
        world.record(StepRecord(runId: runId, task: "play-media", index: recordCount, step: step, effect: effect,
                                consent: consent, millisSinceStart: Int((world.now() - startedAt) * 1000),
                                outcome: outcome))
    }

    // MARK: - Reading the world

    /// Runs `check` every poll interval until it gives an event, the user interrupts, the wall clock
    /// runs out (those two are events too) or `seconds` pass (nil).
    private func poll(seconds: Double, _ check: () async -> MediaRunEvent?) async -> MediaRunEvent? {
        let deadline = world.now() + seconds
        while true {
            if let stop = interruptOrTimeUp() { return stop }
            if let event = await check() { return event }
            if world.now() >= deadline { return nil }
            await world.sleep(seconds: Self.pollIntervalSeconds)
        }
    }

    private func interruptOrTimeUp() -> MediaRunEvent? {
        if let interrupt = world.pendingInterrupt() { return interrupt }
        return world.now() - startedAt >= caps.wallClockSeconds ? .timeUp : nil
    }

    private func isResultsPage(_ url: String) -> Bool {
        guard MediaPlaybackCheck.isOnDomain(url: url, domainLock: request.domainLock),
              let path = URLComponents(string: url)?.path else { return false }
        return path == "/results"
    }

    /// Once the results page has loaded, an http(s) page off the domain lock ends the run.
    /// A page that cannot be read, or is not a web page, is not evidence of leaving.
    private func offDomainEvent(url: String?) -> MediaRunEvent? {
        guard resultsPageSeen, let url, let scheme = URLComponents(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !MediaPlaybackCheck.isOnDomain(url: url, domainLock: request.domainLock) else { return nil }
        return .offDomain
    }

    static func isSameTarget(_ a: LinkCandidate, _ b: LinkCandidate) -> Bool {
        a.url == b.url && a.label == b.label
            && abs(a.frame.minX - b.frame.minX) <= frameToleranceInPoints
            && abs(a.frame.maxX - b.frame.maxX) <= frameToleranceInPoints
            && abs(a.frame.minY - b.frame.minY) <= frameToleranceInPoints
            && abs(a.frame.maxY - b.frame.maxY) <= frameToleranceInPoints
    }

    // MARK: - Names for the log (never carry page text)

    private static func answerName(_ event: MediaRunEvent) -> String {
        switch event {
        case .consentYes: return "yes"
        case .consentNo: return "no"
        default: return "timeout"
        }
    }

    private static func name(of state: MediaRunState) -> String {
        switch state {
        case .searching: return "searching"
        case .opening: return "opening"
        case .locating: return "locating"
        case .asking: return "asking"
        case .askingDirect: return "askingDirect"
        case .openingVideo: return "openingVideo"
        case .pressing: return "pressing"
        case .verifying(let attempt): return "verifying\(attempt)"
        case .playing: return "playing"
        case .opened: return "opened"
        case .handoff(let reason): return "handoff.\(reason)"
        case .stopped(let reason): return "stopped.\(reason)"
        case .capped(let reason): return "capped.\(reason)"
        }
    }
}
