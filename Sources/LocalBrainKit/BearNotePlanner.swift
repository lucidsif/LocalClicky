//
//  BearNotePlanner.swift
//  LocalBrainKit
//
//  Writes notes into Bear by its own URL scheme, with no page reading and no window coming forward:
//
//    "write a note in bear: buy milk"                          -> create, no title (Bear titles it)
//    "make a bear note called groceries saying milk and eggs"  -> create with a title
//    "add to my bear note groceries: buy flowers"              -> add text to that note
//    "add buy flowers to my groceries note in bear"            -> the same
//
//  A command starts with a verb (write, make, create, add, put, append, save, take) and names Bear,
//  so a sentence that only mentions Bear is chat. Pure, no model; the opening is the app's job.
//

import Foundation

public struct BearNoteRequest: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case create, append }
    public let mode: Mode
    /// The note's title; nil for a new note that Bear titles from its first line. Always set for append.
    public let title: String?
    /// What to write; empty when the words named a note but no text.
    public let text: String
}

public enum BearNotePlanner {
    public static let bundleIdentifier = "net.shinyfrog.bear"

    public static func request(from transcript: String) -> BearNoteRequest? {
        let spoken = transcript.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowers = spoken.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        guard let bear = lowers.firstIndex(of: "bear") else { return nil }
        // "draft an email to bob, check my bear note": the draft comes first, so it is the draft's.
        if let key = EmailDraftPlanner.firstKeywordIndex(in: lowers), key < bear { return nil }
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)) else { continue }
            func group(_ name: String) -> String? {
                guard let range = Range(match.range(withName: name), in: spoken) else { return nil }
                return clean(String(spoken[range]))
            }
            let title = group("title")
            let text = group("text") ?? ""
            if pattern.appends {
                guard let title, !title.isEmpty else { continue }
                return BearNoteRequest(mode: .append, title: title, text: text)
            }
            return BearNoteRequest(mode: .create, title: title?.isEmpty == false ? title : nil, text: text)
        }
        return nil
    }

    // MARK: - URLs

    /// What is said after the link opened. Never "sent": that word is only for email.
    public static let addedLine = "added the note to bear."
    public static let failedLine = "i could not reach bear, so nothing was saved."
    public static let askTextLine = "what should the note say?"

    private static let flags = "open_note=no&show_window=no"

    /// `bear://x-callback-url/create?...` for a new note (tagged clicky), `.../add-text?...&mode=append` for an existing one.
    public static func url(for request: BearNoteRequest) -> String {
        let text = StrictURLEncoder.encode(request.text)
        switch request.mode {
        case .create:
            let title = request.title.map { "title=\(StrictURLEncoder.encode($0))&" } ?? ""
            return "bear://x-callback-url/create?\(title)text=\(text)&tags=clicky&\(flags)"
        case .append:
            return "bear://x-callback-url/add-text?title=\(StrictURLEncoder.encode(request.title ?? ""))&text=\(text)&mode=append&\(flags)"
        }
    }

    // MARK: - Grammar

    private struct Pattern {
        let regex: NSRegularExpression
        let appends: Bool
    }

    private static let lead = #"^(?:(?:hey|ok|okay)\s+clicky[,\s]+)?(?:(?:please|can you|could you|i want you to|i'd like you to)[,\s]+)?"#
    private static let separator = #"(?:\s*[:,]\s*|\s+(?:saying|that says|and say|with the text|with)\s+)"#

    private static let patterns: [Pattern] = [
        // add to my bear note groceries: buy flowers
        Pattern(regex: make(lead + #"(?:add|append|put)\s+(?:this\s+)?(?:something\s+)?to\s+(?:my\s+|the\s+)?bear\s+note\s+(?:called\s+|named\s+|titled\s+)?(?<title>.+?)"# + separator + #"(?<text>.+)$"#), appends: true),
        // add buy flowers to my groceries note in bear
        Pattern(regex: make(lead + #"(?:add|append|put)\s+(?<text>.+?)\s+to\s+(?:my\s+|the\s+)?(?<title>.+?)\s+note\s+in\s+(?:my\s+)?bear\s*$"#), appends: true),
        // make a bear note called groceries saying milk and eggs / make a note in bear called groceries: milk
        Pattern(regex: make(lead + #"(?:make|create|write|take|start|add)\s+(?:me\s+)?(?:a\s+|new\s+)*(?:new\s+)?(?:bear\s+note|note\s+(?:in|on|to)\s+(?:my\s+)?bear(?:\s+app)?)\s+(?:called|named|titled)\s+(?<title>.+?)"# + separator + #"(?<text>.+)$"#), appends: false),
        // write a note in bear: buy milk / save this to bear: buy milk / make a bear note: buy milk
        Pattern(regex: make(lead + #"(?:make|create|write|take|start|add|save|put)\s+(?:me\s+)?(?:(?:a|new|this|that)\s+)*(?:(?:bear\s+)?note|bear\s+note)?\s*(?:in|on|to)?\s*(?:my\s+)?bear(?:\s+app|\s+note)?"# + #"(?:\s*[:,]\s*|\s+(?:saying|that says|and say|with the text)\s+)(?<text>.+)$"#), appends: false),
        // a named note with nothing to write: "make a bear note called groceries"
        Pattern(regex: make(lead + #"(?:make|create|write|take|start)\s+(?:me\s+)?(?:(?:a|new)\s+)*bear\s+note\s+(?:called|named|titled)\s+(?<title>.+?)\s*$"#), appends: false),
        // a note with nothing to write: "write a note in bear"
        Pattern(regex: make(lead + #"(?:make|create|write|take|start)\s+(?:me\s+)?(?:(?:a|new)\s+)*(?:bear\s+note|note\s+(?:in|on)\s+(?:my\s+)?bear(?:\s+app)?)\s*$"#), appends: false),
    ]

    private static func make(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:\"")))
    }
}
