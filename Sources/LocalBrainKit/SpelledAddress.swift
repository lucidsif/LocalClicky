//
//  SpelledAddress.swift
//  LocalBrainKit
//
//  Finds an email address in dictated words. Speech-to-text gives either a formatted address
//  ("bob@example.com", "bob at example.com") or a spelled one ("b o b at example dot com").
//  A formatted address is tried first, then the spelled form.
//
//  The spelled form starts after the last "to", "tell" or "email" before the "at", and ends at
//  the first top-level-domain word after a "dot". Everything after that span is the message,
//  never part of the address. Spoken words: at, dot / period / point, underscore / under score,
//  dash / hyphen / minus, plus, digits as words (zero to nine), "g mail" / "gee mail" for gmail.
//  Commas and trailing periods are dropped. Nil when no valid address comes out.
//
//  Pure, no model.
//

import Foundation

public enum SpelledAddress {
    /// A found address and the half-open range of tokens (indexes into the input) that spelled it.
    public struct Match: Equatable, Sendable {
        public let address: String
        public let tokenRange: Range<Int>
    }

    /// Words after which a spelled local part starts.
    private static let startMarkers: Set<String> = ["to", "tell", "email", "e-mail", "mail"]

    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "co", "dev", "studio", "edu", "gov", "me", "ai", "app",
    ]

    private static let digitWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    private static let dotWords: Set<String> = ["dot", "period", "point"]

    private static let symbolWords: [String: String] = [
        "dash": "-", "hyphen": "-", "minus": "-", "plus": "+", "underscore": "_",
    ]

    /// Words read after the "at" before giving up.
    private static let maxDomainTokens = 16

    private static let formattedShape = #"^[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}$"#
    private static let domainShape = #"^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}$"#
    private static let localShape = #"^[a-z0-9._%+-]+$"#

    /// The first address in `tokens` (the words of a transcript, lowercase, edge punctuation already
    /// dropped by `clean`), nil when there is none.
    public static func find(in tokens: [String]) -> Match? {
        formatted(in: tokens) ?? spelled(in: tokens)
    }

    /// Convenience for a whole string: the address, nil when none.
    public static func parse(_ spoken: String) -> String? {
        find(in: spoken.split(whereSeparator: \.isWhitespace).map { clean(String($0)) })?.address
    }

    /// A word cleaned of commas, quotes and other edge punctuation and lowercased. A trailing period is
    /// dropped ("com." becomes "com"); dots inside a word stay ("example.com").
    public static func clean(_ word: String) -> String {
        var cleaned = word.lowercased()
        let edge = CharacterSet(charactersIn: ",;:!?\"'()[]<>")
        cleaned = cleaned.trimmingCharacters(in: edge)
        while cleaned.hasSuffix(".") { cleaned.removeLast() }
        return cleaned
    }

    // MARK: - Formatted

    private static func formatted(in tokens: [String]) -> Match? {
        for (index, token) in tokens.enumerated() where token.range(of: formattedShape, options: .regularExpression) != nil {
            return Match(address: token, tokenRange: index..<(index + 1))
        }
        // "bob at example.com": a local part, "at", then a domain with a dot in it.
        guard tokens.count >= 3 else { return nil }
        for index in 1..<(tokens.count - 1) where tokens[index] == "at" {
            let local = tokens[index - 1]
            let domain = tokens[index + 1]
            guard local.range(of: localShape, options: .regularExpression) != nil, !startMarkers.contains(local),
                  domain.range(of: domainShape, options: .regularExpression) != nil else { continue }
            return Match(address: "\(local)@\(domain)", tokenRange: (index - 1)..<(index + 2))
        }
        return nil
    }

    // MARK: - Spelled

    private static func spelled(in tokens: [String]) -> Match? {
        for atIndex in tokens.indices where tokens[atIndex] == "at" {
            guard let domain = spelledDomain(in: tokens, after: atIndex) else { continue }
            let start = (tokens[..<atIndex].lastIndex { startMarkers.contains($0) }).map { $0 + 1 } ?? 0
            guard start < atIndex, let local = spelledPart(tokens[start..<atIndex]),
                  !local.hasPrefix("."), !local.hasSuffix(".") else { continue }
            let address = "\(local)@\(domain.text)"
            guard address.range(of: formattedShape, options: .regularExpression) != nil else { continue }
            return Match(address: address, tokenRange: start..<domain.end)
        }
        return nil
    }

    /// Reads the domain after the "at": words and spelled letters up to the first top-level domain that
    /// follows a "dot", then any further "dot" plus a two-letter country code or known top-level domain
    /// ("example dot co dot uk"). `end` is the index after the last token used.
    private static func spelledDomain(in tokens: [String], after atIndex: Int) -> (text: String, end: Int)? {
        var text = ""
        var index = atIndex + 1
        while index < tokens.count, index - atIndex <= maxDomainTokens {
            let token = tokens[index]
            // A second "at" means the first one was ordinary talk ("meet me at noon").
            if token == "at" { return nil }
            if dotWords.contains(token) {
                guard !text.isEmpty, !text.hasSuffix(".") else { return nil }
                text += "."
                index += 1
                continue
            }
            if text.hasSuffix("."), isTopLevelDomain(token) {
                text += token
                index += 1
                // More labels of the suffix: "co dot uk".
                while index + 1 < tokens.count, dotWords.contains(tokens[index]), isTopLevelDomain(tokens[index + 1]) {
                    text += "." + tokens[index + 1]
                    index += 2
                }
                return (text, index)
            }
            guard let piece = word(token, allowGmailSplit: true, tokens: tokens, index: &index) else { return nil }
            text += piece
        }
        return nil
    }

    private static func isTopLevelDomain(_ token: String) -> Bool {
        topLevelDomains.contains(token) || (token.count == 2 && token.allSatisfy { $0 >= "a" && $0 <= "z" })
    }

    /// The text of one spoken word, advancing `index` past what it used. "gee mail" and "g mail" become
    /// "gmail". Nil for a word that cannot be part of an address.
    private static func word(_ token: String, allowGmailSplit: Bool, tokens: [String], index: inout Int) -> String? {
        if allowGmailSplit, token == "gee" || token == "g", index + 1 < tokens.count, tokens[index + 1] == "mail" {
            index += 2
            return "gmail"
        }
        index += 1
        if let digit = digitWords[token] { return digit }
        if let symbol = symbolWords[token] { return symbol }
        guard token.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        return token
    }

    /// The local part spelled by `tokens`: letters and words joined, "dot" as ".", symbols and digit words.
    private static func spelledPart(_ tokens: ArraySlice<String>) -> String? {
        let all = Array(tokens)
        var text = ""
        var index = 0
        while index < all.count {
            let token = all[index]
            if dotWords.contains(token) { text += "."; index += 1; continue }
            if token == "under", index + 1 < all.count, all[index + 1] == "score" { text += "_"; index += 2; continue }
            if let digit = digitWords[token] { text += digit; index += 1; continue }
            if let symbol = symbolWords[token] { text += symbol; index += 1; continue }
            guard token.range(of: #"^[a-z0-9]+$"#, options: .regularExpression) != nil else { return nil }
            text += token
            index += 1
        }
        return text.isEmpty ? nil : text
    }
}
