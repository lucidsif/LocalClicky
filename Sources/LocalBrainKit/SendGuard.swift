//
//  SendGuard.swift
//  LocalBrainKit
//
//  Nothing in LocalClicky sends mail or throws a message away. Two layers keep it that way:
//
//   1. The press backstop. Every press of a page element (AXBackend.press) first asks
//      `mayPress(label:)`. A control whose label is, or starts with, send, send now, schedule send,
//      send later, send and archive, discard, discard draft, delete, archive, report spam or move to
//      trash is refused. The label is normalised first: lowercase letters and digits only, one space
//      between words, bidirectional and other invisible format marks removed, so "Send (⌘Enter)" with
//      U+202A and U+202C around it still reads "send enter".
//   2. The transcript gate. "click send", "press the send button" and the like never become a screen
//      click: the router answers "press send yourself."
//
//  A draft opens through a compose URL or a mailto link, which can only open a draft.
//

import Foundation

public enum SendGuard {
    /// What the companion says when asked to click Send.
    public static let refusalLine = "press send yourself."

    /// Normalised labels that are never pressed, whole or as the start of a longer label.
    static let blockedLabels: [String] = [
        "send", "send now", "schedule send", "send later", "send and archive",
        "discard", "discard draft", "delete", "archive", "report spam", "move to trash",
    ]

    /// Lowercase letters and digits, single spaces, invisible format characters gone.
    public static func normalize(_ label: String) -> String {
        let visible = label.unicodeScalars.filter { $0.properties.generalCategory != .format }
        var words: [String] = []
        var current = ""
        for scalar in String(String.UnicodeScalarView(visible)).lowercased().unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }

    /// False for a control that sends or discards.
    public static func mayPress(label: String) -> Bool {
        let name = normalize(label)
        guard !name.isEmpty else { return true }
        return !blockedLabels.contains { name == $0 || name.hasPrefix($0 + " ") }
    }

    private static let sendTarget = try! NSRegularExpression(
        pattern: #"\b(?:click|press|tap|hit|select|choose|double[- ]click)\s+(?:on\s+)?(?:the\s+|that\s+|this\s+|my\s+)?(?:big\s+|blue\s+|green\s+)?send\b"#)

    /// True when the words tell the companion to click or press Send. Used with the router's click detection.
    public static func clickTargetsSend(_ transcript: String) -> Bool {
        let text = transcript.lowercased().replacingOccurrences(of: "-", with: " ")
        return sendTarget.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
