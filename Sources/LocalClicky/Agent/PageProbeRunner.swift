//
//  PageProbeRunner.swift
//  LocalClicky
//
//  TEMP page probe (remove at project end). Answers, in one run and without voice, whether the web
//  page of Chrome or Fastmail can be read through Accessibility, and a few things the draft features
//  need to know about Gmail's compose window and Fastmail's mailto.
//
//  While ~/.clicky-gateway/debug.on exists, a 2 second timer looks for ~/.clicky-gateway/probe.request.
//  When it is there, its first word is read, the file is deleted and that probe runs:
//    chrome    make Chrome readable, walk its front window for 10 s, log, put the switch back. No page is opened.
//    fastmail  the same on Fastmail.app (AXManualAccessibility).
//    mailto    open a safe mailto in Fastmail.app without activating it; log the frontmost app and
//              Fastmail's window titles before and 2 s after.
//    compose   find Gmail's "Message Body" in Chrome's front window; if it is settable and empty,
//              write a marker, read it back, and look 3 s later for Gmail's "Saved" text. Also writes
//              the roles and descriptions of the compose region to probe-compose-tree.jsonl.
//  The result is ~/.clicky-gateway/probe-result.json; the agent-ax, agent-walk and agent-end events go
//  to the TEMP debug log. A probe never presses, focuses or raises anything, never posts a key or a
//  mouse event, and never sends mail. Remove the call sites marked "TEMP debug logger" with this file.
//

import AppKit
import LocalBrainKit
import LocalClickyActions

@MainActor
final class PageProbeRunner {
    private static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky-gateway")
    private static let requestPath = directory.appendingPathComponent("probe.request").path
    private static let resultURL = directory.appendingPathComponent("probe-result.json")
    private static let composeTreeURL = directory.appendingPathComponent("probe-compose-tree.jsonl")
    private static let chromeBundleIdentifier = "com.google.Chrome"
    private static let pollSeconds = 2.0
    private static let walkSeconds = 10.0
    private static let walkGapSeconds = 0.5
    private static let walkBudgetSeconds = 1.0
    private static let mailtoSettleSeconds = 2.0

