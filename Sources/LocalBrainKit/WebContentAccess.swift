//
//  WebContentAccess.swift
//  LocalBrainKit
//
//  Decides how to make a Chromium browser expose its web content to Accessibility for one run,
//  and what to undo afterwards. Pure: the caller makes the AX calls and reports each result.
//
//  Two attributes can do it. AXManualAccessibility is the clean one. Newer Chrome answers it
//  with kAXErrorAttributeUnsupported (-25205) and never exposes the page, so the fallback is
//  AXEnhancedUserInterface, the attribute VoiceOver sets. That one has side effects: it can slow
//  the browser and disturb window animation and window managers, and VoiceOver owns it. So it is
//  scoped to a run: its previous value is read and remembered before it is set, it is never
//  touched when it was already true, and `finish` hands back the value to restore at the end of
//  the run, once, after which the browser is forgotten. While VoiceOver is running it owns the
//  attribute: an unreadable previous value then counts as true, and nothing is ever set back to
//  false if VoiceOver was on at the start or is on at the end. The caller passes VoiceOver's state in.
//
//  The browser may be busy when the first call lands and answer with a transient error (-25204,
//  cannot complete). That is retried once; a second failure of any kind, like "unsupported" on the
//  first, moves on to AXEnhancedUserInterface, so a flaky first answer can no longer keep the
//  fallback from ever being tried.
//

import Foundation

/// Which attribute made the page readable for a browser, for the debug log.
public enum WebContentAccessMode: String, Sendable {
    case manual, enhanced, none
}

public struct WebContentAccess<Key: Hashable> {
    /// The AXError for "this attribute is not supported": Chrome's answer to AXManualAccessibility.
    public static var attributeUnsupportedCode: Int32 { -25205 }
    public static var successCode: Int32 { 0 }

    public enum Action: Equatable {
        case setManual
        /// Set AXEnhancedUserInterface to true. When `readPreviousFirst` is set, read its current value
        /// and report it with `recordPrevious` before setting it.
        case setEnhanced(readPreviousFirst: Bool)
    }

    private var manualGate: AttemptGate<Key>
    private var enhancedGate: AttemptGate<Key>
    private var manualWorked: Set<Key> = []
    private var manualUnsupported: Set<Key> = []
    private var manualFailures: [Key: Int] = [:]
    private var enhancedWorked: Set<Key> = []
    private var enhancedGaveUp: Set<Key> = []
    /// Keys whose AXEnhancedUserInterface we may have set, so it may need setting back.
    private var enhancedAttempted: Set<Key> = []
    private var previousEnhanced: [Key: Bool] = [:]
    private var voiceOverAtStart: Set<Key> = []

    public init(retryGapSeconds: Double = 0.5) {
        manualGate = AttemptGate(minimumGapSeconds: retryGapSeconds)
        enhancedGate = AttemptGate(minimumGapSeconds: retryGapSeconds)
    }

    /// The call to make now, nil when there is nothing to do (done, given up, or too soon after the last try).
    public mutating func nextAction(for key: Key, now: Double) -> Action? {
        if manualUnsupported.contains(key) {
            guard enhancedGate.shouldAttempt(key, now: now) else { return nil }
            enhancedAttempted.insert(key)
            return .setEnhanced(readPreviousFirst: previousEnhanced[key] == nil)
        }
        return manualGate.shouldAttempt(key, now: now) ? .setManual : nil
    }

    /// How many failures of AXManualAccessibility other than "unsupported" are tolerated before
    /// AXEnhancedUserInterface is tried.
    public static var manualFailuresBeforeEnhanced: Int { 2 }

    /// The AXError of the AXManualAccessibility call. Success ends it; "unsupported" ends it too and
    /// moves on to AXEnhancedUserInterface at once; any other error is retried after the gap (the
    /// browser may still be starting), and the second one moves on to AXEnhancedUserInterface.
    public mutating func recordManual(code: Int32, for key: Key) {
        if code == Self.successCode {
            manualWorked.insert(key)
            manualGate.recordSuccess(key)
        } else if code == Self.attributeUnsupportedCode {
            manualUnsupported.insert(key)
            manualGate.recordSuccess(key)
        } else {
            let failures = (manualFailures[key] ?? 0) + 1
            manualFailures[key] = failures
            if failures >= Self.manualFailuresBeforeEnhanced {
                manualUnsupported.insert(key)
                manualGate.recordSuccess(key)
            }
        }
    }

    /// AXEnhancedUserInterface's value before we set it; nil when it could not be read, which counts
    /// as false (its default), or as true while VoiceOver is on (VoiceOver sets it). Only the first
    /// report counts, so a retry never records our own change.
    public mutating func recordPrevious(_ value: Bool?, voiceOverOn: Bool, for key: Key) {
        guard previousEnhanced[key] == nil else { return }
        previousEnhanced[key] = value ?? voiceOverOn
        if voiceOverOn { voiceOverAtStart.insert(key) }
    }

    /// The AXError of setting AXEnhancedUserInterface. Success ends it; "unsupported" gives up (nothing
    /// was changed); any other error is retried after the gap.
    public mutating func recordEnhanced(code: Int32, for key: Key) {
        if code == Self.successCode {
            enhancedWorked.insert(key)
            enhancedGate.recordSuccess(key)
        } else if code == Self.attributeUnsupportedCode {
            enhancedAttempted.remove(key)
            enhancedGaveUp.insert(key)
            enhancedGate.recordSuccess(key)
        }
    }

    /// True when no further call can change anything for this browser: a call worked, or the last
    /// resort said "unsupported". Not true while a failed call is still waiting for its retry.
    public func isSettled(for key: Key) -> Bool {
        manualWorked.contains(key) || enhancedWorked.contains(key) || enhancedGaveUp.contains(key)
    }

    public func mode(for key: Key) -> WebContentAccessMode {
        if manualWorked.contains(key) { return .manual }
        return enhancedWorked.contains(key) ? .enhanced : .none
    }

    /// Ends the run for this browser and forgets it. Returns the value to put back into
    /// AXEnhancedUserInterface, or nil when nothing needs restoring: it was never set by us, or it was
    /// already true so we changed nothing, or VoiceOver was on at the start or is on now (it owns the
    /// value, so it is never set back to false). A second call returns nil. A set that failed other than
    /// "unsupported" counts as attempted, because a timed-out set may still have landed.
    public mutating func finish(_ key: Key, voiceOverOn: Bool) -> Bool? {
        let voiceOverOwnsIt = voiceOverOn || voiceOverAtStart.contains(key)
        defer {
            voiceOverAtStart.remove(key)
            manualWorked.remove(key)
            manualUnsupported.remove(key)
            manualFailures[key] = nil
            enhancedWorked.remove(key)
            enhancedGaveUp.remove(key)
            enhancedAttempted.remove(key)
            previousEnhanced[key] = nil
            manualGate.forget(key)
            enhancedGate.forget(key)
        }
        guard !voiceOverOwnsIt, enhancedAttempted.contains(key), let previous = previousEnhanced[key], !previous else { return nil }
        return previous
    }
}
