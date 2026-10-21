//
//  AccessibilityProbe.swift
//  LocalClickyActions
//
//  TEMP page probe (remove at project end). The Accessibility reads that decide whether a Chromium
//  or Electron app's web page can be read in the background: a bounded look at the front window's
//  tree (AXBackend.walkTelemetry), the list of an app's window titles, and the Gmail compose probe.
//  Every call here is a read except the compose probe's single AXValue set on an empty compose body.
//  Nothing is pressed, focused or raised, and no key or mouse event is posted.
//
//  What each label is matched against (the address bar's wording, "Message Body") is decided in
//  LocalBrainKit (PageProbeMatcher); those names are guesses until the probe shows the real ones.
//

import AppKit
import ApplicationServices
import LocalBrainKit

extension AXBackend {
    public func walkTelemetry(pid: pid_t, budget: TimeInterval) async -> WalkTelemetry? {
        guard AXIsProcessTrusted() else { return nil }
        return await Self.withinBudget(budget + 0.5, onTimeout: { nil }) {
            Self.telemetryWalk(pid: pid, budget: budget)
        }
    }

    private static func telemetryWalk(pid: pid_t, budget: TimeInterval) -> WalkTelemetry? {
        let started = Date()
        let deadline = started.addingTimeInterval(budget)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, perElementTimeoutSeconds)
        let windows = elements(application, kAXWindowsAttribute)
        let front = element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute) ?? windows.first
        guard let window = front else { return nil }
        AXUIElementSetMessagingTimeout(window, perElementTimeoutSeconds)

        let lookForOmnibox = WebPageReading.isChromiumBrowser(
            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        var firstArea: AXUIElement?
        var webAddressedArea: AXUIElement?
        var omnibox: String?
        var deepest = 0
        var hitDepthLimit = false
        let walk = AccessibilityTreeWalk.breadthFirst(
            roots: [window],
            maxNodes: windowSearchMaxNodes,
            maxDepth: windowSearchMaxDepth,
            children: { elements($0, kAXChildrenAttribute) },
            shouldStop: { Date() >= deadline },
            visit: { node, depth in
                AXUIElementSetMessagingTimeout(node, perElementTimeoutSeconds)
                deepest = max(deepest, depth)
                let role = string(node, kAXRoleAttribute)
                if depth == windowSearchMaxDepth, !elements(node, kAXChildrenAttribute).isEmpty { hitDepthLimit = true }
                if role == "AXWebArea" {
                    if firstArea == nil { firstArea = node }
                    if webAddressedArea == nil, WebPageReading.isWebURL(string(node, kAXURLAttribute)) { webAddressedArea = node }
                } else if lookForOmnibox, omnibox == nil,
                          PageProbeMatcher.isAddressBar(role: role, title: string(node, kAXTitleAttribute),
                                                        description: string(node, kAXDescriptionAttribute)) {
                    omnibox = string(node, kAXValueAttribute)
                }
                return webAddressedArea != nil && (!lookForOmnibox || omnibox != nil)
            })

        let area = webAddressedArea ?? firstArea
        let (onScreen, bounds) = onScreenBounds(of: window, pid: pid)
        return WalkTelemetry(
            windowIndex: windows.firstIndex { CFEqual($0, window) },
            windowTitle: string(window, kAXTitleAttribute),
            nodesVisited: walk.visited,
            maxDepth: deepest,
            stopReason: WalkStopReason.decide(foundWebArea: area != nil, stoppedEarly: walk.stoppedEarly,
                                              deadlinePassed: Date() >= deadline, hitDepthLimit: hitDepthLimit),
            elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
            webAreaFound: area != nil,
            webAreaURL: area.flatMap { string($0, kAXURLAttribute) },
            webAreaChildCount: area.map { elements($0, kAXChildrenAttribute).count },
            windowOnScreen: onScreen,
            windowBounds: bounds,
            omnibox: omnibox)
    }

    /// Whether CGWindowList lists a window of `pid` on screen with the Accessibility window's frame, and its bounds.
    private static func onScreenBounds(of window: AXUIElement, pid: pid_t) -> (Bool, [Double]?) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let bounds: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dictionary)
        }
        guard let match = WindowBoundsMatcher.onScreenBounds(matching: frame(of: window), among: bounds) else { return (false, nil) }
        let values: [Double] = [Double(match.minX), Double(match.minY), Double(match.width), Double(match.height)]
        return (true, values.map { ($0 * 10).rounded() / 10 })
    }
}

/// What the compose probe found. Values from the page are not included, except the "Saved" text.
public struct ComposeProbeReport: Sendable {
    public var composeBodyFound = false
    public var settable: Bool?
    /// True when the body read as empty (or had no value), false when it held text, nil when unreadable.
    public var wasEmpty: Bool?
    public var setCode: Int32?
    public var readBack: String?
    public var savedTextFound: Bool?
    /// The text of the "Saved" static text, only when it is short.
    public var savedText: String?
    /// JSON lines (depth, role, description, title) of the compose region, for the probe-compose-tree file.
    public var treeLines: [String] = []
    public var notes: [String] = []
}

public enum AXPageProbe {
    private static let treeMaxNodes = 300
    private static let climbMaxLevels = 10
    private static let savedWaitSeconds = 3.0
    private static let compositeBudgetSeconds = 15.0

    /// The titles of an app's windows, in the app's order. Native windows need no web reading.
    public static func windowTitles(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        return AXBackend.elements(application, kAXWindowsAttribute).map { window in
            AXUIElementSetMessagingTimeout(window, 0.5)
            return AXBackend.string(window, kAXTitleAttribute) ?? ""
        }
    }

