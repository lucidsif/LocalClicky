//
//  MediaPlaybackCheck.swift
//  LocalBrainKit
//
//  The checks that tell whether a press worked: is the page a YouTube watch page,
//  is it still on the locked domain, is a Pause button showing (the video is
//  playing) or a Play button (it is not). Pure functions over strings the app
//  reads from the accessibility tree.
//

import Foundation

public enum MediaPlaybackCheck {

    public static func isWatchPage(url: String?) -> Bool {
        guard let url, let parts = URLComponents(string: url), let host = parts.host?.lowercased() else { return false }
        return ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) && parts.path == "/watch"
    }

    /// The `v` parameter of a watch page address, nil for anything else.
    public static func videoID(inWatchURL url: String?) -> String? {
        guard isWatchPage(url: url), let url else { return nil }
        return URLComponents(string: url)?.queryItems?.first { $0.name == "v" }?.value
    }

    /// True when the host is the lock or one of its subdomains. A nil URL is not on the domain.
    public static func isOnDomain(url: String?, domainLock: String) -> Bool {
        guard let url, let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        let lock = domainLock.lowercased()
        return host == lock || host.hasSuffix("." + lock)
    }

    public static func pauseButtonPresent(buttonLabels: [String]) -> Bool {
        buttonLabels.contains { labelNames($0, verb: "pause") }
    }

    public static func playButtonIndex(buttonLabels: [String]) -> Int? {
        buttonLabels.firstIndex { labelNames($0, verb: "play") }
    }

    /// "Pause", "Pause (k)" and "Pause keyboard shortcut k" name the control; "Play all",
    /// "Playlist" and "Play next" do not.
    private static func labelNames(_ label: String, verb: String) -> Bool {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text == verb || text.hasPrefix(verb + " (") || text.hasPrefix(verb + " keyboard shortcut")
    }
}
