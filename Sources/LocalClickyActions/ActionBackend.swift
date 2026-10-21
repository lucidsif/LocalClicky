//
//  ActionBackend.swift
//  LocalClickyActions
//
//  What the agent needs from the world: read a page's elements, press one,
//  read it back. Behind a protocol so the backend is chosen in one place
//  (ActionBackends.current). Only Accessibility is implemented so far.
//

import CoreGraphics
import ApplicationServices
import Foundation
import LocalBrainKit

/// One element read from a page: what it says and where it is. `handle` is the live element, kept so the
/// same element can be read back or pressed.
public struct WebElement: @unchecked Sendable {
    public let role: String
    public let label: String
    public let url: String?
    public let frame: CGRect
    let handle: AXUIElement
}

/// A text area of a mail page that a draft may write into (a compose body). `handle` is the live element.
public struct ComposeField: @unchecked Sendable {
    /// True when it held no text (or no value) when it was read.
    public let isEmpty: Bool
    let handle: AXUIElement
}

/// A web area that was found, with the address it shows and how many children it has.
public struct WebAreaStatus: Sendable, Equatable {
    public let url: String?
    public let childCount: Int
}

/// A mail message page read in document order, and its last Reply control.
public struct ThreadPage: Sendable {
    public let items: [PageItem]
    public let replyButton: WebElement?
}

public struct WebPageState: Sendable, Equatable {
    public let windowTitle: String?
    public let pageURL: String?
}

/// One attempt to tell an app an assistive client is reading (a set of AXManualAccessibility or
/// AXEnhancedUserInterface), with what the app said about it. For the TEMP agent-ax debug event.
public struct WebContentSetAttempt: Sendable {
    public let attribute: String
    public let axError: Int32
    /// System uptime when the set was made, in milliseconds.
    public let uptimeMs: Int
    public let timeoutSeconds: Double
    /// The attribute read again right after the set; "error <code>" when the read failed.
    public let readBack: String
    public let voiceOverOn: Bool
    public let appBundleId: String?
    public let appVersion: String?
    /// Whether AXUIElementCopyAttributeNames on the app lists the attribute.
    public let attributeListed: Bool
    /// AXUIElementIsAttributeSettable's answer, nil when the call failed.
    public let settable: Bool?

    public var logFields: [String: Any] {
        ["attribute": attribute, "axError": Int(axError), "uptimeMs": uptimeMs, "timeoutSeconds": timeoutSeconds,
         "readBack": readBack, "voiceOverOn": voiceOverOn, "appBundleId": appBundleId ?? NSNull(),
         "appVersion": appVersion ?? NSNull(), "attributeListed": attributeListed, "settable": settable ?? NSNull()]
    }
}

/// What ending a run's web content access did, for the TEMP agent-end debug event.
public struct WebContentRestoreReport: Sendable {
    /// True when AXEnhancedUserInterface was written back successfully.
    public let restored: Bool
    /// The AXError of the write-back, nil when nothing needed writing back.
    public let axError: Int32?
    /// AXEnhancedUserInterface read again after the write-back; nil when nothing was written back.
    public let readBackAfterRestore: String?
}

/// One look at a window's tree while the page was being made readable, for the TEMP agent-walk debug event.
public struct WalkTelemetry: Sendable {
    public let windowIndex: Int?
    public let windowTitle: String?
    public let nodesVisited: Int
    public let maxDepth: Int
    public let stopReason: WalkStopReason
    public let elapsedMs: Int
    public let webAreaFound: Bool
    public let webAreaURL: String?
    public let webAreaChildCount: Int?
    public let windowOnScreen: Bool
    /// [x, y, width, height] of the on-screen window that matches the Accessibility window.
    public let windowBounds: [Double]?
    /// The address bar's value; only looked for in Chromium browsers.
    public let omnibox: String?

