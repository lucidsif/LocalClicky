//
//  EmailDraftPlanner.swift
//  LocalBrainKit
//
//  Reads a spoken email-draft request with a fixed grammar, no model:
//
//    "open a gmail draft and tell X i will get back to him"
//    "draft a reply to Bob in my gmail"
//    "draft an email to bob at example dot com saying i will get back to him"
//    "use the current draft on screen not create new draft"
//
//  and returns the service (gmail or fastmail, nil when none is named), whether it is a new
//  draft or a reply, whether the user means the draft that is already open, who it is for, and
//  the gist of the message. It declines anything that is not a command: a question, a fragment
//  ("John in the email"), "open my gmail". The command has to start with a verb (open, draft,
//  write, compose, start, create, make, new, use, fill, reply, respond), after any "hey clicky" or
//  "can you" in front, so words inside the message ("tell bob to check the weather") can never
//  turn another request into a draft, and a draft request cannot be stolen by them.
//
//  The recipient is an address when one can be heard (SpelledAddress), a bare name otherwise
//  ("Bob", one word), or none. A lookup in the second brain can replace the name step later.
//

import Foundation

public enum EmailService: String, Equatable, Sendable {
    case gmail, fastmail
}

public enum DraftKind: String, Equatable, Sendable {
    case new, reply
}

/// Who a draft is for. `nameOnly` has no address, so the To field stays empty.
public enum Recipient: Equatable, Sendable {
    case address(String)
    case nameOnly(String)
    case none

    /// For the debug log: which kind, never the value.
    public var kindName: String {
        switch self {
        case .address: return "address"
        case .nameOnly: return "name"
        case .none: return "none"
        }
    }
}

public struct EmailDraftRequest: Equatable, Sendable {
    public let service: EmailService?
    public let kind: DraftKind
    /// The user means the draft that is already open ("use the current draft"), not a new one.
    public let useOpenDraft: Bool
    public let recipient: Recipient
    /// What the message should say, in the user's words; empty when none was given.
    public let gist: String
    /// Only when the words say "subject ...".
    public let subject: String?

    public init(service: EmailService?, kind: DraftKind, useOpenDraft: Bool, recipient: Recipient,
                gist: String, subject: String? = nil) {
        self.service = service
        self.kind = kind
        self.useOpenDraft = useOpenDraft
        self.recipient = recipient
        self.gist = gist
        self.subject = subject
    }
}

extension EmailDraftRequest {
    /// The same request with the service the user named when asked ("gmail or fastmail?").
    public func withService(_ service: EmailService) -> EmailDraftRequest {
        EmailDraftRequest(service: service, kind: kind, useOpenDraft: useOpenDraft, recipient: recipient,
                          gist: gist, subject: subject)
    }
}

public enum EmailDraftPlanner {

    /// The answer to "gmail or fastmail?": a turn that is only a service name, with at most "in", "use",
    /// "on", "with", "my" and "please" around it.
    public static func serviceAnswer(from transcript: String) -> EmailService? {
        let lowers = tokenize(transcript).map(\.lower)
        let filler: Set<String> = ["in", "use", "on", "with", "my", "please", "the", "just", "uh", "um", "and", "using"]
        let rest = lowers.filter { !filler.contains($0) }
        for spelling in serviceSpellings where rest == spelling.words { return spelling.service }
        return nil
    }

