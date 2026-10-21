//
//  DraftAgentRun.swift
//  LocalClicky
//
//  One "open an email draft" run in the app: the DraftRunWorld that DraftRunDriver drives. It shows
//  the step card, speaks (or, with VoiceOver on, announces) the fixed lines, calls the draft model
//  through the same gateway client chat uses, and opens the compose link in its app in the background.
//
//  It sends nothing. Its only effects on a mail app are opening a link and, for the page features,
//  setting a compose body's value and pressing a message row or the Reply button through the backend
//  (SendGuard applies). It never presses a link, moves no pointer, sets no focus and posts no key
//  events. The page is made readable once per run (beginWebContentAccess) and put back at the end.
//  The message, the address and page text stay out of the debug log; the TEMP `draft` event carries
//  counts and names only.
//

import AppKit
import LocalBrainKit
import LocalClickyActions

@MainActor
final class DraftAgentRun: DraftRunWorld {
    private static let finalCardSeconds = 6.0

    private let request: EmailDraftRequest
    private let speak: (String) async -> Void
    private let client: OllamaClient
    private let model: String
    private let keepAlive: String
    private let contextWindow: Int
    private let backend = ActionBackends.current()
    private lazy var panel = DraftRunPanel(request: request, onAnswer: { [weak self] in self?.answer($0) },
                                           onStop: { [weak self] in self?.stopPressed() })

    private var task: Task<Void, Never>?
    private var stopFlag = false
    private(set) var isActive = false
    /// True from the moment the question is put up until it is answered or times out.
    private(set) var isAsking = false
    private var givenAnswer: ConsentAnswer?
    /// The process this run made readable, and the compose bodies and message rows last found.
    private var accessPid: pid_t?
    private var fields: [ComposeField] = []
    private var rows: [WebElement] = []
    private var replyButton: WebElement?

    init(request: EmailDraftRequest, client: OllamaClient, model: String, keepAlive: String, contextWindow: Int,
         speak: @escaping (String) async -> Void) {
        self.request = request
        self.client = client
        self.model = model
        self.keepAlive = keepAlive
        self.contextWindow = contextWindow
        self.speak = speak
    }

    func start(onFinish: @escaping @MainActor (DraftRunState) -> Void) {
        isActive = true
        task = Task {
            let final = await DraftRunDriver(request: request, gmailAccountIndex: ModelPreferences.gmailAccountIndex,
                                             userName: ModelPreferences.userDisplayName, world: self).run()
            isActive = false
            // The driver already put the app back; this does nothing twice.
            if let service = request.service { endPageAccess(service: service) }
            onFinish(final)
            try? await Task.sleep(nanoseconds: UInt64(Self.finalCardSeconds * 1_000_000_000))
            if !Task.isCancelled { panel.hide() }
        }
    }

    /// A talk press or the card's Stop: the driver reads this between steps.
    func interrupt() {
        // While it asks, a talk press starts the spoken answer, and Escape and No are the answer.
        guard isActive, !isAsking else { return }
        stopFlag = true
    }

    /// The card's Stop button. While it asks, stopping is saying no.
    private func stopPressed() {
        if isAsking { answer(.no) } else { interrupt() }
    }

    /// The answer to the append question: Yes, No, Return, Escape or a spoken yes or no.
    func answer(_ answer: ConsentAnswer) {
        guard isAsking, givenAnswer == nil else { return }
        givenAnswer = answer
    }

    /// Closes the card of a finished run at once, so a new run does not draw over it.
    func dismiss() {
        guard !isActive else { return }
        task?.cancel()
        panel.hide()
    }

    // MARK: - DraftRunWorld

