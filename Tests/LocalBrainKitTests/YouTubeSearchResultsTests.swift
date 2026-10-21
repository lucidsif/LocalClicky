import XCTest
@testable import LocalBrainKit

// The fixtures are small and written by hand to match the shape of the search page's data
// (itemSectionRenderer contents holding videoRenderer objects). No real YouTube HTML is committed.
final class YouTubeSearchResultsTests: XCTestCase {

    private func video(_ id: String, _ title: String, extra: String = "") -> String {
        """
        {"videoRenderer": {"videoId": "\(id)", "title": {"runs": [{"text": "\(title)"}]}, "thumbnailOverlays": [{"thumbnailOverlayTimeStatusRenderer": {"style": "DEFAULT", "text": {"simpleText": "3:33"}}}]\(extra)}}
        """
    }

    private func page(_ items: [String], before: String = "", after: String = "") -> String {
        """
        <html><head><title>query - YouTube</title></head><body><script nonce="x">\(before)</script>
        <script nonce="y">var ytInitialData = {"contents": {"twoColumnSearchResultsRenderer": {"primaryContents": {"sectionListRenderer": {"contents": [{"itemSectionRenderer": {"contents": [\(items.joined(separator: ","))]}}]}}}}, "note": "a } brace and a \\" quote in a string"};</script>
        <script>\(after)</script></body></html>
        """
    }

    func testNormalListKeepsPageOrderAndBuildsWatchURLs() {
        let html = page([video("4fndeDfaWCg", "Backstreet Boys - I Want It That Way (Official HD Video)"),
                         video("AAAAAAAAAAA", "Second"), video("BBBBBBBBBBB", "Third")])
        let results = YouTubeSearchResults.parse(html: html)
        XCTAssertEqual(results.map(\.videoID), ["4fndeDfaWCg", "AAAAAAAAAAA", "BBBBBBBBBBB"])
        XCTAssertEqual(results.first?.title, "Backstreet Boys - I Want It That Way (Official HD Video)")
        XCTAssertEqual(results.first?.watchURL, "https://www.youtube.com/watch?v=4fndeDfaWCg")
    }

    func testTitleRunsAreJoinedAndSimpleTextIsAccepted() {
        let runs = #"{"videoRenderer": {"videoId": "AAAAAAAAAAA", "title": {"runs": [{"text": "Lucid "}, {"text": "Dreams"}]}}}"#
        let simple = #"{"videoRenderer": {"videoId": "BBBBBBBBBBB", "title": {"simpleText": "  Plain title  "}}}"#
        let results = YouTubeSearchResults.parse(html: page([runs, simple]))
        XCTAssertEqual(results.map(\.title), ["Lucid Dreams", "Plain title"])
    }

