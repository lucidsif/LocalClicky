import XCTest
@testable import LocalBrainKit

final class MediaPlaybackCheckTests: XCTestCase {
    func testWatchPage() {
        XCTAssertTrue(MediaPlaybackCheck.isWatchPage(url: "https://www.youtube.com/watch?v=abc"))
        XCTAssertTrue(MediaPlaybackCheck.isWatchPage(url: "https://m.youtube.com/watch?v=abc"))
        XCTAssertTrue(MediaPlaybackCheck.isWatchPage(url: "https://youtube.com/watch?v=abc"))
        XCTAssertFalse(MediaPlaybackCheck.isWatchPage(url: "https://www.youtube.com/results?search_query=x"))
        XCTAssertFalse(MediaPlaybackCheck.isWatchPage(url: "https://www.youtube.com/shorts/abc"))
        XCTAssertFalse(MediaPlaybackCheck.isWatchPage(url: "https://example.com/watch?v=abc"))
        XCTAssertFalse(MediaPlaybackCheck.isWatchPage(url: nil))
    }

    func testOnDomain() {
        XCTAssertTrue(MediaPlaybackCheck.isOnDomain(url: "https://youtube.com/", domainLock: "youtube.com"))
        XCTAssertTrue(MediaPlaybackCheck.isOnDomain(url: "https://www.youtube.com/watch?v=a", domainLock: "youtube.com"))
        XCTAssertFalse(MediaPlaybackCheck.isOnDomain(url: "https://notyoutube.com/", domainLock: "youtube.com"))
        XCTAssertFalse(MediaPlaybackCheck.isOnDomain(url: "https://youtube.com.evil.com/", domainLock: "youtube.com"))
        XCTAssertFalse(MediaPlaybackCheck.isOnDomain(url: nil, domainLock: "youtube.com"))
    }

    func testPauseButton() {
        XCTAssertTrue(MediaPlaybackCheck.pauseButtonPresent(buttonLabels: ["Share", "Pause (k)"]))
        XCTAssertTrue(MediaPlaybackCheck.pauseButtonPresent(buttonLabels: [" PAUSE "]))
        XCTAssertTrue(MediaPlaybackCheck.pauseButtonPresent(buttonLabels: ["Pause keyboard shortcut k"]))
        XCTAssertFalse(MediaPlaybackCheck.pauseButtonPresent(buttonLabels: ["Play (k)", "Pausefoo", "Unpause"]))
        XCTAssertFalse(MediaPlaybackCheck.pauseButtonPresent(buttonLabels: []))
    }

    func testPlayButtonIndex() {
        XCTAssertEqual(MediaPlaybackCheck.playButtonIndex(buttonLabels: ["Share", "Play (k)"]), 1)
        XCTAssertEqual(MediaPlaybackCheck.playButtonIndex(buttonLabels: ["play"]), 0)
        XCTAssertEqual(MediaPlaybackCheck.playButtonIndex(buttonLabels: ["Play keyboard shortcut k"]), 0)
        XCTAssertNil(MediaPlaybackCheck.playButtonIndex(buttonLabels: ["Play all", "Playlist", "Play next", "Pause (k)"]))
        XCTAssertNil(MediaPlaybackCheck.playButtonIndex(buttonLabels: []))
    }

    func testVideoIDOfAWatchAddress() {
        XCTAssertEqual(MediaPlaybackCheck.videoID(inWatchURL: "https://www.youtube.com/watch?v=4fndeDfaWCg&t=3"), "4fndeDfaWCg")
        XCTAssertNil(MediaPlaybackCheck.videoID(inWatchURL: "https://www.youtube.com/results?search_query=x"))
        XCTAssertNil(MediaPlaybackCheck.videoID(inWatchURL: "https://www.youtube.com/watch"))
        XCTAssertNil(MediaPlaybackCheck.videoID(inWatchURL: nil))
    }
}
