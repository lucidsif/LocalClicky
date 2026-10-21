import XCTest
@testable import LocalBrainKit

final class ComposeTargetTests: XCTestCase {
    func testGmailComposeURLHasAllThreeFieldsEvenWhenEmpty() {
        XCTAssertEqual(ComposeTarget.gmailURL(to: "", subject: "", body: ""),
                       "https://mail.google.com/mail/u/0/?view=cm&fs=1&tf=1&to=&su=&body=")
    }

    func testGmailComposeURLEncodesEachValueStrictly() {
        let url = ComposeTarget.gmailURL(to: "bob@example.com", subject: "a&b", body: "Hi Bob,\nI will get back to you.")
        XCTAssertEqual(url, "https://mail.google.com/mail/u/0/?view=cm&fs=1&tf=1&to=bob%40example.com&su=a%26b"
                       + "&body=Hi%20Bob%2C%0AI%20will%20get%20back%20to%20you.")
    }

    func testGmailAccountNumberIsAConfigValue() {
        XCTAssertTrue(ComposeTarget.gmailURL(to: "", subject: "", body: "", accountIndex: 2).hasPrefix("https://mail.google.com/mail/u/2/?"))
        XCTAssertTrue(ComposeTarget.gmailURL(to: "", subject: "", body: "", accountIndex: -1).hasPrefix("https://mail.google.com/mail/u/0/?"))
    }

    func testMailtoKeepsTheAtSignAndUsesCRLFForBodyBreaks() {
        let url = ComposeTarget.mailtoURL(to: "bob@example.com", subject: "hi", body: "line one\nline two")
        XCTAssertEqual(url, "mailto:bob@example.com?subject=hi&body=line%20one%0D%0Aline%20two")
    }

    func testMailtoWithNoRecipientHasAnEmptyAddress() {
        XCTAssertEqual(ComposeTarget.mailtoURL(to: "", subject: "", body: ""), "mailto:?subject=&body=")
    }

    func testMailtoEncodesAPlusInTheAddress() {
        XCTAssertTrue(ComposeTarget.mailtoURL(to: "bob+news@example.com", subject: "", body: "").hasPrefix("mailto:bob%2Bnews@example.com?"))
    }

    func testEachServiceOpensInItsOwnApp() {
        let gmail = ComposeTarget.opening(service: .gmail, to: "", subject: "", body: "x")
        XCTAssertEqual(gmail.bundleIdentifier, "com.google.Chrome")
        XCTAssertTrue(gmail.url.hasPrefix("https://mail.google.com/"))
        let fastmail = ComposeTarget.opening(service: .fastmail, to: "", subject: "", body: "x")
        XCTAssertEqual(fastmail.bundleIdentifier, "com.fastmail.mac.Fastmail")
        XCTAssertTrue(fastmail.url.hasPrefix("mailto:"))
    }
}