    func testShortsAreSkippedByEndpointAndByAddress() {
        let reel = video("SSSSSSSSSS1", "Reel", extra: #", "navigationEndpoint": {"reelWatchEndpoint": {"videoId": "SSSSSSSSSS1"}}"#)
        let byURL = video("SSSSSSSSSS2", "By url", extra: #", "navigationEndpoint": {"commandMetadata": {"webCommandMetadata": {"url": "/shorts/SSSSSSSSSS2"}}}"#)
        let normal = video("NNNNNNNNNN1", "Normal", extra: #", "navigationEndpoint": {"commandMetadata": {"webCommandMetadata": {"url": "/watch?v=NNNNNNNNNN1"}}}"#)
        XCTAssertEqual(YouTubeSearchResults.parse(html: page([reel, byURL, normal])).map(\.videoID), ["NNNNNNNNNN1"])
    }

    func testLiveAndUpcomingAreSkipped() {
        let liveBadge = video("LLLLLLLLLL1", "Live badge", extra: #", "badges": [{"metadataBadgeRenderer": {"style": "BADGE_STYLE_TYPE_LIVE_NOW", "label": "LIVE"}}]"#)
        let liveLabel = video("LLLLLLLLLL2", "Live label", extra: #", "badges": [{"metadataBadgeRenderer": {"label": "Live"}}]"#)
        let liveOverlay = #"{"videoRenderer": {"videoId": "LLLLLLLLLL3", "title": {"simpleText": "Live overlay"}, "thumbnailOverlays": [{"thumbnailOverlayTimeStatusRenderer": {"style": "LIVE"}}]}}"#
        let upcoming = video("UUUUUUUUUU1", "Upcoming", extra: #", "upcomingEventData": {"startTime": "1"}"#)
        let normal = video("NNNNNNNNNN1", "Normal")
        XCTAssertEqual(YouTubeSearchResults.parse(html: page([liveBadge, liveLabel, liveOverlay, upcoming, normal])).map(\.videoID),
                       ["NNNNNNNNNN1"])
    }

    func testEntriesWithoutAUsableIdOrTitleAreSkipped() {
        let noID = #"{"videoRenderer": {"title": {"simpleText": "No id"}}}"#
        let emptyID = #"{"videoRenderer": {"videoId": "", "title": {"simpleText": "Empty id"}}}"#
        let badID = #"{"videoRenderer": {"videoId": "abc&evil=1&&&", "title": {"simpleText": "Odd id"}}}"#
        let shortID = #"{"videoRenderer": {"videoId": "abc", "title": {"simpleText": "Short id"}}}"#
        let noTitle = #"{"videoRenderer": {"videoId": "TTTTTTTTTTT"}}"#
        let blankTitle = #"{"videoRenderer": {"videoId": "TTTTTTTTTT2", "title": {"runs": [{"text": "  "}]}}}"#
        let ok = video("OOOOOOOOOOO", "Fine")
        XCTAssertEqual(YouTubeSearchResults.parse(html: page([noID, emptyID, badID, shortID, noTitle, blankTitle, ok])).map(\.videoID),
                       ["OOOOOOOOOOO"])
    }

    func testOtherRenderersAndDuplicatesAreIgnored() {
        let playlist = #"{"playlistRenderer": {"playlistId": "PL1", "title": {"simpleText": "A playlist"}}}"#
        let channel = #"{"channelRenderer": {"channelId": "UC1"}}"#
        let html = page([playlist, video("AAAAAAAAAAA", "First"), channel, video("AAAAAAAAAAA", "First again")])
        XCTAssertEqual(YouTubeSearchResults.parse(html: html).map(\.title), ["First"])
    }

    func testBracesAndQuotesInsideStringsDoNotEndTheObjectEarly() {
        // The fixture's "note" string holds a brace and an escaped quote, and a video follows it in the data.
        let html = """
        <script>var ytInitialData = {"note": "}\\" {", "list": [\(video("AAAAAAAAAAA", "After the note"))]};</script>
        """
        XCTAssertEqual(YouTubeSearchResults.parse(html: html).map(\.title), ["After the note"])
    }

    func testMissingMalformedAndTruncatedDataGiveNothing() {
        XCTAssertEqual(YouTubeSearchResults.parse(html: ""), [])
        XCTAssertEqual(YouTubeSearchResults.parse(html: "<html><body>no data here</body></html>"), [])
        XCTAssertEqual(YouTubeSearchResults.parse(html: "<script>var ytInitialData = {\"a\": [1, 2,};</script>"), [])
        XCTAssertEqual(YouTubeSearchResults.parse(html: "<script>var ytInitialData = {\"a\": {\"b\": 1}"), [])
        XCTAssertEqual(YouTubeSearchResults.parse(html: "<script>var ytInitialData = ;</script>"), [])
        XCTAssertEqual(YouTubeSearchResults.parse(html: "<script>var ytInitialData = [1, 2];</script>"), [])
        XCTAssertEqual(YouTubeSearchResults.parse(html: "<script>var ytInitialData = {\"videoRenderer\": 5};</script>"), [])
    }

    func testNonASCIITitlesSurviveBeforeAndAfterTheMarker() {
        let html = "<p>caf\u{00E9} \u{1F3B5}</p>" + page([video("AAAAAAAAAAA", "Caf\u{00E9} \u{1F3B5} Mix")])
        XCTAssertEqual(YouTubeSearchResults.parse(html: html).map(\.title), ["Caf\u{00E9} \u{1F3B5} Mix"])
    }

    func testConsentLinkCarriesTheTitleAndTheWatchAddress() {
        let result = DirectResult(videoID: "4fndeDfaWCg", title: "A title")
        XCTAssertEqual(result.consentLink.label, "A title")
        XCTAssertEqual(result.consentLink.url, "https://www.youtube.com/watch?v=4fndeDfaWCg")
    }
}