    /// Finds the compose body in the app's front window and, when it is settable and empty, writes the
    /// probe marker into it and looks for Gmail's "Saved" text 3 seconds later. Never presses anything.
    public static func composeProbe(pid: pid_t) async -> ComposeProbeReport {
        guard AXIsProcessTrusted() else { return ComposeProbeReport(notes: ["accessibility not trusted"]) }
        return await AXBackend.withinBudget(compositeBudgetSeconds, onTimeout: { ComposeProbeReport(notes: ["probe timed out"]) }) {
            runCompose(pid: pid)
        }
    }

    private static func runCompose(pid: pid_t) -> ComposeProbeReport {
        var report = ComposeProbeReport()
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, AXBackend.perElementTimeoutSeconds)
        guard let window = AXBackend.element(application, kAXFocusedWindowAttribute)
            ?? AXBackend.element(application, kAXMainWindowAttribute) else {
            report.notes.append("no front window")
            return report
        }
        let deadline = Date().addingTimeInterval(4)
        var body: AXUIElement?
        _ = AccessibilityTreeWalk.breadthFirst(
            roots: [window], maxNodes: 5000, maxDepth: 40,
            children: { AXBackend.elements($0, kAXChildrenAttribute) },
            shouldStop: { Date() >= deadline },
            visit: { node, _ in
                AXUIElementSetMessagingTimeout(node, AXBackend.perElementTimeoutSeconds)
                if PageProbeMatcher.isComposeBody(role: AXBackend.string(node, kAXRoleAttribute),
                                                  description: AXBackend.string(node, kAXDescriptionAttribute)) { body = node }
                return body != nil
            })
        guard let body else {
            report.notes.append("no compose body found in the front window")
            return report
        }
        report.composeBodyFound = true
        report.treeLines = composeRegion(around: body)

        var settableFlag: DarwinBoolean = false
        report.settable = AXUIElementIsAttributeSettable(body, kAXValueAttribute as CFString, &settableFlag) == .success
            ? settableFlag.boolValue : nil
        var raw: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(body, kAXValueAttribute as CFString, &raw)
        if read == .success { report.wasEmpty = ((raw as? String) ?? "").isEmpty }
        else if read == .noValue { report.wasEmpty = true }
        guard report.settable == true, report.wasEmpty == true else {
            report.notes.append("not written: settable \(report.settable.map(String.init) ?? "unknown"), empty \(report.wasEmpty.map(String.init) ?? "unknown")")
            return report
        }

        AXUIElementSetMessagingTimeout(body, 2.0)
        let set = AXUIElementSetAttributeValue(body, kAXValueAttribute as CFString, ProbeSamples.composeMarker as CFString)
        report.setCode = set.rawValue
        var after: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(body, kAXValueAttribute as CFString, &after)
        report.readBack = (after as? String).map { $0 == ProbeSamples.composeMarker ? "marker" : "other (\($0.count) characters)" }
            ?? "unreadable"

        Thread.sleep(forTimeInterval: savedWaitSeconds)
        let savedDeadline = Date().addingTimeInterval(3)
        var saved: String?
        _ = AccessibilityTreeWalk.breadthFirst(
            roots: [window], maxNodes: 5000, maxDepth: 40,
            children: { AXBackend.elements($0, kAXChildrenAttribute) },
            shouldStop: { Date() >= savedDeadline },
            visit: { node, _ in
                AXUIElementSetMessagingTimeout(node, AXBackend.perElementTimeoutSeconds)
                guard AXBackend.string(node, kAXRoleAttribute) == "AXStaticText",
                      let text = AXBackend.string(node, kAXValueAttribute), text.count <= 40,
                      PageProbeMatcher.isSavedIndicator(text) else { return false }
                saved = text
                return true
            })
        report.savedTextFound = saved != nil
        report.savedText = saved
        return report
    }

    /// Roles, descriptions and titles (never values) of up to 300 nodes of the compose region: the
    /// lowest ancestor of the body, at most 10 levels up and below the web area, whose subtree holds a
    /// control whose label starts with "send"; else the highest such ancestor. That is where the real
    /// Send button label shows up.
    private static func composeRegion(around body: AXUIElement) -> [String] {
        var best: [String] = []
        var current = body
        for _ in 0..<climbMaxLevels {
            guard let parent = AXBackend.element(current, kAXParentAttribute),
                  AXBackend.string(parent, kAXRoleAttribute) != "AXWebArea",
                  AXBackend.string(parent, kAXRoleAttribute) != "AXWindow" else { break }
            current = parent
            best = describe(subtree: current)
            if best.contains(where: { $0.lowercased().contains("\"description\":\"send") || $0.lowercased().contains("\"title\":\"send") }) {
                return best
            }
        }
        return best.isEmpty ? describe(subtree: body) : best
    }

    private static func describe(subtree root: AXUIElement) -> [String] {
        var lines: [String] = []
        _ = AccessibilityTreeWalk.breadthFirst(
            roots: [root], maxNodes: treeMaxNodes, maxDepth: 30,
            children: { AXBackend.elements($0, kAXChildrenAttribute) },
            shouldStop: { false },
            visit: { node, depth in
                AXUIElementSetMessagingTimeout(node, AXBackend.perElementTimeoutSeconds)
                let role = AXBackend.string(node, kAXRoleAttribute) ?? ""
                guard role != "AXSecureTextField" else { return false }
                let fields: [String: Any] = ["depth": depth, "role": role,
                                             "description": AXBackend.string(node, kAXDescriptionAttribute) ?? "",
                                             "title": AXBackend.string(node, kAXTitleAttribute) ?? ""]
                if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                   let line = String(data: data, encoding: .utf8) { lines.append(line) }
                return false
            })
        return lines
    }
}
