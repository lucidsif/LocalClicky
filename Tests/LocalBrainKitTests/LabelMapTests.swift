import XCTest
@testable import LocalBrainKit

/// Every guessed label lives in LabelMap, so these tests are what a later fix after the compose probe changes.
final class LabelMapTests: XCTestCase {
    func testComposeBodyIsATextAreaDescribedMessageBody() {
        XCTAssertTrue(LabelMap.isComposeBody(role: "AXTextArea", description: "Message Body"))
        XCTAssertTrue(LabelMap.isComposeBody(role: "AXTextField", description: "message body, editable"))
        XCTAssertFalse(LabelMap.isComposeBody(role: "AXButton", description: "Message Body"))
        XCTAssertFalse(LabelMap.isComposeBody(role: "AXTextArea", description: "Subject"))
        XCTAssertFalse(LabelMap.isComposeBody(role: "AXTextArea", description: nil))
        XCTAssertTrue(LabelMap.isComposeBody(role: "AXTextArea", description: "Message Body", service: .fastmail))
    }

    func testThePhaseOneProbeMatcherAnswersFromTheSameMap() {
        XCTAssertEqual(PageProbeMatcher.isComposeBody(role: "AXTextArea", description: "Message Body"),
                       LabelMap.isComposeBody(role: "AXTextArea", description: "Message Body"))
    }

    func testReplyButtonIsExactlyReply() {
        XCTAssertTrue(LabelMap.isReplyButton(role: "AXButton", label: "Reply"))
        XCTAssertTrue(LabelMap.isReplyButton(role: "AXButton", label: " \u{202A}reply\u{202C} "))
        XCTAssertFalse(LabelMap.isReplyButton(role: "AXButton", label: "Reply all"))
        XCTAssertFalse(LabelMap.isReplyButton(role: "AXButton", label: "Reply to Bob"))
        XCTAssertFalse(LabelMap.isReplyButton(role: "AXLink", label: "Reply"))
    }

    func testRowsMatchANameOrAnAddress() {
        let row = ["Bob Smith", "Lunch on Thursday?", "bob@example.com"]
        XCTAssertTrue(LabelMap.rowMentions(person: .nameOnly("bob"), texts: row))
        XCTAssertTrue(LabelMap.rowMentions(person: .address("bob@example.com"), texts: row))
        XCTAssertTrue(LabelMap.rowMentions(person: .address("bobsmith@other.org"), texts: ["Bobsmith", "hi"]))
        XCTAssertFalse(LabelMap.rowMentions(person: .nameOnly("alice"), texts: row))
        XCTAssertFalse(LabelMap.rowMentions(person: .address("al@x.org"), texts: ["al"]), "a part under three letters is too weak")
        XCTAssertFalse(LabelMap.rowMentions(person: .none, texts: row))
        XCTAssertFalse(LabelMap.rowMentions(person: .nameOnly("bob"), texts: []))
    }

    func testOnlyRowsAndButtonsMayBePressedInADraft() {
        XCTAssertTrue(LabelMap.mayPressInDraft(role: "AXRow"))
        XCTAssertTrue(LabelMap.mayPressInDraft(role: "AXButton"))
        XCTAssertFalse(LabelMap.mayPressInDraft(role: "AXLink"))
        XCTAssertFalse(LabelMap.mayPressInDraft(role: "AXTextArea"))
    }

    func testComposeWindowCues() {
        XCTAssertTrue(LabelMap.isComposeWindow(title: nil, address: "https://mail.google.com/mail/u/0/?view=cm&fs=1"))
        XCTAssertTrue(LabelMap.isComposeWindow(title: nil, address: "https://mail.google.com/mail/u/0/#inbox?compose=new"))
        XCTAssertTrue(LabelMap.isComposeWindow(title: "Compose - Gmail", address: nil))
        XCTAssertFalse(LabelMap.isComposeWindow(title: "Inbox (3) - Gmail", address: "https://mail.google.com/mail/u/0/#inbox"))
    }

    func testPreferredDomains() {
        XCTAssertEqual(LabelMap.preferredDomain(for: .gmail), "mail.google.com")
        XCTAssertEqual(LabelMap.preferredDomain(for: .fastmail), "app.fastmail.com")
    }

    // MARK: - ReplyContext

    func testReplyContextIsTheTextsBeforeTheLastReplyButton() {
        let items: [PageItem] = [.text("Inbox"), .text("Bob Smith"), .button("Reply"), .text("Lunch on Thursday?"),
                                 .text("Are you free at noon?"), .button("Reply all"), .button("Reply"), .text("Footer")]
        XCTAssertEqual(ReplyContext.extract(from: items), "Inbox\nBob Smith\nLunch on Thursday?\nAre you free at noon?")
    }

    func testReplyContextKeepsTheEndNearestTheButtonWhenItIsLong() {
        let items: [PageItem] = [.text(String(repeating: "a", count: 3000)), .text("last words"), .button("Reply")]
        let context = ReplyContext.extract(from: items)
        XCTAssertEqual(context?.count, ReplyContext.maxCharacters)
        XCTAssertTrue(context?.hasSuffix("last words") == true)
    }

    func testReplyContextIsNilWithoutAReplyButtonOrText() {
        XCTAssertNil(ReplyContext.extract(from: [.text("hello"), .button("Reply all")]))
        XCTAssertNil(ReplyContext.extract(from: [.button("Reply")]))
        XCTAssertNil(ReplyContext.extract(from: [.text("   "), .button("Reply")]))
    }

    // MARK: - PageGate and links

    func testThePageGateNeedsTheServicesDomainAndChildren() {
        let gmail = "https://mail.google.com/mail/u/0/#inbox"
        XCTAssertTrue(PageGate.isReadable(url: gmail, childCount: 3, domain: "mail.google.com"))
        XCTAssertFalse(PageGate.isReadable(url: gmail, childCount: 0, domain: "mail.google.com"))
        XCTAssertFalse(PageGate.isReadable(url: gmail, childCount: nil, domain: "mail.google.com"))
        XCTAssertFalse(PageGate.isReadable(url: "https://www.youtube.com/watch?v=x", childCount: 9, domain: "mail.google.com"))
        XCTAssertFalse(PageGate.isReadable(url: nil, childCount: 9, domain: "mail.google.com"))
        XCTAssertFalse(PageGate.isReadable(url: "https://evilmail.google.com.example.org/", childCount: 9, domain: "mail.google.com"))
        XCTAssertTrue(PageGate.isReadable(url: "https://app.fastmail.com/mail/", childCount: 1, domain: "app.fastmail.com"))
    }

    func testGmailSearchLinkEncodesThePerson() {
        XCTAssertEqual(ComposeTarget.gmailSearchURL(from: "bob"), "https://mail.google.com/mail/u/0/#search/from%3Abob")
        XCTAssertEqual(ComposeTarget.gmailSearchURL(from: "bob@example.com", accountIndex: 2),
                       "https://mail.google.com/mail/u/2/#search/from%3Abob%40example.com")
        XCTAssertEqual(ComposeTarget.gmailSearchURL(from: "a&b c"), "https://mail.google.com/mail/u/0/#search/from%3Aa%26b%20c")
    }

    // MARK: - Bear

    func testBearLinesNeverSaySent() {
        XCTAssertEqual(BearNotePlanner.addedLine, "added the note to bear.")
        for line in [BearNotePlanner.addedLine, BearNotePlanner.failedLine, BearNotePlanner.askTextLine] {
            XCTAssertFalse(line.lowercased().contains("sent"), line)
        }
    }
}