    public var logFields: [String: Any] {
        ["windowIndex": windowIndex ?? NSNull(), "windowTitle": windowTitle ?? NSNull(), "nodesVisited": nodesVisited,
         "maxDepth": maxDepth, "stopReason": stopReason.rawValue, "elapsedMs": elapsedMs, "webAreaFound": webAreaFound,
         "webAreaURL": webAreaURL ?? NSNull(), "webAreaChildCount": webAreaChildCount ?? NSNull(),
         "windowOnScreen": windowOnScreen, "windowBounds": windowBounds ?? NSNull(), "omnibox": omnibox ?? NSNull()]
    }
}

public protocol ActionBackend: Sendable {
    /// Tells the app an assistive client is reading, so it exposes its web content. Called once per run,
    /// before the page is opened, on its own app element with a generous messaging timeout; the read
    /// calls below never make this call. Returns every set that was attempted (empty for an app that
    /// needs no nudge, or without the Accessibility permission). Calling it again after it settled does nothing.
    func beginWebContentAccess(pid: pid_t) async -> [WebContentSetAttempt]
    /// One bounded look at the front window's tree and what it holds. Nil without the Accessibility permission.
    func walkTelemetry(pid: pid_t, budget: TimeInterval) async -> WalkTelemetry?
    /// The focused window's title and the URL of its web area. Nil when the app has no window or no web area.
    func pageState(pid: pid_t) async -> WebPageState?
    /// Elements of the given roles in the focused window's web area, in tree order, within `budget` seconds.
    func walk(pid: pid_t, roles: Set<String>, budget: TimeInterval) async -> [WebElement]
    /// Presses the element. `.unverifiable` when the press was accepted (the caller verifies on the page), `.noop` when it was refused.
    func press(_ element: WebElement) async -> ActionEffect
    // Mail pages (drafts). `preferredDomain` picks the window whose web area is on that domain. None of
    // these sets AXFocused, raises a window or posts an event; the only write is a compose body's AXValue.

    /// The service's web area, if one is found: its address and child count. Nil when there is none.
    func webAreaStatus(pid: pid_t, preferredDomain: String) async -> WebAreaStatus?
    /// The address of the preferred domain's web area, nil when none is found.
    func pageURL(pid: pid_t, preferredDomain: String) async -> String?
    /// The settable compose bodies of the service's page, in tree order, within `budget` seconds.
    func composeFields(pid: pid_t, service: EmailService, budget: TimeInterval) async -> [ComposeField]
    /// Sets the field's value to `text` (after its old text and a blank line when `appending`) and reads it
    /// back. False when the old text could not be read for an append, the set failed, or the read back differs.
    func setValue(_ text: String, in field: ComposeField, appending: Bool) async -> Bool
    /// Message rows (AXRow) of the service's page; each label is the row's static texts joined.
    func messageRows(pid: pid_t, preferredDomain: String, budget: TimeInterval) async -> [WebElement]
    /// The message page in document order, with its last Reply control.
    func readThread(pid: pid_t, preferredDomain: String, budget: TimeInterval) async -> ThreadPage
    /// Presses a row or a button, through `press` (so SendGuard applies). Refuses anything else, links included.
    func pressControl(_ element: WebElement) async -> ActionEffect
    /// Reads the same element again, nil when it is gone.
    func readBack(_ element: WebElement) async -> WebElement?
    /// The raw AXError of the last "an assistive client is reading" call for this browser pid, nil when none was made. For the debug log.
    func lastManualAccessibilityResult(pid: pid_t) -> Int32?
    /// How the browser's web content was made readable in the current run (manual, enhanced or none). For the debug log.
    func webContentMode(pid: pid_t) -> WebContentAccessMode
    /// Ends the run's web content access for this browser: puts AXEnhancedUserInterface back to the value it had
    /// before the run, but only if the run changed it, and forgets the browser. Reports what it wrote and read
    /// back. Safe to call more than once.
    @discardableResult func endWebContentAccess(pid: pid_t) -> WebContentRestoreReport
}

/// The one place the backend is chosen. The plan's Cua Driver would replace this line after its probes pass.
public enum ActionBackends { public static func current() -> ActionBackend { AXBackend() } }

public extension WebElement {
    var linkCandidate: LinkCandidate { LinkCandidate(label: label, url: url ?? "", frame: frame) }
}
