import XCTest
@testable import LocalBrainKit

final class CustomSiteRoutingTests: XCTestCase {
    private let address = "http://127.0.0.1:9999/dashboard"
    private lazy var sites = ["my dashboard": address, "me zan": address]

    private func context(_ sites: [String: String] = [:]) -> ConversationRouter.Context {
        ConversationRouter.Context(visionModeSelected: true, screenAvailable: true, previousTurnUsedScreen: false,
                                   hasConversationHistory: false, customSites: sites)
    }

    func testACustomNameOpensItsAddress() {
        for words in ["open my dashboard", "Open My Dashboard", "go to me zan", "pull up my dashboard"] {
            XCTAssertEqual(ConversationRouter.route(transcript: words, context: context(sites)), .browserCommand, words)
            let plan = BrowserCommandPlanner.plan(for: words, customSites: sites)
            XCTAssertEqual(plan.actions.map(\.url), [address], words)
        }
        XCTAssertEqual(BrowserCommandPlanner.plan(for: "open my dashboard", customSites: sites).actions.first?.label, "my dashboard")
    }

    func testAnEmptyTableChangesNothing() {
        for words in ["open my dashboard", "open gmail", "open youtube", "open me zan"] {
            XCTAssertEqual(BrowserCommandPlanner.plan(for: words, customSites: [:]).actions.map(\.url),
                           BrowserCommandPlanner.plan(for: words).actions.map(\.url), words)
        }
        XCTAssertFalse(BrowserCommandPlanner.plan(for: "open my dashboard").isUnderstood)
        XCTAssertNotEqual(ConversationRouter.route(transcript: "open my dashboard", context: context()), .browserCommand)
    }

    func testAnInvalidAddressIsIgnored() {
        let bad = ["my dashboard": "not a url", "me zan": "ftp://example.com/", "notes site": "http://", "  ": "http://127.0.0.1:1/"]
        XCTAssertTrue(CustomSites.entries(from: bad).isEmpty)
        XCTAssertFalse(BrowserCommandPlanner.plan(for: "open my dashboard", customSites: bad).isUnderstood)
        XCTAssertNotEqual(ConversationRouter.route(transcript: "open my dashboard", context: context(bad)), .browserCommand)
        let mixed = bad.merging(["my notes": "https://example.org/notes"]) { a, _ in a }
        XCTAssertEqual(CustomSites.entries(from: mixed).map(\.keyword), ["my notes"])
    }

    func testTheLongestNameIsTriedFirstAndConsumedWhole() {
        let table = ["dashboard": "http://127.0.0.1:1/short", "my dashboard": "http://127.0.0.1:2/long"]
        XCTAssertEqual(CustomSites.entries(from: table).map(\.keyword), ["my dashboard", "dashboard"])
        XCTAssertEqual(BrowserCommandPlanner.plan(for: "open my dashboard", customSites: table).actions.map(\.url),
                       ["http://127.0.0.1:2/long"])
    }

    func testACustomNameWinsOverABuiltInSiteWithTheSameWords() {
        let table = ["gmail": "https://example.org/mail"]
        XCTAssertEqual(BrowserCommandPlanner.plan(for: "open gmail", customSites: table).actions.map(\.url), ["https://example.org/mail"])
    }

    func testNamesAreMatchedCaseAndSpaceInsensitively() {
        XCTAssertEqual(CustomSites.entries(from: ["  My   Dashboard ": address]).map(\.keyword), ["my dashboard"])
    }

    func testOtherSitesAreUnchanged() {
        XCTAssertEqual(BrowserCommandPlanner.plan(for: "open gmail").actions.map(\.url), ["https://mail.google.com/mail/u/0/"])
        XCTAssertEqual(BrowserCommandPlanner.plan(for: "open youtube").actions.map(\.url), ["https://www.youtube.com/"])
        // the owner's own phrase: a plain open of Gmail, not a Gmail search for "up".
        for words in ["Open up, my Gmail in the browser", "open up my gmail", "open my gmail in the browser"] {
            XCTAssertEqual(BrowserCommandPlanner.plan(for: words, customSites: sites).actions.map(\.url),
                           ["https://mail.google.com/mail/u/0/"], words)
        }
        XCTAssertEqual(BrowserCommandPlanner.plan(for: "go to gmail and search for invoices").actions.map(\.url),
                       ["https://mail.google.com/mail/u/0/#search/invoices"])
    }

    func testNoPersonalSiteIsBuiltIn() {
        XCTAssertFalse(BrowserCommandPlanner.siteMap.contains { $0.url.contains("127.0.0.1") || $0.url.contains("localhost") })
    }
}
