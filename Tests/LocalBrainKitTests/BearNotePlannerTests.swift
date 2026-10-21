import XCTest
@testable import LocalBrainKit

final class BearNotePlannerTests: XCTestCase {
    private func plan(_ words: String) -> BearNoteRequest? { BearNotePlanner.request(from: words) }

    func testWriteANoteInBear() {
        XCTAssertEqual(plan("write a note in bear: buy milk"), BearNoteRequest(mode: .create, title: nil, text: "buy milk"))
        XCTAssertEqual(plan("Write a note in Bear saying call the plumber"),
                       BearNoteRequest(mode: .create, title: nil, text: "call the plumber"))
        XCTAssertEqual(plan("make a note in my bear app: stretch daily"),
                       BearNoteRequest(mode: .create, title: nil, text: "stretch daily"))
    }

    func testMakeABearNoteCalledXSayingY() {
        XCTAssertEqual(plan("make a bear note called groceries saying milk and eggs"),
                       BearNoteRequest(mode: .create, title: "groceries", text: "milk and eggs"))
        XCTAssertEqual(plan("create a new bear note titled Trip ideas: see the coast"),
                       BearNoteRequest(mode: .create, title: "Trip ideas", text: "see the coast"))
    }

    func testAddToMyBearNote() {
        XCTAssertEqual(plan("add to my bear note groceries: buy flowers"),
                       BearNoteRequest(mode: .append, title: "groceries", text: "buy flowers"))
        XCTAssertEqual(plan("add to my bear note called shopping list saying oat milk"),
                       BearNoteRequest(mode: .append, title: "shopping list", text: "oat milk"))
        XCTAssertEqual(plan("hey clicky, please add to my bear note ideas: a pond walk"),
                       BearNoteRequest(mode: .append, title: "ideas", text: "a pond walk"))
    }

    func testAddXToMyYNoteInBear() {
        XCTAssertEqual(plan("add buy flowers to my groceries note in bear"),
                       BearNoteRequest(mode: .append, title: "groceries", text: "buy flowers"))
    }

    func testANoteWithNothingToWriteHasEmptyText() {
        XCTAssertEqual(plan("write a note in bear")?.text, "")
        XCTAssertEqual(plan("make a bear note called groceries")?.title, "groceries")
    }

    func testTheOriginalCaseOfTheNoteIsKept() {
        XCTAssertEqual(plan("write a note in bear: Call Maria about the Austin trip")?.text, "Call Maria about the Austin trip")
    }

    func testNotBearCommands() {
        for words in ["write a note", "make a note called groceries saying milk", "tell me about bears", "the bear note was long",
                      "what's in my bear note", "write a note in bear", "John in the email", "open bear"] where words != "write a note in bear" {
            XCTAssertNil(plan(words), words)
        }
    }

    func testADraftThatMentionsBearIsNotANote() {
        XCTAssertNil(plan("draft an email to bob saying check my bear note: groceries"))
    }

    func testCreateURLCarriesTheTagAndTheBackgroundFlags() {
        let url = BearNotePlanner.url(for: BearNoteRequest(mode: .create, title: "groceries", text: "milk & eggs\nbread"))
        XCTAssertEqual(url, "bear://x-callback-url/create?title=groceries&text=milk%20%26%20eggs%0Abread&tags=clicky&open_note=no&show_window=no")
    }

    func testCreateWithoutATitleLeavesTheTitleOut() {
        let url = BearNotePlanner.url(for: BearNoteRequest(mode: .create, title: nil, text: "buy milk"))
        XCTAssertEqual(url, "bear://x-callback-url/create?text=buy%20milk&tags=clicky&open_note=no&show_window=no")
    }

    func testAppendURLNamesTheNoteAndAppends() {
        let url = BearNotePlanner.url(for: BearNoteRequest(mode: .append, title: "my list", text: "buy flowers"))
        XCTAssertEqual(url, "bear://x-callback-url/add-text?title=my%20list&text=buy%20flowers&mode=append&open_note=no&show_window=no")
    }

    func testBearIsOpenedByItsBundleIdentifier() {
        XCTAssertEqual(BearNotePlanner.bundleIdentifier, "net.shinyfrog.bear")
    }
}
