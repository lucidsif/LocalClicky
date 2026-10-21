//
//  WebPageReading.swift
//  LocalBrainKit
//
//  The pure decisions of reading a web page through Accessibility (the AX
//  calls live in LocalClickyActions): which apps are Chromium browsers that
//  must be told an assistive client is reading, which page addresses count as
//  web pages, and how an element is named.
//

import Foundation

public enum WebPageReading {
    /// Longest label kept for one element.
    public static let maxLabelCharacters = 200
    /// Static text children joined to name a link that has no title.
    public static let maxLabelTextParts = 3

    private static let chromiumBundlePrefixes = [
        "com.google.Chrome", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac",
    ]

    /// True for Chrome (with its Beta and Canary builds), Chromium, Brave and
    /// Edge: browsers that may not expose web content until asked to.
    public static func isChromiumBrowser(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return chromiumBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    /// Fastmail's desktop app is an Electron (Chromium) shell, so it gets the same assistive-client
    /// nudge as a Chromium browser. Only AXManualAccessibility is expected to matter there.
    public static let fastmailBundleIdentifier = "com.fastmail.mac.Fastmail"

    /// True for the apps told an assistive client is reading before their web content is expected:
    /// the Chromium browsers and Fastmail's Electron app.
    public static func needsAssistiveClientNudge(bundleIdentifier: String?) -> Bool {
        isChromiumBrowser(bundleIdentifier: bundleIdentifier) || bundleIdentifier == fastmailBundleIdentifier
    }

    /// True for an http or https address, the only kind a page's web area has.
    public static func isWebURL(_ text: String?) -> Bool {
        guard let lowered = text?.lowercased() else { return false }
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    /// Which window to read when the front window has no web page: the first whose address is a
    /// web address, but one on `preferredDomain` (or a subdomain of it) wins over earlier ones.
    /// Nil when no window shows a web page.
    public static func preferredWindowIndex(_ windows: [(windowIndex: Int, url: String?)],
                                            preferredDomain: String = "youtube.com") -> Int? {
        let webWindows = windows.filter { isWebURL($0.url) }
        let preferred = webWindows.first { window in
            guard let host = window.url.flatMap({ URLComponents(string: $0)?.host?.lowercased() }) else { return false }
            return host == preferredDomain || host.hasSuffix("." + preferredDomain)
        }
        return (preferred ?? webWindows.first)?.windowIndex
    }

    /// The element's name: its title, else its description, else the first
    /// `maxLabelTextParts` non-blank `childTexts` joined by spaces. Trimmed and
    /// cut to `maxLabelCharacters`; empty when nothing names it. `childTexts`
    /// is only evaluated when the title and description are both blank.
    public static func label(title: String?, description: String?,
                             childTexts: @autoclosure () -> [String]) -> String {
        let named = [title, description].compactMap { trimmed($0) }.first
        let text = named ?? childTexts().compactMap { trimmed($0) }.prefix(maxLabelTextParts).joined(separator: " ")
        return String(text.prefix(maxLabelCharacters))
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
