import XCTest
@testable import LocalBrainKit

final class ConsentAnswerTests: XCTestCase {
    func testYes() {
        for words in ["yes", "Yeah.", "yep", "yup", "sure", "ok", "okay", "go ahead", "do it", "play it",
                      "yes please", "Yes, please!"] {
            XCTAssertEqual(ConsentAnswer.parse(words), .yes, words)
        }
    }

    func testNo() {
        for words in ["no", "nope", "don't", "don\u{2019}t", "do not", "stop", "cancel", "wait", "never mind",
                      "no thanks", "No."] {
            XCTAssertEqual(ConsentAnswer.parse(words), .no, words)
        }
    }

    func testLongOrUnknownUtterancesAreNotAnAnswer() {
        for words in ["yes but what about the other one", "what is the weather", "", "  ", "maybe", "yes no"] {
            XCTAssertNil(ConsentAnswer.parse(words), words)
        }
    }
}