    /// Nil when `transcript` is not a draft command.
    public static func request(from transcript: String) -> EmailDraftRequest? {
        var words = tokenize(transcript)
        guard let start = commandStart(in: words) else { return nil }
        words = Array(words[start...])
        let lowers = words.map(\.lower)
        guard accepts(verb: lowers[0], lowers: lowers) else { return nil }
        // "write a note in bear: draft the email": the note comes first, so it is Bear's.
        if let bear = lowers.firstIndex(of: "bear"), let key = firstKeywordIndex(in: lowers), bear < key { return nil }

        let subject = extractSubject(from: &words)
        let wordLowers = words.map(\.lower)
        let frameEnd = [wordLowers.firstIndex { isGistMarker($0) }, sayMarker(in: wordLowers)?.index].compactMap { $0 }.min()
            ?? words.count
        let frame = Array(words.map(\.lower)[..<min(frameEnd, words.count)])

        let useOpenDraft = mentionsOpenDraft(frame)
        let kind: DraftKind = frame.contains(where: { ["reply", "respond", "replying"].contains($0) }) ? .reply : .new
        let service = removeServiceMention(from: &words, frameEnd: frameEnd)

        let (recipient, gistWords) = recipientAndGist(words)
        let gist = stripConnectors(gistWords).map(\.text).joined(separator: " ")
        return EmailDraftRequest(service: service, kind: kind, useOpenDraft: useOpenDraft, recipient: recipient,
                                 gist: gist, subject: subject)
    }

    /// The index of the first word that names mail (draft, email, gmail, fastmail), for deciding which of
    /// two commands in one sentence comes first.
    public static func firstKeywordIndex(in lowers: [String]) -> Int? {
        lowers.firstIndex { keywords.contains($0) }
    }

    // MARK: - Words

    struct Word {
        let text: String
        let lower: String
        /// The spoken word ended in a colon: what follows is the message.
        let colon: Bool
    }

    private static let keywords: Set<String> = ["draft", "drafts", "email", "e-mail", "emails", "mail", "gmail", "fastmail"]

    static func tokenize(_ transcript: String) -> [Word] {
        let normalized = transcript.replacingOccurrences(of: "\u{2019}", with: "'")
        let edge = CharacterSet(charactersIn: ",;:!?\"()[]<>")
        return normalized.split(whereSeparator: \.isWhitespace).compactMap { piece in
            let raw = String(piece)
            var text = raw.trimmingCharacters(in: edge)
            while text.hasSuffix(".") { text.removeLast() }
            guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return Word(text: text, lower: text.lowercased(), colon: raw.hasSuffix(":"))
        }
    }

    private static let addressWords: Set<String> = ["hey", "hi", "ok", "okay", "clicky", "so", "um", "uh", "alright"]

    private static let leadIns: [[String]] = [
        ["can", "you", "please"], ["could", "you", "please"], ["would", "you", "please"],
        ["i", "would", "like", "you", "to"], ["i'd", "like", "you", "to"], ["i", "want", "you", "to"],
        ["i", "need", "you", "to"], ["i'd", "like", "to"], ["i", "want", "to"], ["i", "need", "to"],
        ["go", "ahead", "and"], ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
        ["please"], ["let's"], ["lets"], ["i", "wanna"], ["just"],
    ]

    private static let commandVerbs: Set<String> = [
        "open", "draft", "write", "compose", "start", "create", "make", "new", "use", "fill", "reply", "respond", "begin",
    ]

    /// Index of the first word of the command after any address words and request lead-ins, nil when it does
    /// not start with a command verb.
    private static func commandStart(in words: [Word]) -> Int? {
        var index = 0
        scanning: while index < words.count {
            if addressWords.contains(words[index].lower) { index += 1; continue }
            for leadIn in leadIns where index + leadIn.count <= words.count
                && words[index..<(index + leadIn.count)].map(\.lower) == leadIn {
                index += leadIn.count
                continue scanning
            }
            break
        }
        guard index < words.count, commandVerbs.contains(words[index].lower) else { return nil }
        return index
    }

    private static func accepts(verb: String, lowers: [String]) -> Bool {
        let hasDraft = lowers.contains("draft") || lowers.contains("drafts")
        let hasEmail = lowers.contains { ["email", "e-mail", "emails", "mail"].contains($0) }
        let hasReply = lowers.contains { ["reply", "respond"].contains($0) }
        let hasService = mentionsService(lowers)
        switch verb {
        case "open", "use", "fill": return hasDraft
        case "reply", "respond": return hasDraft || hasEmail || hasService
        case "draft": return hasEmail || hasService || hasReply
        default: return hasDraft || hasEmail
        }
    }