    private let backend = ActionBackends.current()
    private var timer: Timer?
    private var isRunning = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForRequest() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkForRequest() {
        guard !isRunning, TempAppDebugLog.isOn, FileManager.default.fileExists(atPath: Self.requestPath) else { return }
        let contents = (try? String(contentsOfFile: Self.requestPath, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: Self.requestPath)
        isRunning = true
        Task {
            await run(requestContents: contents)
            isRunning = false
        }
    }

    // MARK: - Probes

    private func run(requestContents: String) async {
        guard let word = ProbeWord(requestContents: requestContents) else {
            write(ProbeResult(word: "unknown", ts: Self.timestamp(),
                              notes: ["the first word of probe.request must be chrome, fastmail, mailto or compose"]))
            return
        }
        var result = ProbeResult(word: word.rawValue, ts: Self.timestamp())
        switch word {
        case .chrome: await probeWalk(bundleIdentifier: Self.chromeBundleIdentifier, into: &result)
        case .fastmail: await probeWalk(bundleIdentifier: WebPageReading.fastmailBundleIdentifier, into: &result)
        case .mailto: await probeMailto(into: &result)
        case .compose: await probeCompose(into: &result)
        }
        write(result)
    }

    /// `chrome` and `fastmail`: begin access, walk the front window for 10 s, end access.
    private func probeWalk(bundleIdentifier: String, into result: inout ProbeResult) async {
        guard let pid = Self.processIdentifier(bundleIdentifier) else {
            result.notes.append("\(bundleIdentifier) is not running")
            return
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        await beginAccess(pid: pid, into: &result)
        var budget = WalkTelemetryBudget(startedAt: startedAt)
        while ProcessInfo.processInfo.systemUptime - startedAt < Self.walkSeconds {
            let now = ProcessInfo.processInfo.systemUptime
            if let telemetry = await backend.walkTelemetry(pid: pid, budget: Self.walkBudgetSeconds) {
                if budget.shouldLog(now: now) {
                    // TEMP debug logger (remove at project end)
                    TempAppDebugLog.append("agent-walk", telemetry.logFields)
                }
                note(telemetry, at: now - startedAt, into: &result)
            } else if !result.notes.contains("no front window or Accessibility is not trusted") {
                result.notes.append("no front window or Accessibility is not trusted")
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.walkGapSeconds * 1_000_000_000))
        }
        endAccess(pid: pid, word: result.word, into: &result)
    }

    /// `mailto`: open the sample mailto in Fastmail without activating it, and see what moved.
    private func probeMailto(into result: inout ProbeResult) async {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WebPageReading.fastmailBundleIdentifier),
              let mailto = URL(string: ProbeSamples.mailtoURL) else {
            result.notes.append("Fastmail.app is not installed")
            return
        }
        let pidBefore = Self.processIdentifier(WebPageReading.fastmailBundleIdentifier)
        let titlesBefore = pidBefore.map { AXPageProbe.windowTitles(pid: $0) } ?? []
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        var openError: String?
        do {
            _ = try await NSWorkspace.shared.open([mailto], withApplicationAt: appURL, configuration: configuration)
        } catch {
            openError = String(describing: error)
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.mailtoSettleSeconds * 1_000_000_000))
        let pidAfter = Self.processIdentifier(WebPageReading.fastmailBundleIdentifier)
        let titlesAfter = pidAfter.map { AXPageProbe.windowTitles(pid: $0) } ?? []
        let frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("probe-mailto", [
            "frontmostBefore": frontBefore ?? NSNull(), "frontmostAfter": frontAfter ?? NSNull(),
            "fastmailRunningBefore": pidBefore != nil, "windowCountBefore": titlesBefore.count,
            "windowCountAfter": titlesAfter.count, "windowTitlesBefore": titlesBefore, "windowTitlesAfter": titlesAfter,
            "openError": openError ?? NSNull(),
        ])
        result.notes.append("frontmost before \(frontBefore ?? "none"), after \(frontAfter ?? "none")")
        result.notes.append("fastmail windows \(titlesBefore.count) before, \(titlesAfter.count) after")
        if let openError { result.notes.append("open failed: \(openError)") }
    }

    /// `compose`: write the marker into an empty Gmail compose body and see whether Gmail saves a draft.
    private func probeCompose(into result: inout ProbeResult) async {
        guard let pid = Self.processIdentifier(Self.chromeBundleIdentifier) else {
            result.notes.append("Chrome is not running")
            return
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        await beginAccess(pid: pid, into: &result)
        if let telemetry = await backend.walkTelemetry(pid: pid, budget: Self.walkBudgetSeconds) {
            // TEMP debug logger (remove at project end)
            TempAppDebugLog.append("agent-walk", telemetry.logFields)
            note(telemetry, at: ProcessInfo.processInfo.systemUptime - startedAt, into: &result)
        }
        let report = await AXPageProbe.composeProbe(pid: pid)
        if !report.treeLines.isEmpty { writeComposeTree(report.treeLines) }
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("probe-compose", [
            "composeBodyFound": report.composeBodyFound, "settable": report.settable ?? NSNull(),
            "wasEmpty": report.wasEmpty ?? NSNull(), "setCode": report.setCode.map { Int($0) } ?? NSNull(),
            "readBack": report.readBack ?? NSNull(), "savedTextFound": report.savedTextFound ?? NSNull(),
            "savedText": report.savedText ?? NSNull(), "treeNodes": report.treeLines.count, "notes": report.notes,
        ])
        result.notes.append("compose body found \(report.composeBodyFound), settable \(report.settable.map(String.init) ?? "unknown"), was empty \(report.wasEmpty.map(String.init) ?? "unknown")")
        if let code = report.setCode { result.notes.append("set AXError \(code), read back \(report.readBack ?? "unreadable")") }
        if let found = report.savedTextFound { result.notes.append("saved text found \(found)") }
        result.notes.append("compose region lines written: \(report.treeLines.count)")
        result.notes.append(contentsOf: report.notes)
        endAccess(pid: pid, word: result.word, into: &result)
    }

    // MARK: - Shared steps

    private func beginAccess(pid: pid_t, into result: inout ProbeResult) async {
        let attempts = await backend.beginWebContentAccess(pid: pid)
        for attempt in attempts {
            result.codes.append(Int(attempt.axError))
            // TEMP debug logger (remove at project end)
            TempAppDebugLog.append("agent-ax", attempt.logFields)
        }
        if attempts.isEmpty { result.notes.append("no attribute was set (no nudge needed, not trusted, or already settled)") }
    }

    private func endAccess(pid: pid_t, word: String, into result: inout ProbeResult) {
        result.axMode = backend.webContentMode(pid: pid).rawValue
        let restore = backend.endWebContentAccess(pid: pid)
        // TEMP debug logger (remove at project end)
        TempAppDebugLog.append("agent-end", [
            "state": "probe:\(word)", "axMode": result.axMode, "restored": restore.restored,
            "lastPageURL": result.omnibox ?? NSNull(), "firstWebAreaMs": result.firstWebAreaMs ?? NSNull(),
            "restoreAXError": restore.axError.map { Int($0) } ?? NSNull(),
            "readBackAfterRestore": restore.readBackAfterRestore ?? NSNull(),
        ])
    }

    /// Folds one walk into the result: the latest web area facts, the first time one was seen, the last omnibox.
    private func note(_ telemetry: WalkTelemetry, at seconds: Double, into result: inout ProbeResult) {
        if telemetry.webAreaFound {
            if !result.webAreaFound { result.firstWebAreaMs = Int(seconds * 1000) }
            result.webAreaFound = true
            result.webAreaChildCount = telemetry.webAreaChildCount
        }
        if let omnibox = telemetry.omnibox { result.omnibox = omnibox }
    }

    // MARK: - Files

    private func write(_ result: ProbeResult) {
        guard let data = try? JSONSerialization.data(withJSONObject: result.jsonObject, options: [.sortedKeys, .prettyPrinted]) else { return }
        writePrivately(data, to: Self.resultURL)
    }

    private func writeComposeTree(_ lines: [String]) {
        writePrivately(Data((lines.joined(separator: "\n") + "\n").utf8), to: Self.composeTreeURL)
    }

    private func writePrivately(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func processIdentifier(_ bundleIdentifier: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }
}
