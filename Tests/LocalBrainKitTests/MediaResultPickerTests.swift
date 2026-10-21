import CoreGraphics
import XCTest
@testable import LocalBrainKit

// The fixtures below are synthetic, not captured from a real page; replace them with a
// captured fixture after the first real run.
final class MediaResultPickerTests: XCTestCase {
    private func link(_ label: String, _ url: String) -> LinkCandidate {
        LinkCandidate(label: label, url: url, frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    }

    private let ad = LinkCandidate(label: "Buy headphones", url: "https://www.googleadservices.com/pagead/aclk?x=1",
                                   frame: .zero)

    func testAdIsSkipped() {
        let links = [ad, link("Lucid Dreams (Official Video)", "https://www.youtube.com/watch?v=abc123")]
        XCTAssertEqual(MediaResultPicker.firstResult(in: links, query: "lucid dreams")?.url,
                       "https://www.youtube.com/watch?v=abc123")
    }

    func testShortsPlaylistsAndChannelsAreSkipped() {
        let links = [
            link("A short", "https://www.youtube.com/shorts/abc123"),
            link("A playlist", "https://www.youtube.com/watch?v=pl1&list=PL123"),
            link("Juice WRLD", "https://www.youtube.com/@juicewrld"),
            link("The real one", "https://www.youtube.com/watch?v=real1"),
        ]
        XCTAssertEqual(MediaResultPicker.firstResult(in: links, query: "x")?.label, "The real one")
    }

    func testThumbnailWithADurationLabelLosesToTheTitledLink() {
        let url = "https://www.youtube.com/watch?v=abc123"
        for duration in ["3:59", "1:02:03"] {
            let links = [link(duration, url), link("Lucid Dreams", url)]
            XCTAssertEqual(MediaResultPicker.firstResult(in: links, query: "lucid")?.label, "Lucid Dreams", duration)
        }
    }

    func testControlLabelsAreNotTitles() {
        for label in ["Now playing", "watch later", "Add to queue", "More actions", "  ", ""] {
            XCTAssertFalse(MediaResultPicker.isVideoResult(link(label, "https://www.youtube.com/watch?v=abc")), label)
        }
    }

    func testVideoResultNeedsAWatchURLWithAVideoId() {
        XCTAssertTrue(MediaResultPicker.isVideoResult(link("T", "https://m.youtube.com/watch?v=abc")))
        XCTAssertTrue(MediaResultPicker.isVideoResult(link("T", "https://youtube.com/watch?v=abc")))
        XCTAssertFalse(MediaResultPicker.isVideoResult(link("T", "https://www.youtube.com/watch")))
        XCTAssertFalse(MediaResultPicker.isVideoResult(link("T", "https://www.youtube.com/watch/x?v=abc")))
        XCTAssertFalse(MediaResultPicker.isVideoResult(link("T", "https://evil.com/watch?v=abc")))
        XCTAssertFalse(MediaResultPicker.isVideoResult(link("T", "not a url")))
    }

    func testPrefersAResultSharingAQueryWord() {
        let links = [link("Unrelated cooking show", "https://www.youtube.com/watch?v=one"),
                     link("Juice WRLD - Lucid Dreams", "https://www.youtube.com/watch?v=two")]
        XCTAssertEqual(MediaResultPicker.firstResult(in: links, query: "Lucid dreams!")?.url,
                       "https://www.youtube.com/watch?v=two")
    }

    func testShortQueryWordsDoNotCount() {
        let links = [link("First", "https://www.youtube.com/watch?v=one"),
                     link("Go to it", "https://www.youtube.com/watch?v=two")]
        XCTAssertEqual(MediaResultPicker.firstResult(in: links, query: "go to")?.url,
                       "https://www.youtube.com/watch?v=one")
    }

    func testFallsBackToTheFirstVideoWhenNoWordIsShared() {
        let links = [ad, link("First", "https://www.youtube.com/watch?v=one"),
                     link("Second", "https://www.youtube.com/watch?v=two")]
        XCTAssertEqual(MediaResultPicker.firstResult(in: links, query: "zebra")?.url,
                       "https://www.youtube.com/watch?v=one")
    }

    func testNilWhenThereIsNoVideoResult() {
        XCTAssertNil(MediaResultPicker.firstResult(in: [], query: "x"))
        XCTAssertNil(MediaResultPicker.firstResult(in: [ad], query: "x"))
    }

    // MARK: - direct results

    func testDirectResultWithTheMostSharedWordsWinsAndTheEarliestOnATie() {
        let results = [
            DirectResult(videoID: "AAAAAAAAAAA", title: "Lucid Dreams reaction"),
            DirectResult(videoID: "BBBBBBBBBBB", title: "Juice WRLD - Lucid Dreams (Forget Me)"),
            DirectResult(videoID: "CCCCCCCCCCC", title: "Juice WRLD - Lucid Dreams (Official Video)"),
        ]
        XCTAssertEqual(MediaResultPicker.bestResult(in: results, query: "juice wrld lucid dreams")?.videoID, "BBBBBBBBBBB")
    }

    func testDirectResultsWithNoSharedWordGiveTheFirstAndNoneGivesNil() {
        let results = [DirectResult(videoID: "AAAAAAAAAAA", title: "One"), DirectResult(videoID: "BBBBBBBBBBB", title: "Two")]
        XCTAssertEqual(MediaResultPicker.bestResult(in: results, query: "backstreet boys")?.videoID, "AAAAAAAAAAA")
        XCTAssertNil(MediaResultPicker.bestResult(in: [], query: "x"))
    }

    func testTheRealExampleChoosesTheOfficialVideo() {
        let results = [
            DirectResult(videoID: "4fndeDfaWCg", title: "Backstreet Boys - I Want It That Way (Official HD Video)"),
            DirectResult(videoID: "BBBBBBBBBBB", title: "I Want It That Way - cover"),
        ]
        XCTAssertEqual(MediaResultPicker.bestResult(in: results, query: "backstreet boys i want it that way")?.videoID,
                       "4fndeDfaWCg")
    }
}