    // MARK: - Frame: service, open draft, subject

    private static let serviceSpellings: [(words: [String], service: EmailService)] = [
        (["gmail"], .gmail), (["g", "mail"], .gmail), (["gee", "mail"], .gmail), (["google", "mail"], .gmail),
        (["fastmail"], .fastmail), (["fast", "mail"], .fastmail),
    ]

    private static func mentionsService(_ lowers: [String]) -> Bool {
        serviceMatch(in: lowers, before: lowers.count) != nil
    }

    private static func serviceMatch(in lowers: [String], before end: Int) -> (range: Range<Int>, service: EmailService)? {
        var index = 0
        while index < min(end, lowers.count) {
            for spelling in serviceSpellings where index + spelling.words.count <= min(end, lowers.count)
                && Array(lowers[index..<(index + spelling.words.count)]) == spelling.words {
                return (index..<(index + spelling.words.count), spelling.service)
            }
            index += 1
        }
        return nil
    }

    private static let prepositions: Set<String> = ["in", "on", "with", "using", "via", "from"]
    private static let articles: Set<String> = ["my", "the", "a", "an"]

    /// Takes the first service mention before the message out of `words` (with the "in my" in front of it)
    /// and returns the service.
    private static func removeServiceMention(from words: inout [Word], frameEnd: Int) -> EmailService? {
        let lowers = words.map(\.lower)
        guard let match = serviceMatch(in: lowers, before: frameEnd) else { return nil }
        var lower = match.range.lowerBound
        if lower >= 1, prepositions.contains(lowers[lower - 1]) {
            lower -= 1
        } else if lower >= 2, articles.contains(lowers[lower - 1]), prepositions.contains(lowers[lower - 2]) {
            lower -= 2
        }
        words.removeSubrange(lower..<match.range.upperBound)
        return match.service
    }

    private static let openDraftPhrases: [[String]] = [
        ["current", "draft"], ["this", "draft"], ["existing", "draft"], ["open", "draft"], ["same", "draft"],
        ["draft", "on", "screen"], ["draft", "on", "the", "screen"], ["draft", "on", "my", "screen"],
        ["draft", "i", "have", "open"], ["draft", "i", "have", "up"], ["draft", "that", "is", "open"],
        ["draft", "that's", "open"], ["draft", "already", "open"], ["already", "open", "draft"],
    ]

    private static func mentionsOpenDraft(_ lowers: [String]) -> Bool {
        openDraftPhrases.contains { phrase in
            guard lowers.count >= phrase.count else { return false }
            return (0...(lowers.count - phrase.count)).contains { Array(lowers[$0..<($0 + phrase.count)]) == phrase }
        }
    }

    private static let gistMarkers: Set<String> = ["saying", "says", "say", "tell", "telling"]

    private static func isGistMarker(_ lower: String) -> Bool { gistMarkers.contains(lower) }

    /// The first word that introduces the message itself: saying, says, say, telling; "that" (but not "that is
    /// open", "that's open" or "that says", which the other rules own); and "let(ting) him/her/them know". `gistStart`
    /// is where the message begins (connector words still in front are stripped later).
    static func sayMarker(in lowers: [String]) -> (index: Int, gistStart: Int)? {
        for index in lowers.indices {
            let word = lowers[index]
            let next = index + 1 < lowers.count ? lowers[index + 1] : nil
            if ["saying", "says", "say", "telling"].contains(word) { return (index, index) }
            if word == "that", let next, !["is", "says", "has", "was"].contains(next), !next.hasPrefix("'") { return (index, index + 1) }
            if ["let", "letting"].contains(word), index + 2 < lowers.count,
               ["him", "her", "them"].contains(lowers[index + 1]), lowers[index + 2] == "know" {
                return (index, index + 3)
            }
        }
        return nil
    }

