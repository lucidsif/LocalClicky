//
//  MediaAgentRun.swift
//  LocalClicky
//
//  One "go to youtube and play X" run in the app: the MediaRunWorld that
//  MediaRunDriver drives. It opens the search page in Chrome, reads and presses
//  the page through the Accessibility backend, shows the step card and the ghost
//  pointer, speaks (or, with VoiceOver on, announces) the fixed narration lines,
//  and watches for the user taking over.
//
//  A run works in the background unless the request asks for the foreground: Chrome is
//  opened without coming to the front, nothing activates LocalClicky, and the mouse and
//  key interlocks are off, so the user can keep working in other apps. Only the talk keys,
//  the card's Stop, No and Escape, a spoken no, the caps and leaving youtube.com end it.
//  In the foreground Chrome comes up and a real mouse move or key press ends the run.
//
//  The run owns its own Task. A key press cancels CompanionManager's response
//  task, and that must not end a run: only the interlocks below do, and each of
//  them only queues an event that the driver reads between steps.
//
//  Page text (link labels, button labels) goes to the consent card and, while the
//  TEMP debug logger is on, to its local file. It is never spoken or announced.
//
//  Chrome is told an assistive client is reading once per run, before the page is opened (or, for a cold
//  launch, at the first read after it started): AXBackend.beginWebContentAccess. If Chrome needed
//  AXEnhancedUserInterface to expose its page, the run puts it back as soon as it reaches a final
//  state (and again when the driver returns, which does nothing twice).
//

import AppKit
import Combine
import LocalBrainKit
import LocalClickyActions

@MainActor
final class MediaAgentRun: MediaRunWorld {
    private static let chromeBundleIdentifier = "com.google.Chrome"
    private static let linkWalkBudgetSeconds = 1.5
    private static let buttonWalkBudgetSeconds = 1.0
    private static let mousePollSeconds = 0.05
    private static let finalCardSeconds = 4.0
    private static let consentLabelMaxCharacters = 120
    private static let loggedLinkCount = 40
    private static let walkTelemetryBudgetSeconds = 1.0

    private struct LinkKey: Hashable {
        let url: String
        let label: String
    }

    private let request: MediaRequest
    private let speak: (String) async -> Void
    private let keyDowns: AnyPublisher<Int64, Never>
    private let backend = ActionBackends.current()
    private let ghost = GhostPointerWindow()
    private lazy var panel = AgentRunPanel(
        query: request.query,
        consentSeconds: Int(AgentCaps().consentTimeoutSeconds),
        onAnswer: { [weak self] in self?.answer($0) },
        onStop: { [weak self] in self?.stop() })

    private var task: Task<Void, Never>?
    private var queuedInterrupt: MediaRunEvent?
    private var mouseTimer: Timer?
    private var mouseBaseline: CGPoint?
    private var keyDownCancellable: AnyCancellable?

    /// The first live element for each link of the last walk, so a press reaches the same element.
    private var linkElements: [LinkKey: WebElement] = [:]
    private var buttonElements: [WebElement] = []
    private var loggedLinks = false
    private var loggedButtons = false
    /// For the TEMP agent-open event: Chrome's state at the open and the last page URL read.
    private var chromeWasRunningAtOpen = false
    private var lastPageURL: String?
    /// The Chrome process this run has made readable (beginWebContentAccess), when, and what the TEMP
    /// agent-walk events may still log. firstWebAreaMs is for agent-end: begin to the first page read.
    private var accessBegunPid: pid_t?
    private var accessBegunAt: Double?
    private var walkBudget: WalkTelemetryBudget?
    private var firstWebAreaMs: Int?
    /// For the TEMP agent-direct event: the fetch of the search page.
    private var directFetch: YouTubeDirectSearch.Outcome?

    private var consentContinuation: CheckedContinuation<MediaRunEvent, Never>?
    /// An answer that came while the question was still being spoken.
    private var earlyConsent: MediaRunEvent?

    private(set) var isActive = false
    /// True from the moment the question is put up until it is answered or times out.
    private(set) var isAsking = false

