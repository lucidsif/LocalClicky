//
//  BrowserActionExecutor.swift
//  LocalClicky
//
//  Carries out a BrowserPlan by opening each URL in the user's default browser
//  (a new tab). Using NSWorkspace rather than AppleScript keeps this permission-
//  free and browser-agnostic, and — importantly — structurally safe: the only
//  thing this can ever do is *navigate to a URL*. It cannot click, submit forms,
//  send mail, or run page scripts, so every planned action is inherently in the
//  "auto-run safe" category the user chose.
//

import AppKit
import Foundation
import LocalBrainKit

@MainActor
enum BrowserActionExecutor {
    /// Opens each planned URL in Google Chrome when it's installed (the user asked
    /// for "chrome if there"), otherwise the default browser. Still navigation
    /// only — opening a URL can't click, submit, or script the page.
    /// With `activates` false Chrome opens the page without coming to the front (the default
    /// browser fallback is unchanged).
    @discardableResult
    static func execute(_ plan: BrowserPlan, activates: Bool = true) -> Int {
        let chromeURL = chromeApplicationURL()
        var opened = 0
        for action in plan.actions {
            guard let url = URL(string: action.url) else { continue }
            if let chromeURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = activates
                NSWorkspace.shared.open([url], withApplicationAt: chromeURL, configuration: configuration)
                opened += 1
            } else if NSWorkspace.shared.open(url) {
                opened += 1
            }
        }
        return opened
    }

    /// Opens one link in a named app (Chrome for a Gmail draft, Fastmail for a mailto link, Bear for a
    /// note) without bringing it forward by default. Returns false when the app or the link is not usable.
    /// Opening a link cannot click, send or script anything.
    static func openInApp(url urlString: String, bundleIdentifier: String, activates: Bool = false) async -> Bool {
        guard let url = URL(string: urlString),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    /// The installed Google Chrome bundle, or nil if Chrome isn't present.
    private static func chromeApplicationURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome") {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
