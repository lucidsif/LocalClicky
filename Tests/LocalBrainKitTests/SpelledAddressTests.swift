import XCTest
@testable import LocalBrainKit

final class SpelledAddressTests: XCTestCase {
    private func parse(_ words: String) -> String? { SpelledAddress.parse(words) }

    func testAFormattedAddressIsTakenAsIs() {
        XCTAssertEqual(parse("email bob@example.com please"), "bob@example.com")
        XCTAssertEqual(parse("to Bob.Smith+news@Example.co.uk, saying hi"), "bob.smith+news@example.co.uk")
    }

    func testAnAddressWithAWordForAtAndARealDomain() {
        XCTAssertEqual(parse("email bob at example.com saying hi"), "bob@example.com")
    }

    func testTheSpelledFormWithLettersAndWords() {
        XCTAssertEqual(parse("to b o b at example dot com"), "bob@example.com")
        XCTAssertEqual(parse("to bob at example dot com"), "bob@example.com")
        XCTAssertEqual(parse("email Bob at Example Dot Com."), "bob@example.com")
    }

    func testDotPeriodAndPointAreAllDots() {
        XCTAssertEqual(parse("to john dot smith at example dot com"), "john.smith@example.com")
        XCTAssertEqual(parse("to john period smith at example period org"), "john.smith@example.org")
        XCTAssertEqual(parse("to john point smith at example point io"), "john.smith@example.io")
    }

    func testUnderscoreDashHyphenMinusAndPlus() {
        XCTAssertEqual(parse("to bob underscore smith at example dot com"), "bob_smith@example.com")
        XCTAssertEqual(parse("to bob under score smith at example dot com"), "bob_smith@example.com")
        XCTAssertEqual(parse("to bob dash smith at example dot com"), "bob-smith@example.com")
        XCTAssertEqual(parse("to bob hyphen smith at example dot com"), "bob-smith@example.com")
        XCTAssertEqual(parse("to bob minus smith at example dot com"), "bob-smith@example.com")
        XCTAssertEqual(parse("to bob plus news at example dot com"), "bob+news@example.com")
    }

    func testDigitsAsWords() {
        XCTAssertEqual(parse("to bob one two three at example dot com"), "bob123@example.com")
        XCTAssertEqual(parse("to bob at example two dot com"), "bob@example2.com")
    }

    func testGmailSpokenAsTwoWords() {
        XCTAssertEqual(parse("to bob at g mail dot com"), "bob@gmail.com")
        XCTAssertEqual(parse("to bob at gee mail dot com"), "bob@gmail.com")
        XCTAssertEqual(parse("to bob at gmail dot com"), "bob@gmail.com")
    }

    func testTheSpanEndsAtTheFirstTopLevelDomainSoTheMessageIsLeftOut() {
        let tokens = "write an email to bob at example dot com tell him thanks".split(separator: " ").map(String.init)
        let match = SpelledAddress.find(in: tokens)
        XCTAssertEqual(match?.address, "bob@example.com")
        XCTAssertEqual(match.map { Array(tokens[$0.tokenRange.upperBound...]) }, ["tell", "him", "thanks"])
    }

    func testAMessageWordThatIsNotATopLevelDomainIsNotSwallowed() {
        XCTAssertEqual(parse("to bob at example dot com saying call me"), "bob@example.com")
    }

    func testCountryAndMultiPartSuffixes() {
        XCTAssertEqual(parse("to bob at example dot co dot uk"), "bob@example.co.uk")
        XCTAssertEqual(parse("to bob at example dot de"), "bob@example.de")
    }

    func testEveryListedTopLevelDomain() {
        for tld in ["com", "org", "net", "io", "co", "dev", "studio", "edu", "gov", "me", "ai", "app"] {
            XCTAssertEqual(parse("to bob at example dot \(tld)"), "bob@example.\(tld)", tld)
        }
    }

    func testAnEarlierOrdinaryAtIsSkipped() {
        XCTAssertEqual(parse("meet me at noon, draft an email to bob at example dot com"), "bob@example.com")
    }

    func testNoValidAddressIsNil() {
        XCTAssertNil(parse("tell bob i will get back to him"))
        XCTAssertNil(parse("to bob at example"))
        XCTAssertNil(parse("to bob at example dot"))
        XCTAssertNil(parse("bob at the office"))
        XCTAssertNil(parse("at example dot com"))
        XCTAssertNil(parse(""))
    }

    func testCleaningDropsCommasQuotesAndTrailingPeriods() {
        XCTAssertEqual(SpelledAddress.clean("Com."), "com")
        XCTAssertEqual(SpelledAddress.clean("\"example,\""), "example")
        XCTAssertEqual(SpelledAddress.clean("example.com."), "example.com")
    }
}