    init(request: MediaRequest, keyDowns: AnyPublisher<Int64, Never>, speak: @escaping (String) async -> Void) {
        self.request = request
        self.keyDowns = keyDowns
        self.speak = speak
    }

    // MARK: - Lifecycle

    func start(onFinish: @escaping @MainActor (MediaRunState) -> Void) {
        isActive = true
        if request.foreground { startInterlocks() }
        task = Task {
            let finalState = await MediaRunDriver(request: request, world: self).run()
            endWebContentAccess(finalState: nil)
            onFinish(finalState)
            try? await Task.sleep(nanoseconds: UInt64(Self.finalCardSeconds * 1_000_000_000))
            if !Task.isCancelled { panel.hide() }
        }
    }

    /// Queues a takeover for the driver to read. Ignored while asking (a spoken answer starts with
    /// a push-to-talk press, and Return and Escape are the answer) and once the run is over.
    func interrupt(_ event: MediaRunEvent) {
        guard isActive, !isAsking, queuedInterrupt == nil else { return }
        queuedInterrupt = event
    }

    /// Closes the card of a finished run at once, so a new run does not draw over it.
    func dismiss() {
        guard !isActive else { return }
        task?.cancel()
        panel.hide()
    }

    func answer(_ answer: ConsentAnswer) {
        resolveConsent(answer == .yes ? .consentYes : .consentNo)
    }

    /// The card's Stop button. While asking, stopping is saying no.
    private func stop() {
        if isAsking { answer(.no) } else { interrupt(.stopButton) }
    }

    private func resolveConsent(_ event: MediaRunEvent) {
        // Exactly one answer per question: a second Return or a late timeout finds this false.
        guard isAsking else { return }
        isAsking = false
        // The user may have moved the mouse to click Yes; the run's baseline starts over here.
        mouseBaseline = nil
        panel.endAsking()
        if let continuation = consentContinuation {
            consentContinuation = nil
            continuation.resume(returning: event)
        } else {
            earlyConsent = event
        }
    }

    // MARK: - Interlocks

    private func startInterlocks() {
        mouseBaseline = nil
        let timer = Timer(timeInterval: Self.mousePollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
        keyDownCancellable = keyDowns
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userData in
                if InputInterlock.shouldStop(keyDownWithUserData: userData) { self?.interrupt(.userInput) }
            }
    }

