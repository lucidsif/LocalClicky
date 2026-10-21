//
//  AccessibilityActions.swift
//  LocalClickyActions
//
//  The Accessibility implementation of ActionBackend: finds a browser
//  window's web area, reads its links and buttons, and presses one with
//  AXPress. AXPress is delivered to the element, so it works with the browser
//  in the background and the real cursor never moves.
//
//  Nothing here posts a key or mouse event, and press refuses any control SendGuard names (send,
//  discard, delete and the like).
//
//  Follows AccessibilityHarvester's idiom: every read runs off the main thread,
//  each element gets a short messaging timeout, a hard budget returns whatever
//  was read so far (the caller is resumed once), and nothing is ever read from
//  a secure text field. It never prompts for permission; without it every call
//  returns at once with nothing.
//
//  Chromium browsers (and Fastmail's Electron app) may not expose their web content until an
//  assistive client says it is there. beginWebContentAccess, called once per run before the page is
//  opened, gives the app element AXManualAccessibility first. Chrome 155 answers that with "attribute
//  unsupported", and then AXEnhancedUserInterface (what VoiceOver sets) is used instead, for the length
//  of one run only: its previous value is read first, and endWebContentAccess puts it back.
//  WebContentAccess (LocalBrainKit) holds those decisions. The read calls (pageState, walk) never
//  set anything, and keep the short per-element timeout.
//
//  What to keep, how to name it and which browsers need the nudge are decided
//  in LocalBrainKit (WebPageReading, AccessibilityTreeWalk).
//

import AppKit
import ApplicationServices
import LocalBrainKit

public struct AXBackend: ActionBackend {
    /// Per-element limit for a slow or hung page.
    static let perElementTimeoutSeconds: Float = 0.1
    /// Messaging timeout of the app element that gets the attribute sets: a busy browser can take longer
    /// than the per-element limit to answer an app-level set, and a timeout there looks like a failure.
    private static let accessSetTimeoutSeconds: Float = 2.0
    /// Upper bound of beginWebContentAccess: two manual tries, two enhanced tries and the gaps between.
    private static let beginBudgetSeconds = 12.0
    private static let beginMaxSteps = 8
    /// Budget for the single-element calls (page state, press, read back).
    private static let singleCallBudgetSeconds: Double = 1.0
    private static let accessSetBudgetSeconds: Double = 3.0
    static let windowSearchMaxNodes = 600
    static let windowSearchMaxDepth = 14
    private static let windowFallbackMaxWindows = 8
    private static let pageWalkMaxNodes = 5000
    private static let pageWalkMaxDepth = 40
    private static let secureRole = "AXSecureTextField"

    static let manualAccessibilityAttribute = "AXManualAccessibility"
    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private static let webContent = WebContentState()

    public init() {}

    // MARK: - ActionBackend

