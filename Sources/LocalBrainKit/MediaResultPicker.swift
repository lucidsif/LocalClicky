//
//  MediaResultPicker.swift
//  LocalBrainKit
//
//  Chooses which link on a YouTube results page to play. Only a plain video link
//  counts: not an ad, a short, a playlist, a channel, or a thumbnail whose label
//  is just its duration. Of those, the first that shares a word with the spoken
//  query wins, else the first one on the page. Results read straight from the search
//  page (DirectResult) are scored by how many query words their title shares.
//

import Foundation

public enum MediaResultPicker {

    public static func firstResult(in links: [LinkCandidate], query: String) -> LinkCandidate? {
        let videos = links.filter(isVideoResult)
        let queryWords = significantWords(query)
        return videos.first { !significantWords($0.label).isDisjoint(with: queryWords) } ?? videos.first
    }

    /// The result whose title shares the most words with the query, the earliest on a tie. When none
    /// shares a word, the first (the search page is already ranked).
    public static func bestResult(in results: [DirectResult], query: String) -> DirectResult? {
        let queryWords = significantWords(query)
        var best: (result: DirectResult, score: Int)?
        for result in results {
            let score = significantWords(result.title).intersection(queryWords).count
            if best == nil || score > best!.score { best = (result, score) }
        }
        return best?.result
    }

    public static func isVideoResult(_ link: LinkCandidate) -> Bool {
        guard MediaPlaybackCheck.isWatchPage(url: link.url),
              let items = URLComponents(string: link.url)?.queryItems,
              items.contains(where: { $0.name == "v" }),
              !items.contains(where: { $0.name == "list" }) else { return false }
        let label = link.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty
            && label.range(of: #"^\d{1,2}(:\d{2}){1,2}$"#, options: .regularExpression) == nil
            && !nonTitleLabels.contains(label.lowercased())
    }

    private static let nonTitleLabels: Set<String> = ["now playing", "watch later", "add to queue", "more actions"]

    /// Lowercased runs of letters, 3 or more long ("don't" counts as "don" and "t").
    private static func significantWords(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 })
    }
}
