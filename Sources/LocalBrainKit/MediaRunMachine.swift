//
//  MediaRunMachine.swift
//  LocalBrainKit
//
//  The state machine for one "play a video on youtube" run. Pure: the app feeds it
//  what it observed (a page loaded, a link found, the user said yes, the video is
//  playing) and acts on the state it returns. It owns every stop condition, so the
//  app has no loop of its own that could run away.
//
//  A run starts by reading youtube's results straight from the search page (`searching`):
//  with a result it asks about that video (`askingDirect`) and only after the yes opens its
//  watch page (`openingVideo`). Without one it falls back to the page path: open the results
//  page in Chrome (`opening`), read its links (`locating`), ask, press. Either way it
//  verifies, and a direct open whose page cannot be read ends `opened`, not `playing`.
//

import Foundation

public enum HandoffReason: Equatable, Sendable {
    case noResult, offDomain, targetChanged, didNotOpen, didNotStart, chromeMissing
}

public enum StopReason: Equatable, Sendable {
    case userInput, declined, consentTimeout, pushToTalk, stopButton
}

public enum CapReason: Equatable, Sendable {
    case time, steps
}

public enum MediaRunState: Equatable, Sendable {
    case searching
    case opening
    case locating
    case asking(LinkCandidate)
    case askingDirect(DirectResult)
    case openingVideo(DirectResult)
    case pressing(LinkCandidate)
    case verifying(attempt: Int)
    case playing
    /// The video's page was opened but could not be read, so whether it plays is unknown.
    case opened
    case handoff(HandoffReason)
    case stopped(StopReason)
    case capped(CapReason)

    public var isFinal: Bool {
        switch self {
        case .playing, .opened, .handoff, .stopped, .capped: return true
        case .searching, .opening, .locating, .asking, .askingDirect, .openingVideo, .pressing, .verifying: return false
        }
    }
}

public enum MediaRunEvent: Equatable, Sendable {
    case pageLoaded, pageTimeout, offDomain
    case directFound(DirectResult)
    /// No usable result came from the search page; the run falls back to the page path.
    case directUnavailable
    case videoOpened
    /// After a direct open: the page could not be read as the video's page within the verify window.
    case cannotConfirm
    case located(LinkCandidate)
    case notFound
    case consentYes, consentNo, consentTimeout
    case targetConfirmed, targetChanged
    case pressed(ActionEffect)
    case watchPageWithPause, watchPageNoPause, notWatchPage
    case playPressed(ActionEffect)
    case userInput, pushToTalk, stopButton, timeUp, chromeMissing
}

public enum MediaRunMachine {

    public static func next(_ state: MediaRunState, _ event: MediaRunEvent,
                            caps: AgentCaps, stepsTaken: Int) -> MediaRunState {
        if state.isFinal { return state }
        if event == .timeUp { return .capped(.time) }
        if stepsTaken >= caps.maxSteps { return .capped(.steps) }

        // Keys answer the card and a push-to-talk press starts a spoken answer,
        // so neither stops the run while it asks.
        func answer(yes: MediaRunState) -> MediaRunState {
            switch event {
            case .consentYes: return yes
            case .consentNo: return .stopped(.declined)
            case .consentTimeout: return .stopped(.consentTimeout)
            default: return state
            }
        }
        if case .asking(let link) = state { return answer(yes: .pressing(link)) }
        if case .askingDirect(let result) = state { return answer(yes: .openingVideo(result)) }

        switch event {
        case .userInput: return .stopped(.userInput)
        case .pushToTalk: return .stopped(.pushToTalk)
        case .stopButton: return .stopped(.stopButton)
        case .offDomain: return .handoff(.offDomain)
        default: break
        }

        switch (state, event) {
        case (.searching, .directFound(let result)): return .askingDirect(result)
        case (.searching, .directUnavailable): return .opening
        case (.openingVideo, .videoOpened): return .verifying(attempt: 0)
        case (.openingVideo, .chromeMissing): return .handoff(.chromeMissing)
        case (.verifying, .cannotConfirm): return .opened
        case (.opening, .pageLoaded): return .locating
        case (.opening, .pageTimeout): return .handoff(.didNotOpen)
        case (.opening, .chromeMissing): return .handoff(.chromeMissing)
        case (.locating, .located(let link)): return .asking(link)
        case (.locating, .notFound): return .handoff(.noResult)
        case (.pressing, .targetChanged): return .handoff(.targetChanged)
        case (.pressing, .pressed): return .verifying(attempt: 0)
        case (.verifying, .watchPageWithPause): return .playing
        case (.verifying(let attempt), .watchPageNoPause):
            return attempt < caps.retriesPerRung ? .verifying(attempt: attempt + 1) : .handoff(.didNotStart)
        case (.verifying, .notWatchPage): return .handoff(.didNotOpen)
        default: return state
        }
    }
}