    public func pageState(pid: pid_t) async -> WebPageState? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(Self.singleCallBudgetSeconds)
        return await Self.withinBudget(Self.singleCallBudgetSeconds, onTimeout: { nil }) {
            guard let page = Self.webArea(pid: pid, deadline: deadline) else { return nil }
            return WebPageState(windowTitle: Self.string(page.window, kAXTitleAttribute),
                                pageURL: Self.string(page.area, kAXURLAttribute))
        }
    }

    public func walk(pid: pid_t, roles: Set<String>, budget: TimeInterval) async -> [WebElement] {
        guard AXIsProcessTrusted() else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        let collected = LockedList<WebElement>()
        return await Self.withinBudget(budget, onTimeout: { collected.snapshot() }) {
            guard let page = Self.webArea(pid: pid, deadline: deadline) else { return [] }
            // `visit` runs right before `children` for the same node, so a
            // secure field is marked in `visit` and then not descended into.
            var secureNode: AXUIElement?
            _ = AccessibilityTreeWalk.breadthFirst(
                roots: [page.area],
                maxNodes: Self.pageWalkMaxNodes,
                maxDepth: Self.pageWalkMaxDepth,
                children: { node in
                    if let secureNode, CFEqual(secureNode, node) { return [] }
                    return Self.elements(node, kAXChildrenAttribute)
                },
                shouldStop: { Date() >= deadline },
                visit: { node, _ in
                    AXUIElementSetMessagingTimeout(node, Self.perElementTimeoutSeconds)
                    guard let role = Self.string(node, kAXRoleAttribute) else { return false }
                    if Self.isSecure(node, role: role) { secureNode = node; return false }
                    if roles.contains(role) { collected.append(Self.webElement(node, role: role)) }
                    return false
                })
            return collected.snapshot()
        }
    }

    public func press(_ element: WebElement) async -> ActionEffect {
        guard AXIsProcessTrusted() else { return .noop }
        // The backstop: a control that sends or discards is never pressed, whoever asked (SendGuard).
        guard SendGuard.mayPress(label: element.label) else { return .noop }
        // A press that timed out may still have landed, so it is not a refusal.
        return await Self.withinBudget(Self.singleCallBudgetSeconds, onTimeout: { .unverifiable }) {
            AXUIElementSetMessagingTimeout(element.handle, Self.perElementTimeoutSeconds)
            return AXUIElementPerformAction(element.handle, kAXPressAction as CFString) == .success
                ? .unverifiable : .noop
        }
    }

    public func readBack(_ element: WebElement) async -> WebElement? {
        guard AXIsProcessTrusted() else { return nil }
        return await Self.withinBudget(Self.singleCallBudgetSeconds, onTimeout: { nil }) {
            AXUIElementSetMessagingTimeout(element.handle, Self.perElementTimeoutSeconds)
            // A failed role read means the element is gone.
            guard let role = Self.string(element.handle, kAXRoleAttribute),
                  !Self.isSecure(element.handle, role: role) else { return nil }
            return Self.webElement(element.handle, role: role)
        }
    }

    public func lastManualAccessibilityResult(pid: pid_t) -> Int32? {
        Self.webContent.lastManualResult(for: pid)
    }

    public func webContentMode(pid: pid_t) -> WebContentAccessMode {
        Self.webContent.mode(for: pid)
    }

    @discardableResult
    public func endWebContentAccess(pid: pid_t) -> WebContentRestoreReport {
        guard let previous = Self.webContent.finish(pid, voiceOverOn: NSWorkspace.shared.isVoiceOverEnabled) else {
            return WebContentRestoreReport(restored: false, axError: nil, readBackAfterRestore: nil)
        }
        // Its own app element with the same generous timeout as the set: a busy browser can take longer than
        // the per-element limit to answer an app-level write, and a spurious failure here would leave the
        // switch on.
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.accessSetTimeoutSeconds)
        let result = AXUIElementSetAttributeValue(application, Self.enhancedUserInterfaceAttribute as CFString,
                                                  previous ? kCFBooleanTrue : kCFBooleanFalse)
        let readBack = Self.readBackText(application, Self.enhancedUserInterfaceAttribute)
        print("🧭 AXEnhancedUserInterface restored to \(previous) on pid \(pid): AXError \(result.rawValue), read back \(readBack)")
        return WebContentRestoreReport(restored: result == .success, axError: result.rawValue, readBackAfterRestore: readBack)
    }

    public func beginWebContentAccess(pid: pid_t) async -> [WebContentSetAttempt] {
        guard AXIsProcessTrusted() else { return [] }
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard WebPageReading.needsAssistiveClientNudge(bundleIdentifier: bundleIdentifier) else { return [] }
        let attempts = LockedList<WebContentSetAttempt>()
        return await Self.withinBudget(Self.beginBudgetSeconds, onTimeout: { attempts.snapshot() }) {
            Self.setWebContentAccess(pid: pid, attempts: attempts)
            return attempts.snapshot()
        }
    }

    // MARK: - Mail pages (drafts)

    public func webAreaStatus(pid: pid_t, preferredDomain: String) async -> WebAreaStatus? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(Self.singleCallBudgetSeconds)
        return await Self.withinBudget(Self.singleCallBudgetSeconds, onTimeout: { nil }) {
            guard let page = Self.webArea(pid: pid, deadline: deadline, preferredDomain: preferredDomain) else { return nil }
            AXUIElementSetMessagingTimeout(page.area, Self.perElementTimeoutSeconds)
            return WebAreaStatus(url: Self.string(page.area, kAXURLAttribute),
                                 childCount: Self.elements(page.area, kAXChildrenAttribute).count)
        }
    }

    public func pageURL(pid: pid_t, preferredDomain: String) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(Self.singleCallBudgetSeconds)
        return await Self.withinBudget(Self.singleCallBudgetSeconds, onTimeout: { nil }) {
            Self.webArea(pid: pid, deadline: deadline, preferredDomain: preferredDomain)
                .flatMap { Self.string($0.area, kAXURLAttribute) }
        }
    }

    public func composeFields(pid: pid_t, service: EmailService, budget: TimeInterval) async -> [ComposeField] {
        guard AXIsProcessTrusted() else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        let found = LockedList<ComposeField>()
        return await Self.withinBudget(budget, onTimeout: { found.snapshot() }) {
            guard let page = Self.webArea(pid: pid, deadline: deadline, preferredDomain: LabelMap.preferredDomain(for: service)) else { return [] }
            _ = AccessibilityTreeWalk.breadthFirst(
                roots: [page.area], maxNodes: Self.pageWalkMaxNodes, maxDepth: Self.pageWalkMaxDepth,
                children: { Self.elements($0, kAXChildrenAttribute) },
                shouldStop: { Date() >= deadline },
                visit: { node, _ in
                    AXUIElementSetMessagingTimeout(node, Self.perElementTimeoutSeconds)
                    let role = Self.string(node, kAXRoleAttribute)
                    guard LabelMap.isComposeBody(role: role, description: Self.string(node, kAXDescriptionAttribute), service: service),
                          !Self.isSecure(node, role: role ?? "") else { return false }
                    var settable: DarwinBoolean = false
                    guard AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable) == .success,
                          settable.boolValue else { return false }
                    found.append(ComposeField(isEmpty: (Self.rawText(node, kAXValueAttribute) ?? "").isEmpty, handle: node))
                    return false
                })
            return found.snapshot()
        }
    }

    public func setValue(_ text: String, in field: ComposeField, appending: Bool) async -> Bool {
        guard AXIsProcessTrusted(), !text.isEmpty else { return false }
        return await Self.withinBudget(Self.accessSetBudgetSeconds, onTimeout: { false }) {
            AXUIElementSetMessagingTimeout(field.handle, Self.accessSetTimeoutSeconds)
            var combined = text
            if appending {
                guard let old = Self.rawText(field.handle, kAXValueAttribute) else { return false }
                combined = old.isEmpty ? text : old + "\n\n" + text
            }
            // The only write a draft makes to a page: the body's value. No focus, no raise, no event.
            guard AXUIElementSetAttributeValue(field.handle, kAXValueAttribute as CFString, combined as CFString) == .success,
                  let after = Self.rawText(field.handle, kAXValueAttribute) else { return false }
            return after.trimmingCharacters(in: .whitespacesAndNewlines) == combined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func messageRows(pid: pid_t, preferredDomain: String, budget: TimeInterval) async -> [WebElement] {
        guard AXIsProcessTrusted() else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        let collected = LockedList<WebElement>()
        return await Self.withinBudget(budget, onTimeout: { collected.snapshot() }) {
            guard let page = Self.webArea(pid: pid, deadline: deadline, preferredDomain: preferredDomain) else { return [] }
            _ = AccessibilityTreeWalk.breadthFirst(
                roots: [page.area], maxNodes: Self.pageWalkMaxNodes, maxDepth: Self.pageWalkMaxDepth,
                children: { Self.elements($0, kAXChildrenAttribute) },
                shouldStop: { Date() >= deadline },
                visit: { node, _ in
                    AXUIElementSetMessagingTimeout(node, Self.perElementTimeoutSeconds)
                    guard let role = Self.string(node, kAXRoleAttribute), LabelMap.isThreadRow(role: role) else { return false }
                    collected.append(Self.draftElement(node, role: role))
                    return false
                })
            return collected.snapshot()
        }
    }

    public func readThread(pid: pid_t, preferredDomain: String, budget: TimeInterval) async -> ThreadPage {
        guard AXIsProcessTrusted() else { return ThreadPage(items: [], replyButton: nil) }
        let deadline = Date().addingTimeInterval(budget)
        let items = LockedList<PageItem>()
        let reply = LockedList<WebElement>()
        return await Self.withinBudget(budget, onTimeout: { ThreadPage(items: items.snapshot(), replyButton: reply.snapshot().last) }) {
            guard let page = Self.webArea(pid: pid, deadline: deadline, preferredDomain: preferredDomain) else {
                return ThreadPage(items: [], replyButton: nil)
            }
            // Document order: a stack, with each node's children pushed in reverse.
            var stack: [(node: AXUIElement, depth: Int)] = [(page.area, 0)]
            var visited = 0
            while let (node, depth) = stack.popLast(), visited < Self.pageWalkMaxNodes, depth <= Self.pageWalkMaxDepth, Date() < deadline {
                visited += 1
                AXUIElementSetMessagingTimeout(node, Self.perElementTimeoutSeconds)
                let role = Self.string(node, kAXRoleAttribute) ?? ""
                if Self.isSecure(node, role: role) { continue }
                if role == LabelMap.staticTextRole {
                    if let text = Self.string(node, kAXValueAttribute), !text.isEmpty { items.append(.text(String(text.prefix(400)))) }
                    continue
                }
                if role == LabelMap.buttonRole {
                    let element = Self.draftElement(node, role: role)
                    items.append(.button(element.label))
                    if LabelMap.isReplyButton(role: role, label: element.label) { reply.append(element) }
                    continue
                }
                for child in Self.elements(node, kAXChildrenAttribute).reversed() { stack.append((child, depth + 1)) }
            }
            return ThreadPage(items: items.snapshot(), replyButton: reply.snapshot().last)
        }
    }

    public func pressControl(_ element: WebElement) async -> ActionEffect {
        guard LabelMap.mayPressInDraft(role: element.role) else { return .noop }
        return await press(element)
    }

    /// A row or button of a mail page: named by its title or description, else by its static texts (a row's
    /// are gathered a few levels down, since a mail row keeps the sender in a nested cell).
    private static func draftElement(_ node: AXUIElement, role: String) -> WebElement {
        let label = WebPageReading.label(
            title: string(node, kAXTitleAttribute), description: string(node, kAXDescriptionAttribute),
            childTexts: nestedTexts(of: node, maxDepth: role == LabelMap.threadRowRole ? 4 : 1))
        return WebElement(role: role, label: label, url: nil, frame: frame(of: node), handle: node)
    }

    private static func nestedTexts(of root: AXUIElement, maxDepth: Int) -> [String] {
        var texts: [String] = []
        var frontier = [root]
        for _ in 0..<maxDepth {
            var next: [AXUIElement] = []
            for node in frontier {
                for child in elements(node, kAXChildrenAttribute) {
                    AXUIElementSetMessagingTimeout(child, perElementTimeoutSeconds)
                    if string(child, kAXRoleAttribute) == LabelMap.staticTextRole {
                        if let text = string(child, kAXValueAttribute) { texts.append(text) }
                    } else {
                        next.append(child)
                    }
                    if texts.count >= 10 { return texts }
                }
            }
            frontier = next
        }
        return texts
    }

    /// A string attribute exactly as stored (an empty string stays empty; a missing or unreadable value is nil
    /// except for AXNoValue, which reads as empty).
    private static func rawText(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        if read == .noValue { return "" }
        guard read == .success else { return nil }
        return raw as? String
    }

    // MARK: - Finding the page

    /// Tells the app an assistive client is reading, so it exposes its web content. What to call, and
    /// when to retry, is WebContentAccess's decision: AXManualAccessibility first, and when the app says
    /// it is unsupported (or fails twice), AXEnhancedUserInterface for the rest of the run (restored by
    /// endWebContentAccess). Runs on the app element with `accessSetTimeoutSeconds`, waiting out the retry
    /// gap itself, so the caller makes one call per run. Every attempt is printed and recorded, so a real
    /// run shows what the app answered.
    private static func setWebContentAccess(pid: pid_t, attempts: LockedList<WebContentSetAttempt>) {
        let running = NSRunningApplication(processIdentifier: pid)
        let bundleIdentifier = running?.bundleIdentifier
        let version = running?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, accessSetTimeoutSeconds)
        let name = bundleIdentifier ?? "?"

        func record(_ attribute: String, code: Int32, at uptime: Double) {
            var listed = false
            var names: CFArray?
            if AXUIElementCopyAttributeNames(application, &names) == .success, let names = names as? [String] {
                listed = names.contains(attribute)
            }
            var settableFlag: DarwinBoolean = false
            let settable = AXUIElementIsAttributeSettable(application, attribute as CFString, &settableFlag) == .success
                ? settableFlag.boolValue : nil
            attempts.append(WebContentSetAttempt(
                attribute: attribute, axError: code, uptimeMs: Int(uptime * 1000),
                timeoutSeconds: Double(accessSetTimeoutSeconds), readBack: readBackText(application, attribute),
                voiceOverOn: NSWorkspace.shared.isVoiceOverEnabled, appBundleId: bundleIdentifier, appVersion: version,
                attributeListed: listed, settable: settable))
        }

        for _ in 0..<beginMaxSteps {
            let now = ProcessInfo.processInfo.systemUptime
            guard let action = webContent.nextAction(for: pid, now: now) else {
                if webContent.isSettled(for: pid) { return }
                // Too soon after the last try: wait out the gap.
                Thread.sleep(forTimeInterval: 0.55)
                continue
            }
            switch action {
            case .setManual:
                let result = AXUIElementSetAttributeValue(application, manualAccessibilityAttribute as CFString, kCFBooleanTrue)
                webContent.recordManual(code: result.rawValue, for: pid)
                record(manualAccessibilityAttribute, code: result.rawValue, at: now)
                print("🧭 AXManualAccessibility set on \(name) pid \(pid): AXError \(result.rawValue)")
            case .setEnhanced(let readPreviousFirst):
                if readPreviousFirst {
                    var raw: CFTypeRef?
                    let read = AXUIElementCopyAttributeValue(application, enhancedUserInterfaceAttribute as CFString, &raw)
                    let previous = read == .success ? (raw as? NSNumber)?.boolValue : nil
                    webContent.recordPrevious(previous, voiceOverOn: NSWorkspace.shared.isVoiceOverEnabled, for: pid)
                    print("🧭 AXEnhancedUserInterface read on \(name) pid \(pid): AXError \(read.rawValue), value \(previous.map(String.init) ?? "unreadable")")
                }
                let result = AXUIElementSetAttributeValue(application, enhancedUserInterfaceAttribute as CFString, kCFBooleanTrue)
                webContent.recordEnhanced(code: result.rawValue, for: pid)
                record(enhancedUserInterfaceAttribute, code: result.rawValue, at: now)
                print("🧭 AXEnhancedUserInterface set on \(name) pid \(pid): AXError \(result.rawValue)")
            }
        }
    }

    /// An attribute's value as text for the log: "1" or "0" for a boolean, "error <code>" when it could not be read.
    static func readBackText(_ element: AXUIElement, _ attribute: String) -> String {
        var raw: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard read == .success, let raw else { return "error \(read.rawValue)" }
        if let number = raw as? NSNumber { return number.stringValue }
        return String(describing: raw)
    }

    /// The web area to read: the one in the focused (else main) window when it has an http(s)
    /// address. Otherwise the first of the app's other windows (at most `windowFallbackMaxWindows`)
    /// with one, a youtube.com page first, because the page a background open created may not be
    /// in the focused window. Failing both, the front window's first web area, however addressed.
    private static func webArea(pid: pid_t, deadline: Date, preferredDomain: String = "youtube.com") -> (window: AXUIElement, area: AXUIElement)? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, perElementTimeoutSeconds)
        let frontWindow = element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute)
        let front = frontWindow.flatMap { window in
            webArea(in: window, deadline: deadline).map { (window: window, found: $0) }
        }
        if let front, WebPageReading.isWebURL(front.found.url) { return (front.window, front.found.area) }

        var candidates: [(window: AXUIElement, found: (area: AXUIElement, url: String?))] = []
        for window in elements(application, kAXWindowsAttribute).prefix(windowFallbackMaxWindows) {
            if let frontWindow, CFEqual(frontWindow, window) { continue }
            if Date() >= deadline { break }
            if let found = webArea(in: window, deadline: deadline) { candidates.append((window, found)) }
        }
        if let index = WebPageReading.preferredWindowIndex(candidates.enumerated().map { ($0.offset, $0.element.found.url) },
                                                           preferredDomain: preferredDomain) {
            return (candidates[index].window, candidates[index].found.area)
        }
        return front.map { ($0.window, $0.found.area) }
    }

    /// The first web area with an http(s) address in `window`, else the first one found.
    private static func webArea(in window: AXUIElement, deadline: Date) -> (area: AXUIElement, url: String?)? {
        AXUIElementSetMessagingTimeout(window, perElementTimeoutSeconds)
        var firstArea: AXUIElement?
        var webAddressedArea: AXUIElement?
        _ = AccessibilityTreeWalk.breadthFirst(
            roots: [window],
            maxNodes: windowSearchMaxNodes,
            maxDepth: windowSearchMaxDepth,
            children: { elements($0, kAXChildrenAttribute) },
            shouldStop: { Date() >= deadline },
            visit: { node, _ in
                AXUIElementSetMessagingTimeout(node, perElementTimeoutSeconds)
                guard string(node, kAXRoleAttribute) == "AXWebArea" else { return false }
                if firstArea == nil { firstArea = node }
                if WebPageReading.isWebURL(string(node, kAXURLAttribute)) { webAddressedArea = node }
                return webAddressedArea != nil
            })
        guard let area = webAddressedArea ?? firstArea else { return nil }
        return (area, string(area, kAXURLAttribute))
    }

    // MARK: - Reading one element

    private static func webElement(_ node: AXUIElement, role: String) -> WebElement {
        let label = WebPageReading.label(
            title: string(node, kAXTitleAttribute),
            description: string(node, kAXDescriptionAttribute),
            childTexts: role == "AXLink" ? staticTexts(of: node) : [])
        var url = string(node, kAXURLAttribute)
        if role == "AXLink", url == nil {
            url = AccessibilityLinkResolver.resolve(
                from: node,
                parent: { current in
                    AXUIElementSetMessagingTimeout(current, perElementTimeoutSeconds)
                    return element(current, kAXParentAttribute)
                },
                url: { string($0, kAXURLAttribute) },
                label: { _ in nil }).url
        }
        return WebElement(role: role, label: label, url: url, frame: frame(of: node), handle: node)
    }

    /// The values of a link's direct static text children, which is where
    /// Chromium puts the words of a link that has no title.
    private static func staticTexts(of node: AXUIElement) -> [String] {
        elements(node, kAXChildrenAttribute)
            .filter { child in
                AXUIElementSetMessagingTimeout(child, perElementTimeoutSeconds)
                return string(child, kAXRoleAttribute) == "AXStaticText"
            }
            .prefix(WebPageReading.maxLabelTextParts)
            .compactMap { string($0, kAXValueAttribute) }
    }

    private static func isSecure(_ node: AXUIElement, role: String) -> Bool {
        role == secureRole || string(node, kAXSubroleAttribute) == secureRole
    }

    // MARK: - Plumbing

    /// Runs `work` off the main thread and returns its result, or `onTimeout`'s
    /// when `budget` seconds pass first, whichever comes first. `work` keeps
    /// running after a timeout but its result is dropped.
    static func withinBudget<Value: Sendable>(_ budget: TimeInterval,
                                                      onTimeout: @escaping @Sendable () -> Value,
                                                      _ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation: continuation)
            DispatchQueue.global(qos: .userInitiated).async { gate.finish(work()) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budget) { gate.finish(onTimeout()) }
        }
    }

    private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        init(continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
        func finish(_ value: Value) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Elements gathered so far, readable from the waiting side at any moment.
    final class LockedList<Item: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Item] = []
        func append(_ item: Item) { lock.lock(); defer { lock.unlock() }; items.append(item) }
        func snapshot() -> [Item] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// The access decisions (WebContentAccess) and the last AXManualAccessibility error per pid, behind one lock.
    private final class WebContentState: @unchecked Sendable {
        private let lock = NSLock()
        private var access = WebContentAccess<pid_t>()
        private var lastManualResults: [pid_t: Int32] = [:]
        func nextAction(for pid: pid_t, now: Double) -> WebContentAccess<pid_t>.Action? {
            lock.lock(); defer { lock.unlock() }
            return access.nextAction(for: pid, now: now)
        }
        func recordManual(code: Int32, for pid: pid_t) {
            lock.lock(); defer { lock.unlock() }
            lastManualResults[pid] = code
            access.recordManual(code: code, for: pid)
        }
        func recordPrevious(_ value: Bool?, voiceOverOn: Bool, for pid: pid_t) {
            lock.lock(); defer { lock.unlock() }
            access.recordPrevious(value, voiceOverOn: voiceOverOn, for: pid)
        }
        func recordEnhanced(code: Int32, for pid: pid_t) {
            lock.lock(); defer { lock.unlock() }
            access.recordEnhanced(code: code, for: pid)
        }
        func mode(for pid: pid_t) -> WebContentAccessMode {
            lock.lock(); defer { lock.unlock() }
            return access.mode(for: pid)
        }
        func isSettled(for pid: pid_t) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return access.isSettled(for: pid)
        }
        func finish(_ pid: pid_t, voiceOverOn: Bool) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            lastManualResults[pid] = nil
            return access.finish(pid, voiceOverOn: voiceOverOn)
        }
        func lastManualResult(for pid: pid_t) -> Int32? {
            lock.lock(); defer { lock.unlock() }
            return lastManualResults[pid]
        }
    }

    // These four read helpers are copied from AccessibilityHarvester on purpose:
    // moving the harvester here would be churn with no behaviour change.

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let list = raw as? [AXUIElement] else { return [] }
        return list
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else { return nil }
        if let text = raw as? String { return text }
        if CFGetTypeID(raw) == CFURLGetTypeID() { return (raw as! URL).absoluteString }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// AXPosition and AXSize are already in Core Graphics top-left coordinates.
    static func frame(of element: AXUIElement) -> CGRect {
        var positionRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
              let positionRaw, let sizeRaw,
              CFGetTypeID(positionRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID(),
              AXValueGetValue(positionRaw as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { return .zero }
        return CGRect(origin: position, size: size)
    }
}
