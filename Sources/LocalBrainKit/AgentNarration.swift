//
//  AgentNarration.swift
//  LocalBrainKit
//
//  What the assistant says and shows at each state of a run. Fixed templates only:
//  the one variable part is the user's own query, and page text is never read out. The
//  one exception is the question before a direct open, which names the video it found
//  (its title, from the search page), because the yes is for that exact video.
//

import Foundation

public enum AgentNarration {

    public static let needsQueryLine = "which video should i play on youtube?"

    /// The longest a title is spoken; a longer one is cut at a word.
    public static let spokenTitleMaxCharacters = 100

    /// A video title made fit to read out: control characters and runs of spaces collapsed, cut at a word.
    public static func spokenTitle(_ title: String) -> String {
        let flattened = title.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let collapsed = flattened.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > spokenTitleMaxCharacters else { return collapsed }
        let cut = String(collapsed.prefix(spokenTitleMaxCharacters))
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) }
        return cut
    }

    /// `foreground` only changes the opening line: a background run says so, since nothing
    /// appears on screen to show it. `keyboardAnswers` only changes the asking line: it names
    /// Return only when the consent card really has the keyboard.
    public static func line(for state: MediaRunState, query: String, caps: AgentCaps = AgentCaps(),
                            foreground: Bool = false, keyboardAnswers: Bool = true) -> String {
        let answerHint = "say yes, or press \(keyboardAnswers ? "return" : "the yes button")."
        switch state {
        case .searching: return "looking up \(query) on youtube."
        case .opening: return "opening youtube for \(query)\(foreground ? "" : " in the background")."
        case .locating: return "reading the page."
        case .asking:
            return "should i play the first result for \(query)? \(answerHint)"
        case .askingDirect(let result):
            return "should i play \(spokenTitle(result.title)) on youtube? \(answerHint)"
        case .openingVideo: return "opening the video\(foreground ? "" : " in the background")."
        case .pressing: return "pressing the first result."
        case .verifying: return "checking that it plays."
        case .playing: return "playing \(query) on youtube."
        case .opened: return "i opened the video for \(query) in chrome, but i can't tell whether it started."
        case .handoff(let reason):
            switch reason {
            case .noResult: return "i couldn't find a video for \(query) on the page."
            case .offDomain: return "the page left youtube, so i stopped."
            case .targetChanged: return "the page changed before i pressed, so i stopped. nothing was pressed."
            case .didNotOpen: return "the video page did not open. nothing else was pressed."
            case .didNotStart: return "the video is open but did not start. press play."
            case .chromeMissing: return "i need google chrome for this, and i can't find it."
            }
        case .stopped(let reason):
            switch reason {
            case .userInput: return "stopped, because you used the mouse or keyboard."
            case .declined: return "okay, i won't play it."
            case .consentTimeout: return "no answer, so i didn't play it."
            case .pushToTalk, .stopButton: return "stopped."
            }
        case .capped(let reason):
            switch reason {
            case .time: return "stopped after \(Int(caps.wallClockSeconds)) seconds. the video did not play."
            case .steps: return "stopped at my step limit. the video did not play."
            }
        }
    }

    /// The short label for a step list on the card.
    public static func stepTitle(for state: MediaRunState) -> String {
        switch state {
        case .searching: return "Looking up the video"
        case .opening: return "Opening YouTube"
        case .locating: return "Reading the page"
        case .asking, .askingDirect: return "Waiting for your yes"
        case .openingVideo: return "Opening the video"
        case .pressing: return "Pressing the first result"
        case .verifying: return "Checking that it plays"
        case .playing: return "Playing"
        case .opened: return "Opened"
        case .handoff, .stopped, .capped: return "Stopped"
        }
    }
}
