//
//  ConsentAnswer.swift
//  LocalBrainKit
//
//  Reads a spoken answer to the consent card. Only a short, whole utterance
//  counts, so "yes but what about the other one" is not a yes.
//

import Foundation

public enum ConsentAnswer: Equatable, Sendable {
    case yes, no

    private static let yesPhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "do it", "play it", "yes please",
    ]
    private static let noPhrases: Set<String> = [
        "no", "nope", "don't", "dont", "do not", "stop", "cancel", "wait", "never mind", "no thanks",
    ]

    public static func parse(_ transcript: String) -> ConsentAnswer? {
        let words = transcript.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .map { $0.isLetter || $0 == "'" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
        guard !words.isEmpty, words.count <= 4 else { return nil }
        let phrase = words.joined(separator: " ")
        if yesPhrases.contains(phrase) { return .yes }
        if noPhrases.contains(phrase) { return .no }
        return nil
    }
}
