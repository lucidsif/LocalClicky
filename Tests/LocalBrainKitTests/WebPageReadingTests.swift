import XCTest
@testable import LocalBrainKit

final class WebPageReadingTests: XCTestCase {
    func testChromiumFamilyIsRecognisedByBundlePrefix() {
        for id in ["com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
                   "com.brave.Browser", "com.brave.Browser.beta", "com.microsoft.edgemac"] {
            XCTAssertTrue(WebPageReading.isChromiumBrowser(bundleIdentifier: id), id)
        }
        for id in ["com.apple.Safari", "org.mozilla.firefox", "com.google.Keystone", ""] {
            XCTAssertFalse(WebPageReading.isChromiumBrowser(bundleIdentifier: id), id)
        }
        XCTAssertFalse(WebPageReading.isChromiumBrowser(bundleIdentifier: nil))
    }

    func testFastmailGetsTheNudgeButIsNotABrowser() {
        XCTAssertTrue(WebPageReading.needsAssistiveClientNudge(bundleIdentifier: "com.fastmail.mac.Fastmail"))
        XCTAssertFalse(WebPageReading.isChromiumBrowser(bundleIdentifier: "com.fastmail.mac.Fastmail"))
        XCTAssertTrue(WebPageReading.needsAssistiveClientNudge(bundleIdentifier: "com.google.Chrome"))
        XCTAssertFalse(WebPageReading.needsAssistiveClientNudge(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(WebPageReading.needsAssistiveClientNudge(bundleIdentifier: "com.fastmail.mac.Fastmail.helper"))
        XCTAssertFalse(WebPageReading.needsAssistiveClientNudge(bundleIdentifier: nil))
    }

    func testOnlyHttpAndHttpsAreWebURLs() {
        XCTAssertTrue(WebPageReading.isWebURL("https://www.youtube.com/results?search_query=x"))
        XCTAssertTrue(WebPageReading.isWebURL("HTTP://example.com"))
        XCTAssertFalse(WebPageReading.isWebURL("chrome://newtab/"))
        XCTAssertFalse(WebPageReading.isWebURL("about:blank"))
        XCTAssertFalse(WebPageReading.isWebURL(""))
        XCTAssertFalse(WebPageReading.isWebURL(nil))
    }

    func testLabelPrefersTitleThenDescriptionThenChildTexts() {
        XCTAssertEqual(WebPageReading.label(title: " Song ", description: "d", childTexts: ["t"]), "Song")
        XCTAssertEqual(WebPageReading.label(title: "  ", description: "Desc", childTexts: ["t"]), "Desc")
        XCTAssertEqual(WebPageReading.label(title: nil, description: nil, childTexts: ["a", " ", "b"]), "a b")
    }

    func testLabelJoinsAtMostThreeNonBlankChildTexts() {
        XCTAssertEqual(WebPageReading.label(title: nil, description: nil, childTexts: ["a", "b", "", "c", "d"]), "a b c")
    }

    func testLabelIsCutAndEmptyWhenNothingNamesIt() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(WebPageReading.label(title: long, description: nil, childTexts: []).count, 200)
        XCTAssertEqual(WebPageReading.label(title: nil, description: nil, childTexts: []), "")
    }

    func testChildTextsAreNotReadWhenTheElementIsAlreadyNamed() {
        var reads = 0
        _ = WebPageReading.label(title: "Named", description: nil, childTexts: { reads += 1; return ["x"] }())
        XCTAssertEqual(reads, 0)
    }

    func testPreferredWindowIndex() {
        let youtube = "https://www.youtube.com/results?search_query=cats"
        XCTAssertNil(WebPageReading.preferredWindowIndex([]))
        XCTAssertNil(WebPageReading.preferredWindowIndex([(0, nil), (1, "chrome://newtab/"), (2, "")]))
        // The first web window wins when none is on youtube.
        XCTAssertEqual(WebPageReading.preferredWindowIndex([(0, nil), (1, "https://example.com/"), (2, "http://a.org")]), 1)
        // A youtube page, or one on a subdomain, wins over an earlier web window.
        XCTAssertEqual(WebPageReading.preferredWindowIndex([(0, "https://example.com/"), (1, youtube)]), 1)
        XCTAssertEqual(WebPageReading.preferredWindowIndex([(0, "https://example.com/"), (3, "https://m.youtube.com/watch?v=a")]), 3)
        // Among several youtube pages the first is kept, and a lookalike host does not count.
        XCTAssertEqual(WebPageReading.preferredWindowIndex([(0, youtube), (1, youtube)]), 0)
        XCTAssertEqual(WebPageReading.preferredWindowIndex([(0, "https://notyoutube.com/"), (1, "https://example.com/")]), 0)
    }
}
