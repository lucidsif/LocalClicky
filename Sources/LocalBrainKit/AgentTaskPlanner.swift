//
//  AgentTaskPlanner.swift
//  LocalBrainKit
//
//  Detects the one multi-step computer task LocalClicky can run on its own:
//  "go to youtube and play <video>". Pure and deterministic, no model: a play verb
//  plus the word "youtube" is the trigger, so "play X on spotify", "open youtube" and
//  "search youtube for X" (a plain browser search) never match. Without the word
//  youtube, only an explicit request frame around "play" counts ("can you play X",
//  "i want you to play X", "please play X", "play X for me"); a bare "play X" does not.
//
//  A run is in the background unless the words ask for the foreground ("in the
//  foreground", "bring it up", "show me" next to the request, and a few more).
//

import Foundation

/// What to play and where to look for it.
public struct MediaRequest: Equatable, Sendable {
    /// The words naming the video, e.g. "lucid dreams by juice wrld".
    public let query: String
    public let searchURL: String
    /// The run stops if the page leaves this domain.
    public let domainLock: String
    /// True only when the user asked to see it: Chrome comes to the front and the mouse and keys
    /// stop the run. Otherwise the run works in the background and leaves the screen alone.
    public let foreground: Bool

    public init(query: String, searchURL: String, domainLock: String, foreground: Bool = false) {
        self.query = query
        self.searchURL = searchURL
        self.domainLock = domainLock
        self.foreground = foreground
    }
}

public enum MediaIntent: Equatable, Sendable {
    case play(MediaRequest)
    /// A play request with no usable video name ("open youtube and play a video"):
    /// the app asks which video.
    case needsQuery
}

public enum AgentTaskPlanner {

    public static func mediaIntent(from transcript: String) -> MediaIntent? {
        let text = ComputerActionPlanner.normalize(transcript).replacingOccurrences(of: "you tube", with: "youtube")
        // Punctuation becomes a space; apostrophes stay so "don't stop me now" survives.
        var words = text
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
        let foreground = removeForegroundPhrases(from: &words)
        guard let (verb, afterVerb, beforeVerb) = wordsAfterPlayVerb(in: words) else { return nil }
        let namesYouTube = words.contains("youtube")
        guard namesYouTube || isExplicitPlayRequest(verb: verb, before: beforeVerb, after: afterVerb, words: words) else {
            return nil
        }

        var query = removingSite(from: afterVerb)
        stripFiller(&query)
        let joined = query.joined(separator: " ")
        guard !joined.isEmpty, !genericQueries.contains(joined) else {
            // "watch" is also ordinary talk ("i watch youtube a lot"), so without a
            // video name it is not a request; the play verbs still ask which video.
            // Without the word youtube there is no site to ask about either.
            return verb == ["watch"] || !namesYouTube ? nil : .needsQuery
        }
        return .play(MediaRequest(query: joined,
                                  searchURL: BrowserCommandPlanner.youtubeSearchURL(query: joined),
                                  domainLock: "youtube.com",
                                  foreground: foreground))
    }

    /// Phrases that ask to see the run happen. They are taken out of the words so they never
    /// reach the search. Longest first, so "in the foreground" goes before "foreground".
    private static let foregroundPhrases: [[String]] = [
        ["in", "the", "foreground"], ["in", "foreground"], ["foreground"], ["to", "the", "front"], ["in", "front"],
        ["bring", "chrome", "up"], ["bring", "it", "up"],
        ["where", "i", "can", "see", "it"], ["so", "i", "can", "see", "it"],
    ]

    /// Removes the foreground phrases and reports whether there was one. "show me" counts only
    /// at the start or the end of the request, and only next to a play verb: it is also the
    /// start of ordinary talk ("show me a youtube playlist") and of titles ("show me the way").
    private static func removeForegroundPhrases(from words: inout [String]) -> Bool {
        var found = false
        for phrase in foregroundPhrases {
            var index = 0
            while index + phrase.count <= words.count {
                if Array(words[index..<(index + phrase.count)]) == phrase {
                    words.removeSubrange(index..<(index + phrase.count))
                    found = true
                } else {
                    index += 1
                }
            }
        }
        let showMe = ["show", "me"]
        if wordsAfterPlayVerb(in: words) != nil {
            if words.starts(with: showMe) { words.removeFirst(2); found = true }
            else if words.count >= 2, Array(words.suffix(2)) == showMe { words.removeLast(2); found = true }
        }
        return found
    }