    private func stopInterlocks() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        keyDownCancellable = nil
    }

    private func checkMouse() {
        guard !isAsking else { return }
        let location = NSEvent.mouseLocation
        guard let baseline = mouseBaseline else { mouseBaseline = location; return }
        if InputInterlock.shouldStop(mouseTravel: hypot(location.x - baseline.x, location.y - baseline.y)) {
            interrupt(.userInput)
        }
    }

    // MARK: - MediaRunWorld

    func browserIsRunning() -> Bool {
        chromeWasRunningAtOpen = chromeProcessIdentifier() != nil
        return chromeWasRunningAtOpen
    }

    func directResults(query: String) async -> [DirectResult] {
        let outcome = await YouTubeDirectSearch.fetch(searchURL: request.searchURL)
        directFetch = outcome
        return outcome.results
    }

    func directSearchFinished(chosen: DirectResult?, stoppedDuringLookup: Bool) {
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("agent-direct", [
            "fetchMillis": directFetch?.millis ?? 0,
            "resultCount": directFetch?.results.count ?? 0,
            "chosenVideoId": Self.orNull(chosen?.videoID),
            "chosenTitle": Self.orNull(chosen.map { String($0.title.prefix(120)) }),
            "fellBack": chosen == nil && !stoppedDuringLookup,
            "stoppedDuringLookup": stoppedDuringLookup,
            "error": Self.orNull(directFetch?.error),
        ])
    }

    func openSearchPage(_ url: String) async -> Bool { await openInChrome(url) }

    func openWatchPage(_ url: String) async -> Bool { await openInChrome(url) }

    private func openInChrome(_ url: String) async -> Bool {
        // BrowserActionExecutor falls back to the default browser; this run reads Chrome only.
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.chromeBundleIdentifier) != nil else {
            return false
        }
        // A running Chrome is made readable before the page opens, so the new tab starts with the tree on.
        await ensureWebContentAccess()
        BrowserActionExecutor.execute(BrowserPlan(actions: [BrowserAction(url: url, label: "youtube")],
                                                  spokenSummary: ""),
                                      activates: request.foreground)
        return true
    }

    func pageURL() async -> String? {
        await ensureWebContentAccess()
        guard let pid = chromeProcessIdentifier() else { return nil }
        let url = await backend.pageState(pid: pid)?.pageURL
        lastPageURL = url
        if url != nil, firstWebAreaMs == nil, let begun = accessBegunAt {
            firstWebAreaMs = Int((now() - begun) * 1000)
        }
        await logWalkTelemetry(pid: pid)
        return url
    }

    /// Tells Chrome an assistive client is reading, once per Chrome process in this run, and writes the
    /// TEMP agent-ax events (one per attribute set). Does nothing when Chrome is not running yet.
    private func ensureWebContentAccess() async {
        guard let pid = chromeProcessIdentifier(), accessBegunPid != pid else { return }
        accessBegunPid = pid
        accessBegunAt = now()
        walkBudget = WalkTelemetryBudget(startedAt: now())
        let attempts = await backend.beginWebContentAccess(pid: pid)
        for attempt in attempts {
            // TEMP debug logger (remove at project end)
            TempAppDebugLog.append("agent-ax", attempt.logFields)
        }
    }

    /// The TEMP agent-walk event: a look at Chrome's front window while the page is being made readable.
    /// Only while the debug flag is on, for 10 seconds after the access began, at most 20 times a run.
    private func logWalkTelemetry(pid: pid_t) async {
        guard TempAppDebugLog.isOn, walkBudget?.shouldLog(now: now()) == true else { return }
        guard let telemetry = await backend.walkTelemetry(pid: pid, budget: Self.walkTelemetryBudgetSeconds) else { return }
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("agent-walk", telemetry.logFields)
    }

    func openFailed(waitedSeconds: Double) {
        let pid = chromeProcessIdentifier()
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("agent-open", [
            "axTrusted": AXIsProcessTrusted(),
            "chromeWasRunning": chromeWasRunningAtOpen,
            "chromeRunningNow": pid != nil,
            "chromePid": Self.orNull(pid.map { Int($0) }),
            "lastPageURL": Self.orNull(lastPageURL),
            "manualAXResult": Self.orNull(pid.flatMap { backend.lastManualAccessibilityResult(pid: $0) }.map { Int($0) }),
            "axMode": Self.orNull(pid.map { backend.webContentMode(pid: $0).rawValue }),
            "waitedSeconds": (waitedSeconds * 10).rounded() / 10,
            "foreground": request.foreground,
        ])
    }

    func links() async -> [LinkCandidate] {
        await ensureWebContentAccess()
        guard let pid = chromeProcessIdentifier() else { return [] }
        let found = await backend.walk(pid: pid, roles: ["AXLink"], budget: Self.linkWalkBudgetSeconds)
        linkElements = [:]
        for element in found {
            let key = LinkKey(url: element.url ?? "", label: element.label)
            if linkElements[key] == nil { linkElements[key] = element }
        }
        if !loggedLinks {
            loggedLinks = true
            // TEMP debug logger (remove at project end)
            TempAppDebugLog.append("agent-links", [
                "links": found.prefix(Self.loggedLinkCount).map { [String($0.label.prefix(120)), $0.url ?? ""] },
            ])
        }
        return found.map(\.linkCandidate)
    }

    func buttonLabels() async -> [String] {
        await ensureWebContentAccess()
        guard let pid = chromeProcessIdentifier() else { return [] }
        buttonElements = await backend.walk(pid: pid, roles: ["AXButton"], budget: Self.buttonWalkBudgetSeconds)
        let labels = buttonElements.map(\.label)
        if !loggedButtons {
            loggedButtons = true
            // TEMP debug logger (remove at project end)
            TempAppDebugLog.append("agent-buttons", ["buttons": labels])
        }
        return labels
    }

    func press(_ link: LinkCandidate) async -> ActionEffect? {
        guard let element = linkElements[LinkKey(url: link.url, label: link.label)] else { return nil }
        return await backend.press(element)
    }

    func pressButton(at index: Int) async -> ActionEffect {
        guard buttonElements.indices.contains(index) else { return .noop }
        return await backend.press(buttonElements[index])
    }

    func askConsent(_ link: LinkCandidate, timeout: Double) async -> MediaRunEvent {
        if let early = earlyConsent {
            earlyConsent = nil
            return early
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { self?.resolveConsent(.consentTimeout) }
        }
        let event = await withCheckedContinuation { consentContinuation = $0 }
        timeoutTask.cancel()
        return event
    }

    func show(_ state: MediaRunState, line: String) async {
        var line = line
        panel.show(state, line: line)
        var consentLink: LinkCandidate?
        var consentText: String?
        switch state {
        case .asking(let link): consentLink = link; consentText = link.label
        case .askingDirect(let result): consentText = result.title
        default: break
        }
        if let consentText {
            isAsking = true
            earlyConsent = nil
            // The card shows the link text or title; it is page text, so it is cut short here. The
            // asking line carries a direct result's title (a spoken, shortened copy) and nothing else from the page.
            panel.beginAsking(label: String(consentText.prefix(Self.consentLabelMaxCharacters)))
            // Decide whether the card has the keyboard before the question is spoken.
            let keyboardAnswers = await panel.confirmKeyboardAnswers()
            print("🧭 consent panel key: \(keyboardAnswers)")
            line = AgentNarration.line(for: state, query: request.query, foreground: request.foreground,
                                       keyboardAnswers: keyboardAnswers)
            // In the background Chrome is usually covered, and the arrow would point into another app.
            // A direct result has no place on a page, so it gets no arrow.
            if let consentLink, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.chromeBundleIdentifier {
                ghost.show(atCGGlobalPoint: CGPoint(x: consentLink.frame.midX, y: consentLink.frame.midY))
            }
        }
        if state.isFinal {
            isActive = false
            isAsking = false
            stopInterlocks()
            ghost.hide()
            endWebContentAccess(finalState: state)
        }
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: line,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        } else if Self.isSpoken(state) {
            await speak(line)
        }
    }

    func pendingInterrupt() -> MediaRunEvent? {
        defer { queuedInterrupt = nil }
        return queuedInterrupt
    }

    func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func record(_ record: StepRecord) {
        guard let data = try? JSONEncoder().encode(record),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("agent", fields)
    }

    // MARK: - Helpers

    /// The states that are spoken aloud; every other state only updates the card.
    private static func isSpoken(_ state: MediaRunState) -> Bool {
        switch state {
        case .searching, .opening, .asking, .askingDirect, .openingVideo, .pressing, .playing, .opened, .handoff, .capped:
            return true
        case .locating, .verifying: return false
        // The user is already talking to Clicky; speech now would land in the microphone.
        case .stopped(let reason): return reason != .pushToTalk
        }
    }

    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    /// Gives Chrome its AXEnhancedUserInterface back (a no-op unless this run changed it). With a
    /// `finalState` it also writes the TEMP agent-end event: which attribute worked and whether
    /// something was restored.
    private func endWebContentAccess(finalState: MediaRunState?) {
        guard let pid = chromeProcessIdentifier() else { return }
        let mode = backend.webContentMode(pid: pid)
        let restore = backend.endWebContentAccess(pid: pid)
        guard let finalState else { return }
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("agent-end", [
            "state": String(describing: finalState), "axMode": mode.rawValue, "restored": restore.restored,
            "lastPageURL": Self.orNull(lastPageURL), "firstWebAreaMs": Self.orNull(firstWebAreaMs),
            "restoreAXError": Self.orNull(restore.axError.map { Int($0) }),
            "readBackAfterRestore": Self.orNull(restore.readBackAfterRestore),
        ])
    }

    private func chromeProcessIdentifier() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleIdentifier).first?.processIdentifier
    }
}