    private static let subjectStops: Set<String> = ["saying", "says", "say", "body", "message", "tell", "telling", "and"]

    /// "with the subject lunch tomorrow saying are you free": takes "with the subject lunch tomorrow" out of
    /// `words` and returns "lunch tomorrow".
    private static func extractSubject(from words: inout [Word]) -> String? {
        let lowers = words.map(\.lower)
        guard let at = lowers.firstIndex(of: "subject") else { return nil }
        var index = at + 1
        while index < words.count, ["line", "is", "of", "as", "being"].contains(lowers[index]) { index += 1 }
        var subjectWords: [String] = []
        while index < words.count, !subjectStops.contains(lowers[index]) {
            subjectWords.append(words[index].text)
            let ended = words[index].colon
            index += 1
            if ended { break }
        }
        guard !subjectWords.isEmpty else { return nil }
        var lower = at
        while lower >= 1, ["with", "the", "a", "and"].contains(lowers[lower - 1]) { lower -= 1 }
        words.removeSubrange(lower..<index)
        return subjectWords.joined(separator: " ")
    }

    // MARK: - Recipient and gist

    private static let notNames: Set<String> = [
        "him", "her", "them", "it", "me", "my", "the", "a", "an", "this", "that", "these", "those", "whoever",
        "someone", "anyone", "see", "ask", "remind", "say", "let", "know", "continue", "be", "do", "have", "get",
        "and", "in", "on", "with", "saying", "says", "about",
    ]

    private static func recipientAndGist(_ words: [Word]) -> (Recipient, [Word]) {
        let lowers = words.map(\.lower)
        if let match = SpelledAddress.find(in: lowers) {
            return (.address(match.address), Array(words[match.tokenRange.upperBound...]))
        }
        // A saying word ("saying", "telling", "that", "let him know") that comes before any "to" or "tell" starts the
        // message: a later "to" belongs to the message ("... get back to him"), not to a recipient.
        let say = sayMarker(in: lowers)
        if let marker = lowers.firstIndex(where: { $0 == "to" || $0 == "tell" }), say == nil || marker < say!.index {
            let next = marker + 1
            if next < words.count, isName(words[next]) {
                return (.nameOnly(words[next].text), Array(words[(next + 1)...]))
            }
            let skipPronoun = next < words.count && ["him", "her", "them"].contains(lowers[next])
            return (.none, Array(words[(skipPronoun ? next + 1 : next)...]))
        }
        if let say { return (.none, Array(words[say.gistStart...])) }
        if let marker = words.indices.first(where: { isGistMarker(lowers[$0]) || words[$0].colon }) {
            let from = isGistMarker(lowers[marker]) ? marker : marker + 1
            return (.none, Array(words[from...]))
        }
        return (.none, [])
    }

    private static func isName(_ word: Word) -> Bool {
        !notNames.contains(word.lower) && word.text.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
    }

    private static let connectors: [[String]] = [
        ["with", "the", "message"], ["with", "the", "body"], ["with", "message"], ["with", "body"],
        ["telling", "him"], ["telling", "her"], ["telling", "them"], ["tell", "him"], ["tell", "her"], ["tell", "them"],
        ["that", "says"], ["the", "message"], ["to", "say"],
        ["and"], ["saying"], ["says"], ["say"], ["that"], ["telling"], ["tell"], ["message"], ["body"],
    ]

    private static func stripConnectors(_ words: [Word]) -> [Word] {
        var rest = words[...]
        var changed = true
        while changed, !rest.isEmpty {
            changed = false
            for connector in connectors where rest.count >= connector.count
                && rest.prefix(connector.count).map(\.lower) == connector {
                rest = rest.dropFirst(connector.count)
                changed = true
                break
            }
        }
        return Array(rest)
    }
}