    private static let playVerbs: [[String]] = [["start", "playing"], ["put", "on"], ["play"], ["watch"]]

    private static let genericQueries: Set<String> = [
        "a video", "video", "videos", "something", "anything", "a song", "song", "music", "some music",
        // What is left of "a video" or "some video" once the trailing "video" is stripped.
        "a", "an", "some", "the",
    ]

    /// "i watch youtube a lot" is talk about habits, not a request. "you" is left out on
    /// purpose: "can you play X on youtube" is a request.
    private static let subjectPronouns: Set<String> = ["i", "we", "they", "he", "she"]

    /// The first play verb, the words after it and the words before it, nil when there is
    /// no verb. A verb right after a subject pronoun is skipped.
    private static func wordsAfterPlayVerb(in words: [String]) -> (verb: [String], rest: [String], before: [String])? {
        for start in words.indices where start == 0 || !subjectPronouns.contains(words[start - 1]) {
            for verb in playVerbs where words[start...].starts(with: verb) {
                return (verb, Array(words[(start + verb.count)...]), Array(words[..<start]))
            }
        }
        return nil
    }

    // MARK: - Requests that do not name the site

    /// Words that may open a request ("hey clicky, ...") and are ignored when reading its frame.
    private static let addressWords: Set<String> = ["hey", "hi", "ok", "okay", "clicky"]

    private static let requestLeadIns: Set<[String]> = [
        ["please"], ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
        ["can", "you", "please"], ["could", "you", "please"], ["would", "you", "please"],
        ["i", "want", "you", "to"], ["i", "need", "you", "to"], ["i'd", "like", "you", "to"],
        ["i", "would", "like", "you", "to"],
    ]

    /// Other places to play things. A request that names one is not for youtube.
    private static let otherServices: Set<String> = [
        "spotify", "netflix", "hulu", "soundcloud", "pandora", "tidal", "deezer", "twitch", "vimeo", "disney",
    ]

    /// With no youtube in the words, a request still counts when "play" sits in a request frame:
    /// a lead-in before it ("can you play X", "i want you to play X", "please play X") or "for me" /
    /// "please" at the end ("play X for me"). Only "play" and "start playing" count: "watch" and "put
    /// on" are ordinary talk without a site ("put on a jacket").
    private static func isExplicitPlayRequest(verb: [String], before: [String], after: [String], words: [String]) -> Bool {
        guard verb == ["play"] || verb == ["start", "playing"], Set(words).isDisjoint(with: otherServices),
              !words.joined(separator: " ").contains("apple music") else { return false }
        var lead = before
        while let first = lead.first, addressWords.contains(first) { lead.removeFirst() }
        if requestLeadIns.contains(lead) { return true }
        return lead.isEmpty && (after.suffix(2) == ["for", "me"] || after.last == "please")
    }

    /// Drops "youtube" and the preposition just before it ("on youtube").
    private static func removingSite(from words: [String]) -> [String] {
        let prepositions: Set<String> = ["on", "in", "from", "at", "using", "via", "with"]
        var kept: [String] = []
        for word in words {
            if word == "youtube" {
                if let last = kept.last, prepositions.contains(last) { kept.removeLast() }
                continue
            }
            kept.append(word)
        }
        return kept
    }

    private static let leadingFiller: [[String]] = [
        ["the", "music", "video", "for"], ["a", "video", "called"], ["a", "video", "of"],
        ["the", "video"], ["the", "song"], ["me"], ["the"],
    ]
    private static let trailingFiller: [[String]] = [
        ["for", "me"], ["please"], ["the", "song"], ["song"], ["video"], ["and"],
    ]

    /// Takes one filler phrase off either end per round and starts over, so a phrase that
    /// only shows up once another is gone ("me the song despacito") is still found, and a
    /// longer phrase is always tried before the shorter one it contains ("the song" before "the").
    private static func stripFiller(_ words: inout [String]) {
        while true {
            if let phrase = leadingFiller.first(where: { words.starts(with: $0) }) {
                words.removeFirst(phrase.count)
            } else if let phrase = trailingFiller.first(where: {
                words.count >= $0.count && Array(words.suffix($0.count)) == $0
            }) {
                words.removeLast(phrase.count)
            } else {
                return
            }
        }
    }
}
