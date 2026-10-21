//
//  CustomSites.swift
//  LocalBrainKit
//
//  The user's own spoken site names ("my dashboard" -> http://127.0.0.1:9999/), a config value the app
//  reads from preferences and hands to the router and the browser planner. Nothing about any person's sites
//  is built in. Pure: the entries come in as a dictionary.
//
//  An entry counts when its name has letters or digits and its address is an http or https URL with a host;
//  anything else is ignored. Names are lowercased with single spaces. Entries are tried longest name first
//  (so "my dashboard" is consumed whole before a shorter "dashboard"), ties in alphabetical order. A speech
//  to text spelling of a name is just another key.
//

import Foundation

public enum CustomSites {
    public struct Entry: Equatable, Sendable {
        public let keyword: String
        public let url: String
    }

    /// The usable entries, longest name first.
    public static func entries(from raw: [String: String]) -> [Entry] {
        raw.compactMap { name, address -> Entry? in
            let keyword = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard keyword.contains(where: { $0.isLetter || $0.isNumber }),
                  WebPageReading.isWebURL(url), let host = URL(string: url)?.host, !host.isEmpty else { return nil }
            return Entry(keyword: keyword, url: url)
        }
        .sorted { ($0.keyword.count, $1.keyword) > ($1.keyword.count, $0.keyword) }
    }
}
