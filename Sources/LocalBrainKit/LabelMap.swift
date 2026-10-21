//
//  LabelMap.swift
//  LocalBrainKit
//
//  Every Accessibility role and label the draft features look for on a mail page, in one place. Each one
//  is a GUESS about what Chrome and Gmail expose until the compose probe (probe.request word `compose`)
//  has confirmed it on a real page, so a fix after the probe is a change to this file and its tests, and
//  nothing else. Pure: the app reads roles, descriptions and labels and asks the questions here.
//
//  Guessed so far:
//    - the Gmail compose body is an AXTextArea (or AXTextField) described "Message Body"
//    - the reply control is an AXButton labelled exactly "Reply" (not "Reply all")
//    - a thread in a list is an AXRow whose static texts name the sender
//    - a compose window shows `compose=` or `view=cm` in the address bar, or "compose" in the title
//    - Fastmail's compose body label is unknown; the Gmail one stands in for it
//

import Foundation

public enum LabelMap {
    // MARK: - Guessed values

    public static let composeBodyRoles: Set<String> = ["AXTextArea", "AXTextField"]
    /// Lowercase; matched as a substring of the element's description.
    public static let gmailComposeBodyDescription = "message body"
    /// PLACEHOLDER: Fastmail's compose body has not been seen yet.
    public static let fastmailComposeBodyDescription = "message body"
    /// The normalised label (SendGuard.normalize) of the reply control; "reply all" is a different control.
    public static let replyButtonLabel = "reply"
    public static let threadRowRole = "AXRow"
    public static let buttonRole = "AXButton"
    public static let staticTextRole = "AXStaticText"
    public static let linkRole = "AXLink"
    public static let composeAddressCues = ["compose=", "view=cm"]
    public static let composeTitleCue = "compose"

    /// The domain whose window holds the service's page, for choosing among a browser's windows.
    public static func preferredDomain(for service: EmailService) -> String {
        service == .gmail ? "mail.google.com" : "app.fastmail.com"
    }

    // MARK: - Questions

    public static func isComposeBody(role: String?, description: String?, service: EmailService = .gmail) -> Bool {
        guard let role, composeBodyRoles.contains(role) else { return false }
        let needle = service == .gmail ? gmailComposeBodyDescription : fastmailComposeBodyDescription
        return description?.lowercased().contains(needle) == true
    }

    public static func isReplyButton(role: String?, label: String) -> Bool {
        role == buttonRole && SendGuard.normalize(label) == replyButtonLabel
    }

    public static func isThreadRow(role: String?) -> Bool { role == threadRowRole }

    public static func isComposeWindow(title: String?, address: String?) -> Bool {
        if let address = address?.lowercased(), composeAddressCues.contains(where: { address.contains($0) }) { return true }
        return title?.lowercased().contains(composeTitleCue) == true
    }

    /// Roles a draft run may press. A link is never one of them: no link-click navigation in drafts.
    public static func mayPressInDraft(role: String) -> Bool { role == threadRowRole || role == buttonRole }

    /// True when a row's texts name the person: the name as typed, or an address (or its part before the "@").
    public static func rowMentions(person: Recipient, texts: [String]) -> Bool {
        let haystack = texts.joined(separator: " ").lowercased()
        guard !haystack.isEmpty else { return false }
        switch person {
        case .nameOnly(let name):
            let needle = name.lowercased().trimmingCharacters(in: .whitespaces)
            return !needle.isEmpty && haystack.contains(needle)
        case .address(let address):
            let needle = address.lowercased()
            if haystack.contains(needle) { return true }
            let local = needle.split(separator: "@").first.map(String.init) ?? ""
            return local.count >= 3 && haystack.contains(local)
        case .none:
            return false
        }
    }

    /// What the search link filters on: the address, else the name.
    public static func searchTerm(for person: Recipient) -> String? {
        switch person {
        case .address(let address): return address
        case .nameOnly(let name): return name
        case .none: return nil
        }
    }
}

/// One item of a mail page read in document order.
public enum PageItem: Equatable, Sendable {
    case text(String)
    case button(String)
}

/// The text of the message being replied to, taken from the page: the static texts before the last Reply
/// button, the last 2000 characters of them (the part nearest the button). It is data to quote, never an
/// instruction. This build only measures it (the draft event logs its length, never the text).
public enum ReplyContext {
    public static let maxCharacters = 2000

    public static func extract(from items: [PageItem]) -> String? {
        guard let last = items.lastIndex(where: { item in
            if case .button(let label) = item { return SendGuard.normalize(label) == LabelMap.replyButtonLabel }
            return false
        }) else { return nil }
        var parts: [String] = []
        for item in items[..<last] {
            if case .text(let text) = item {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            }
        }
        let joined = parts.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return String(joined.suffix(maxCharacters))
    }
}

/// Whether a mail page can be read: a web area was found on the service's domain and has children.
public enum PageGate {
    public static let seconds = 4.0

    public static func isReadable(url: String?, childCount: Int?, domain: String) -> Bool {
        guard WebPageReading.isWebURL(url), let host = url.flatMap({ URLComponents(string: $0)?.host?.lowercased() }),
              host == domain || host.hasSuffix("." + domain) else { return false }
        return (childCount ?? 0) > 0
    }
}
