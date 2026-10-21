//
//  YouTubeSearchResults.swift
//  LocalBrainKit
//
//  Reads the video results out of YouTube's search page HTML, so a run can name the video it
//  would play without opening anything. The page carries its results as JSON in
//  `var ytInitialData = {...};`; the parser walks that JSON for `videoRenderer` objects, in
//  page order. Shorts, live and upcoming streams, and entries without a usable video id are
//  skipped. Pure and tolerant: any failure to find or read the data is an empty list, never a crash.
//

import Foundation

/// One video result read straight from the search page.
public struct DirectResult: Equatable, Sendable {
    public let videoID: String
    public let title: String

    public init(videoID: String, title: String) {
        self.videoID = videoID
        self.title = title
    }

    /// The address Chrome is asked to open. The id has been checked to be 11 URL-safe characters.
    public var watchURL: String { "https://www.youtube.com/watch?v=\(videoID)" }

    /// The consent card shows this like any other link: its title and address, with no position.
    public var consentLink: LinkCandidate { LinkCandidate(label: title, url: watchURL, frame: .zero) }
}

public enum YouTubeSearchResults {

    private static let marker = "var ytInitialData = "

    public static func parse(html: String) -> [DirectResult] {
        guard let json = initialDataJSON(in: html),
              let root = try? JSONSerialization.jsonObject(with: json) else { return [] }
        var found: [DirectResult] = []
        collect(root, into: &found)
        var seen = Set<String>()
        return found.filter { seen.insert($0.videoID).inserted }
    }

    // MARK: - Finding the JSON

    /// The bytes of the object that follows the marker, cut by matching braces (aware of strings and escapes).
    private static func initialDataJSON(in html: String) -> Data? {
        guard let markerRange = html.range(of: marker) else { return nil }
        let bytes = Array(html.utf8)
        var index = html.utf8.distance(from: html.utf8.startIndex, to: markerRange.upperBound)
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        let start = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return Data(bytes[start...index]) }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Walking it

    private static func collect(_ node: Any, into results: inout [DirectResult]) {
        if let list = node as? [Any] {
            for item in list { collect(item, into: &results) }
        } else if let object = node as? [String: Any] {
            if let renderer = object["videoRenderer"] as? [String: Any] {
                if let result = result(from: renderer) { results.append(result) }
                return
            }
            // Dictionary order is not stable; sorted keys keep the walk repeatable.
            for key in object.keys.sorted() { collect(object[key] as Any, into: &results) }
        }
    }

    private static let videoIDPattern = #"^[A-Za-z0-9_-]{11}$"#

    private static func result(from renderer: [String: Any]) -> DirectResult? {
        guard let videoID = renderer["videoId"] as? String,
              videoID.range(of: videoIDPattern, options: .regularExpression) != nil,
              !isShort(renderer), !isLiveOrUpcoming(renderer),
              let title = title(of: renderer) else { return nil }
        return DirectResult(videoID: videoID, title: title)
    }

    private static func isShort(_ renderer: [String: Any]) -> Bool {
        guard let endpoint = renderer["navigationEndpoint"] as? [String: Any] else { return false }
        if endpoint["reelWatchEndpoint"] != nil { return true }
        let url = ((endpoint["commandMetadata"] as? [String: Any])?["webCommandMetadata"] as? [String: Any])?["url"] as? String
        return url?.contains("/shorts/") ?? false
    }

    private static func isLiveOrUpcoming(_ renderer: [String: Any]) -> Bool {
        if renderer["upcomingEventData"] != nil { return true }
        let badges = (renderer["badges"] as? [[String: Any]]) ?? []
        for badge in badges {
            guard let inner = badge["metadataBadgeRenderer"] as? [String: Any] else { continue }
            if inner["style"] as? String == "BADGE_STYLE_TYPE_LIVE_NOW" { return true }
            if (inner["label"] as? String)?.uppercased() == "LIVE" { return true }
        }
        let overlays = (renderer["thumbnailOverlays"] as? [[String: Any]]) ?? []
        return overlays.contains {
            ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String == "LIVE"
        }
    }

    private static func title(of renderer: [String: Any]) -> String? {
        guard let title = renderer["title"] as? [String: Any] else { return nil }
        let text: String
        if let runs = title["runs"] as? [[String: Any]] {
            text = runs.compactMap { $0["text"] as? String }.joined()
        } else {
            text = (title["simpleText"] as? String) ?? ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
