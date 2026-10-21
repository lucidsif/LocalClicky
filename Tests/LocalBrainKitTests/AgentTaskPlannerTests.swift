import XCTest
@testable import LocalBrainKit

final class AgentTaskPlannerTests: XCTestCase {
    private func query(_ words: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case .play(let request)? = AgentTaskPlanner.mediaIntent(from: words) else { return nil }
        return request.query
    }

    func testPhrasingsThatNameAVideo() {
        let phrasings = [
            "go to youtube and play lucid dreams",
            "open youtube and play lucid dreams",
            "play lucid dreams on youtube",
            "on youtube play lucid dreams",
            "can you play lucid dreams on youtube",
            "youtube play lucid dreams",
            "Go to YouTube and play lucid dreams, please.",
            "go to you tube and play lucid dreams",
            "watch lucid dreams on youtube",
            "put on lucid dreams on youtube",
            "start playing lucid dreams on youtube",
        ]
        for words in phrasings {
            XCTAssertEqual(query(words), "lucid dreams", words)
        }
    }

    private func request(_ words: String) -> MediaRequest? {
        guard case .play(let request)? = AgentTaskPlanner.mediaIntent(from: words) else { return nil }
        return request
    }

    func testARequestIsInTheBackgroundByDefault() {
        for words in ["go to youtube and play lucid dreams", "play lucid dreams on youtube", "watch lucid dreams on youtube"] {
            XCTAssertEqual(request(words)?.foreground, false, words)
        }
        XCTAssertFalse(MediaRequest(query: "a", searchURL: "b", domainLock: "c").foreground)
    }

    func testEachForegroundPhraseAsksForTheForegroundAndLeavesACleanQuery() {
        let phrasings = [
            "play lucid dreams on youtube in the foreground",
            "play lucid dreams on youtube in foreground",
            "play lucid dreams on youtube foreground",
            "in the foreground play lucid dreams on youtube",
            "go to youtube and play lucid dreams in front",
            "go to youtube and play lucid dreams to the front",
            "bring chrome up and play lucid dreams on youtube",
            "go to youtube and play lucid dreams and bring it up",
            "play lucid dreams on youtube where i can see it",
            "play lucid dreams on youtube so i can see it",
            "show me and play lucid dreams on youtube",
            "play lucid dreams on youtube and show me",
            "Show me, play lucid dreams on youtube.",
        ]
        for words in phrasings {
            let found = request(words)
            XCTAssertEqual(found?.query, "lucid dreams", words)
            XCTAssertEqual(found?.foreground, true, words)
            XCTAssertEqual(found?.searchURL, BrowserCommandPlanner.youtubeSearchURL(query: "lucid dreams"), words)
        }
    }

    func testShowMeInsideATitleOrWithoutAPlayVerbIsNotForeground() {
        XCTAssertEqual(request("play show me the way on youtube")?.foreground, false)
        XCTAssertEqual(request("play show me the way on youtube")?.query, "show me the way")
        XCTAssertNil(AgentTaskPlanner.mediaIntent(from: "show me lucid dreams on youtube"))
    }

    func testAForegroundPhraseWithoutAVideoNameStillNeedsAQuery() {
        XCTAssertEqual(AgentTaskPlanner.mediaIntent(from: "play a video on youtube in the foreground"), .needsQuery)
    }

    func testRequestCarriesTheSearchURLAndDomainLock() {
        guard case .play(let request)? = AgentTaskPlanner.mediaIntent(from: "play lucid dreams on youtube") else {
            return XCTFail("expected a play intent")
        }
        XCTAssertEqual(request.searchURL, BrowserCommandPlanner.youtubeSearchURL(query: "lucid dreams"))
        XCTAssertEqual(request.domainLock, "youtube.com")
    }

    func testFillerIsStripped() {
        XCTAssertEqual(query("play me the song despacito on youtube"), "despacito")
        XCTAssertEqual(query("play the video despacito on youtube"), "despacito")
        XCTAssertEqual(query("play a video of cats on youtube"), "cats")
        XCTAssertEqual(query("play a video called cats on youtube"), "cats")
        XCTAssertEqual(query("play the music video for despacito on youtube"), "despacito")
        XCTAssertEqual(query("play despacito on youtube please"), "despacito")
        XCTAssertEqual(query("play despacito on youtube for me"), "despacito")
        XCTAssertEqual(query("play despacito video on youtube"), "despacito")
        XCTAssertEqual(query("play despacito for me please on youtube"), "despacito")
    }

