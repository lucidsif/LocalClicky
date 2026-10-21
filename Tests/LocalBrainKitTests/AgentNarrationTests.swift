import XCTest
@testable import LocalBrainKit

final class AgentNarrationTests: XCTestCase {
    private let link = LinkCandidate(label: "Page title that must never be spoken", url: "https://www.youtube.com/watch?v=a", frame: .zero)

    private let result = DirectResult(videoID: "4fndeDfaWCg", title: "Backstreet Boys - I Want It That Way (Official HD Video)")

    private var states: [MediaRunState] {
        [.searching, .opening, .locating, .asking(link), .openingVideo(result), .pressing(link), .verifying(attempt: 0),
         .playing, .opened,
         .handoff(.noResult), .handoff(.offDomain), .handoff(.targetChanged), .handoff(.didNotOpen),
         .handoff(.didNotStart), .handoff(.chromeMissing),
         .stopped(.userInput), .stopped(.declined), .stopped(.consentTimeout), .stopped(.pushToTalk), .stopped(.stopButton),
         .capped(.time), .capped(.steps)]
    }

    func testLines() {
        XCTAssertEqual(AgentNarration.line(for: .opening, query: "cats"), "opening youtube for cats in the background.")
        XCTAssertEqual(AgentNarration.line(for: .opening, query: "cats", foreground: false),
                       "opening youtube for cats in the background.")
        XCTAssertEqual(AgentNarration.line(for: .opening, query: "cats", foreground: true), "opening youtube for cats.")
        XCTAssertEqual(AgentNarration.line(for: .asking(link), query: "cats"),
                       "should i play the first result for cats? say yes, or press return.")
        XCTAssertEqual(AgentNarration.line(for: .asking(link), query: "cats", keyboardAnswers: false),
                       "should i play the first result for cats? say yes, or press the yes button.")
        XCTAssertEqual(AgentNarration.line(for: .playing, query: "cats"), "playing cats on youtube.")
        XCTAssertEqual(AgentNarration.line(for: .handoff(.noResult), query: "cats"),
                       "i couldn't find a video for cats on the page.")
        XCTAssertEqual(AgentNarration.line(for: .capped(.time), query: "cats"),
                       "stopped after 45 seconds. the video did not play.")
        XCTAssertEqual(AgentNarration.line(for: .capped(.time), query: "cats", caps: AgentCaps(wallClockSeconds: 30)),
                       "stopped after 30 seconds. the video did not play.")
        XCTAssertEqual(AgentNarration.line(for: .stopped(.pushToTalk), query: "cats"), "stopped.")
        XCTAssertEqual(AgentNarration.line(for: .stopped(.stopButton), query: "cats"), "stopped.")
        XCTAssertEqual(AgentNarration.needsQueryLine, "which video should i play on youtube?")
    }

    func testDirectLines() {
        XCTAssertEqual(AgentNarration.line(for: .searching, query: "cats"), "looking up cats on youtube.")
        XCTAssertEqual(AgentNarration.line(for: .askingDirect(result), query: "cats"),
                       "should i play Backstreet Boys - I Want It That Way (Official HD Video) on youtube? say yes, or press return.")
        XCTAssertEqual(AgentNarration.line(for: .askingDirect(result), query: "cats", keyboardAnswers: false),
                       "should i play Backstreet Boys - I Want It That Way (Official HD Video) on youtube? say yes, or press the yes button.")
        XCTAssertEqual(AgentNarration.line(for: .openingVideo(result), query: "cats"), "opening the video in the background.")
        XCTAssertEqual(AgentNarration.line(for: .openingVideo(result), query: "cats", foreground: true), "opening the video.")
        XCTAssertEqual(AgentNarration.line(for: .opened, query: "cats"),
                       "i opened the video for cats in chrome, but i can't tell whether it started.")
    }

    /// The question before a direct open is the one line that names page text: the title, shortened.
    func testOnlyTheDirectAskingLineCarriesTheTitleAndItIsMadeFitToSpeak() {
        let title = "Marker\n  Title   with\tgaps " + String(repeating: "word ", count: 40)
        let spoken = AgentNarration.spokenTitle(title)
        XCTAssertTrue(spoken.hasPrefix("Marker Title with gaps word"), spoken)
        XCTAssertFalse(spoken.contains("\n") || spoken.contains("\t") || spoken.contains("  "), spoken)
        XCTAssertLessThanOrEqual(spoken.count, AgentNarration.spokenTitleMaxCharacters)
        XCTAssertTrue(spoken.hasSuffix("word"), "cut at a word: \(spoken)")
        XCTAssertEqual(AgentNarration.spokenTitle("Short"), "Short")
        XCTAssertEqual(AgentNarration.spokenTitle(String(repeating: "x", count: 150)).count, 100)
        let marked = DirectResult(videoID: "AAAAAAAAAAA", title: "TITLEMARK")
        for state in states + [.askingDirect(marked)] {
            let carries = AgentNarration.line(for: state, query: "q").contains("TITLEMARK")
            XCTAssertEqual(carries, state == .askingDirect(marked), "\(state)")
        }
    }

    func testStepTitles() {
        XCTAssertEqual(AgentNarration.stepTitle(for: .searching), "Looking up the video")
        XCTAssertEqual(AgentNarration.stepTitle(for: .askingDirect(result)), "Waiting for your yes")
        XCTAssertEqual(AgentNarration.stepTitle(for: .openingVideo(result)), "Opening the video")
        XCTAssertEqual(AgentNarration.stepTitle(for: .opened), "Opened")
        XCTAssertEqual(AgentNarration.stepTitle(for: .opening), "Opening YouTube")
        XCTAssertEqual(AgentNarration.stepTitle(for: .locating), "Reading the page")
        XCTAssertEqual(AgentNarration.stepTitle(for: .asking(link)), "Waiting for your yes")
        XCTAssertEqual(AgentNarration.stepTitle(for: .pressing(link)), "Pressing the first result")
        XCTAssertEqual(AgentNarration.stepTitle(for: .verifying(attempt: 1)), "Checking that it plays")
        XCTAssertEqual(AgentNarration.stepTitle(for: .playing), "Playing")
        XCTAssertEqual(AgentNarration.stepTitle(for: .stopped(.declined)), "Stopped")
    }

    func testNoDashesAndTheQueryIsTheOnlyVariableText() {
        let marker = "QUERYMARK"
        let modes = [(false, true), (false, false), (true, true), (true, false)]
        for state in states {
            for (foreground, keyboardAnswers) in modes {
                let line = AgentNarration.line(for: state, query: marker, foreground: foreground,
                                               keyboardAnswers: keyboardAnswers)
                let titled = AgentNarration.stepTitle(for: state)
                for text in [line, titled, AgentNarration.needsQueryLine] {
                    XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
                }
                // Nothing from the page (the link label or URL) reaches the line.
                XCTAssertFalse(line.contains("must never be spoken") || line.contains("youtube.com/watch"), line)
                // With the query swapped out, the line no longer depends on it.
                XCTAssertEqual(line.replacingOccurrences(of: marker, with: "X"),
                               AgentNarration.line(for: state, query: "X", foreground: foreground,
                                                   keyboardAnswers: keyboardAnswers))
            }
        }
    }
}
