//
//  PageProbe.swift
//  LocalBrainKit
//
//  The pure decisions of the TEMP page probe: which words the probe request file may hold, how the
//  address bar and the compose body are recognised, why a window walk stopped, how often the walk
//  telemetry may be written and how an Accessibility window is matched to an on-screen window. The
//  Accessibility and NSWorkspace calls live in LocalClickyActions and the app target.
//
//  TEMP, with the probe itself (remove at project end).
//

import CoreGraphics
import Foundation

/// The word on the first line of ~/.clicky-gateway/probe.request: which probe to run.
public enum ProbeWord: String, CaseIterable, Sendable {
    case chrome, fastmail, mailto, compose

    /// The first whitespace-separated word of the file's contents, lowercased and cut of punctuation;
    /// nil when it is empty or not one of the four.
    public init?(requestContents: String) {
        let first = requestContents.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let word = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard let known = ProbeWord(rawValue: word) else { return nil }
        self = known
    }
}

public enum ProbeSamples {
    /// The mailto the `mailto` probe opens in Fastmail: a safe-to-delete subject and body, no recipient.
    public static let mailtoURL = "mailto:?subject=clicky%20probe&body=clicky%20probe%2C%20safe%20to%20delete"
    /// The text the `compose` probe writes into an empty compose body.
    public static let composeMarker = "clicky probe, safe to delete"
}

public enum PageProbeMatcher {
    private static let addressBarNames = ["address and search bar", "address bar", "omnibox", "location bar"]

    /// True for the AXTextField of a Chromium toolbar that is the address bar, by its description or title.
    /// The wording is a guess until the probe shows what Chrome calls it.
    public static func isAddressBar(role: String?, title: String?, description: String?) -> Bool {
        guard role == "AXTextField" else { return false }
        return [title, description].contains { text in
            guard let lowered = text?.lowercased() else { return false }
            return addressBarNames.contains { lowered.contains($0) }
        }
    }

    /// True for the compose body of Gmail: a text area (or text field) described as "Message Body".
    public static func isComposeBody(role: String?, description: String?) -> Bool {
        LabelMap.isComposeBody(role: role, description: description)
    }

    /// True for the "Saved" or "Draft saved" text Gmail shows after it stored a draft.
    public static func isSavedIndicator(_ text: String?) -> Bool {
        text?.lowercased().contains("saved") == true
    }
}

/// Why a window walk ended.
public enum WalkStopReason: String, Sendable {
    /// The web area (and the address bar, when one was looked for) was found.
    case found
    /// The node budget ran out before the tree did.
    case maxNodes
    /// The tree ran out of depth budget: nodes at the depth limit still had children.
    case maxDepth
    /// The time budget ran out.
    case deadline
    /// The whole tree was visited and holds no web area.
    case exhausted

    public static func decide(foundWebArea: Bool, stoppedEarly: Bool, deadlinePassed: Bool,
                              hitDepthLimit: Bool) -> WalkStopReason {
        if foundWebArea { return .found }
        if stoppedEarly { return deadlinePassed ? .deadline : .maxNodes }
        return hitDepthLimit ? .maxDepth : .exhausted
    }
}

/// How many walk telemetry events a run may write, and how often: at most one per `minimumGapSeconds`,
/// for `windowSeconds` after the run began making the page readable, and `maxEvents` in all.
public struct WalkTelemetryBudget: Sendable {
    public static let windowSeconds = 10.0
    public static let maxEvents = 20
    public static let minimumGapSeconds = 0.5

    private let startedAt: Double
    private var written = 0
    private var lastAt: Double?

    public init(startedAt: Double) { self.startedAt = startedAt }

    /// True when an event may be written at `now` (and counts it as written).
    public mutating func shouldLog(now: Double) -> Bool {
        guard written < Self.maxEvents, now - startedAt <= Self.windowSeconds else { return false }
        if let lastAt, now - lastAt < Self.minimumGapSeconds { return false }
        written += 1
        lastAt = now
        return true
    }
}

public enum WindowBoundsMatcher {
    /// The on-screen window whose bounds equal `axFrame` within `tolerance` points on every edge, nil
    /// when none does. `onScreen` are the bounds of the pid's windows that CGWindowList lists as on screen.
    public static func onScreenBounds(matching axFrame: CGRect, among onScreen: [CGRect], tolerance: CGFloat = 4) -> CGRect? {
        guard !axFrame.isNull, axFrame.width > 0, axFrame.height > 0 else { return nil }
        return onScreen.first { candidate in
            abs(candidate.minX - axFrame.minX) <= tolerance && abs(candidate.minY - axFrame.minY) <= tolerance
                && abs(candidate.width - axFrame.width) <= tolerance && abs(candidate.height - axFrame.height) <= tolerance
        }
    }
}

/// What a probe run leaves in ~/.clicky-gateway/probe-result.json.
public struct ProbeResult: Equatable, Sendable {
    public var word: String
    public var ts: String
    public var axMode: String
    /// The AXError of each attribute set, in order.
    public var codes: [Int]
    public var webAreaFound: Bool
    public var webAreaChildCount: Int?
    public var firstWebAreaMs: Int?
    public var omnibox: String?
    public var notes: [String]

    public init(word: String, ts: String, axMode: String = "none", codes: [Int] = [], webAreaFound: Bool = false,
                webAreaChildCount: Int? = nil, firstWebAreaMs: Int? = nil, omnibox: String? = nil, notes: [String] = []) {
        self.word = word
        self.ts = ts
        self.axMode = axMode
        self.codes = codes
        self.webAreaFound = webAreaFound
        self.webAreaChildCount = webAreaChildCount
        self.firstWebAreaMs = firstWebAreaMs
        self.omnibox = omnibox
        self.notes = notes
    }

    /// The JSON object: every key is present, an unknown value is null.
    public var jsonObject: [String: Any] {
        [
            "word": word, "ts": ts, "axMode": axMode, "codes": codes, "webAreaFound": webAreaFound,
            "webAreaChildCount": webAreaChildCount.map { $0 as Any } ?? NSNull(),
            "firstWebAreaMs": firstWebAreaMs.map { $0 as Any } ?? NSNull(),
            "omnibox": omnibox.map { $0 as Any } ?? NSNull(),
            "notes": notes,
        ]
    }
}