    func show(_ state: DraftRunState, line: String) async {
        panel.show(state, line: line)
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: line,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        } else if DraftNarration.isSpoken(state, request: request) {
            // The user is already talking to Clicky after a talk press; speech now would reach the microphone.
            if state == .stopped { return }
            await speak(line)
        }
    }

    func say(_ line: String) async {
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: line,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        } else {
            await speak(line)
        }
    }

    func makeGenerator() -> DraftWriter.Generate {
        let client = client, model = model, keepAlive = keepAlive, contextWindow = contextWindow
        return { system, user in
            let result = try await client.streamChat(
                model: model, messages: [.system(system), .user(user)], temperature: 0.4, maxTokens: 600,
                keepAlive: keepAlive, contextWindow: contextWindow, onText: { _ in })
            return result.text
        }
    }

    func open(_ opening: ComposeTarget.Opening) async -> Bool {
        await BrowserActionExecutor.openInApp(url: opening.url, bundleIdentifier: opening.bundleIdentifier, activates: false)
    }

    func isStopRequested() -> Bool { stopFlag }

    func now() -> Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - Page features

    private struct Target {
        let bundleIdentifier: String
        let domain: String
    }

    private func target(_ service: EmailService) -> Target {
        Target(bundleIdentifier: service == .gmail ? ComposeTarget.chromeBundleIdentifier : ComposeTarget.fastmailBundleIdentifier,
               domain: LabelMap.preferredDomain(for: service))
    }

    private func pid(_ service: EmailService) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: target(service).bundleIdentifier).first?.processIdentifier
    }

    /// Tells the app an assistive client is reading, once per run. When the app is not running yet (a cold
    /// launch by the search link), the first look for the page does it.
    private func ensureAccess(_ service: EmailService) async {
        guard accessPid == nil, let pid = pid(service) else { return }
        accessPid = pid
        for attempt in await backend.beginWebContentAccess(pid: pid) {
            // TEMP debug logger (remove at project end)
            TempAppDebugLog.append("agent-ax", attempt.logFields)
        }
    }

    func beginPageAccess(service: EmailService) async { await ensureAccess(service) }

    func awaitPage(service: EmailService, seconds: Double) async -> PageGate.Result {
        let started = now()
        let domain = target(service).domain
        while true {
            await ensureAccess(service)
            if let pid = accessPid, let status = await backend.webAreaStatus(pid: pid, preferredDomain: domain),
               PageGate.isReadable(url: status.url, childCount: status.childCount, domain: domain) {
                return PageGate.Result(readable: true, milliseconds: Int((now() - started) * 1000))
            }
            if now() - started >= seconds || stopFlag { break }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return PageGate.Result(readable: false, milliseconds: Int((now() - started) * 1000))
    }

    func endPageAccess(service: EmailService) {
        guard let pid = accessPid else { return }
        accessPid = nil
        let mode = backend.webContentMode(pid: pid)
        let restore = backend.endWebContentAccess(pid: pid)
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("draft-end", ["axMode": mode.rawValue, "restored": restore.restored,
                                             "restoreAXError": restore.axError.map { Int($0) } ?? NSNull(),
                                             "readBackAfterRestore": restore.readBackAfterRestore ?? NSNull()])
    }

    func composeBodies(service: EmailService, seconds: Double) async -> [ComposeBodyRef] {
        guard let pid = accessPid else { return [] }
        let started = now()
        repeat {
            fields = await backend.composeFields(pid: pid, service: service, budget: 1.5)
            if !fields.isEmpty || stopFlag { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        } while now() - started < seconds
        return fields.enumerated().map { ComposeBodyRef(index: $0.offset, isEmpty: $0.element.isEmpty) }
    }

    func fillBody(_ body: ComposeBodyRef, text: String, appending: Bool, service: EmailService) async -> Bool {
        guard fields.indices.contains(body.index) else { return false }
        return await backend.setValue(text, in: fields[body.index], appending: appending)
    }

    func openMessage(from person: Recipient, service: EmailService, seconds: Double) async -> Bool {
        guard let pid = accessPid else { return false }
        let domain = target(service).domain
        let started = now()
        while now() - started < seconds, !stopFlag {
            rows = await backend.messageRows(pid: pid, preferredDomain: domain, budget: 2.0)
            if let row = rows.first(where: { LabelMap.rowMentions(person: person, texts: [$0.label]) }) {
                let before = await backend.pageURL(pid: pid, preferredDomain: domain)
                guard await backend.pressControl(row) != .noop else { return false }
                // The press is accepted without a result; the page address changing is the proof.
                let verifyStarted = now()
                while now() - verifyStarted < 3.0, !stopFlag {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let after = await backend.pageURL(pid: pid, preferredDomain: domain)
                    if let after, after != before { return true }
                }
                return false
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    func readThread(service: EmailService) async -> ThreadReading {
        guard let pid = accessPid else { return ThreadReading(items: [], hasReplyButton: false) }
        let page = await backend.readThread(pid: pid, preferredDomain: target(service).domain, budget: 3.0)
        replyButton = page.replyButton
        return ThreadReading(items: page.items, hasReplyButton: page.replyButton != nil)
    }

    func pressReply(service: EmailService) async -> Bool {
        guard let replyButton else { return false }
        return await backend.pressControl(replyButton) != .noop
    }

    func askToAppend() async -> Bool {
        let question = "the open draft already has text. add to it?"
        isAsking = true
        givenAnswer = nil
        panel.beginAsking(question)
        let keyboardAnswers = await panel.confirmKeyboardAnswers()
        print("🧭 draft consent panel key: \(keyboardAnswers)")
        await say(keyboardAnswers ? "\(question) press return for yes or escape for no." : question)
        let started = now()
        while givenAnswer == nil, now() - started < AgentCaps().consentTimeoutSeconds, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = givenAnswer == .yes
        isAsking = false
        panel.endAsking()
        return result
    }

    func finished(_ summary: DraftRunSummary) {
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("draft", summary.logFields)
    }
}