    func testAnApostropheInTheTitleSurvives() {
        XCTAssertEqual(query("play don't stop me now on youtube"), "don't stop me now")
    }

    func testGenericOrEmptyQueriesNeedAQuery() {
        for words in ["open youtube and play a video", "play something on youtube", "play anything on youtube",
                      "play a song on youtube", "play music on youtube", "play videos on youtube",
                      "go to youtube and play", "play the video on youtube"] {
            XCTAssertEqual(AgentTaskPlanner.mediaIntent(from: words), .needsQuery, words)
        }
    }

    func testWatchWithoutAVideoNameIsNotARequest() {
        for words in ["watch youtube", "watch a video on youtube", "go to youtube and watch something"] {
            XCTAssertNil(AgentTaskPlanner.mediaIntent(from: words), words)
        }
    }

    func testWatchWithAVideoNameStillPlays() {
        XCTAssertEqual(query("watch lucid dreams on youtube"), "lucid dreams")
        XCTAssertEqual(query("go to youtube and watch lucid dreams"), "lucid dreams")
    }

    func testTalkAboutHabitsIsNotARequest() {
        for words in ["i watch youtube a lot", "we play youtube videos at night", "they watch cats on youtube",
                      "she plays guitar and he play youtube sometimes"] {
            XCTAssertNil(AgentTaskPlanner.mediaIntent(from: words), words)
        }
    }

    func testYouBeforeTheVerbIsStillARequest() {
        XCTAssertEqual(query("can you play lucid dreams on youtube"), "lucid dreams")
        XCTAssertEqual(query("can you watch lucid dreams on youtube"), "lucid dreams")
    }

    func testDoesNotFireWithoutBothAPlayVerbAndYouTube() {
        for words in ["play despacito on spotify", "open youtube", "search youtube for cats",
                      "play the video", "go to youtube", "what is youtube", "show me a youtube playlist",
                      "i like to stop playing games"] {
            XCTAssertNil(AgentTaskPlanner.mediaIntent(from: words), words)
        }
    }

    // MARK: - play requests that do not name the site

    func testRequestFramesWithoutYouTubeNameTheVideo() {
        let phrasings = [
            "I want you to play lucid dreams",
            "can you play lucid dreams",
            "could you play lucid dreams",
            "would you play lucid dreams",
            "please play lucid dreams",
            "play lucid dreams please",
            "play lucid dreams for me",
            "I'd like you to play lucid dreams",
            "I would like you to play lucid dreams",
            "hey clicky, can you play lucid dreams",
            "can you please play lucid dreams",
        ]
        for words in phrasings {
            XCTAssertEqual(query(words), "lucid dreams", words)
        }
    }

    func testTheRealTranscriptKeepsTheTitleWordsAndDropsTheTrailingSong() {
        XCTAssertEqual(query("I want you to play the Backstreet Boys. I want it that Way song."),
                       "backstreet boys i want it that way")
        let found = request("I want you to play the Backstreet Boys. I want it that Way song.")
        XCTAssertEqual(found?.searchURL, BrowserCommandPlanner.youtubeSearchURL(query: "backstreet boys i want it that way"))
        XCTAssertEqual(found?.foreground, false)
    }

    func testTrailingSongVideoAndSiteWordsAreStripped() {
        XCTAssertEqual(query("play despacito song on youtube"), "despacito")
        XCTAssertEqual(query("can you play despacito the song"), "despacito")
        XCTAssertEqual(query("can you play the song despacito"), "despacito")
        XCTAssertEqual(query("please play despacito video"), "despacito")
        XCTAssertEqual(query("can you play despacito song on youtube"), "despacito")
        XCTAssertEqual(query("play the beatles on youtube"), "beatles")
    }

    func testARequestFrameWithoutAVideoNameIsNoRequest() {
        for words in ["can you play", "can you play the video", "please play a song", "can you play some music",
                      "play something for me"] {
            XCTAssertNil(AgentTaskPlanner.mediaIntent(from: words), words)
        }
    }

    func testPronounGuardAndOtherServicesStayOut() {
        for words in ["i play guitar", "we played football", "they watch youtube a lot", "i play lucid dreams for me",
                      "can you play lucid dreams on netflix", "can you play lucid dreams on apple music",
                      "play lucid dreams", "can you watch lucid dreams", "i want you to put on a jacket",
                      "let's play a game", "the play was good"] {
            XCTAssertNil(AgentTaskPlanner.mediaIntent(from: words), words)
        }
    }
}
