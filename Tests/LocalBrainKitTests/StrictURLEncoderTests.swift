import XCTest
@testable import LocalBrainKit

final class StrictURLEncoderTests: XCTestCase {
    func testOnlyUnreservedCharactersSurvive() {
        XCTAssertEqual(StrictURLEncoder.encode("AZaz09-._~"), "AZaz09-._~")
    }

    func testEveryReservedCharacterIsEncoded() {
        XCTAssertEqual(StrictURLEncoder.encode("a&b=c+d/e#f?g"), "a%26b%3Dc%2Bd%2Fe%23f%3Fg")
        XCTAssertEqual(StrictURLEncoder.encode("a b"), "a%20b")
        XCTAssertEqual(StrictURLEncoder.encode("100%"), "100%25")
        XCTAssertEqual(StrictURLEncoder.encode("it's \"fine\" (ok) [x] !*"), "it%27s%20%22fine%22%20%28ok%29%20%5Bx%5D%20%21%2A")
    }

    func testNonAsciiIsEncodedAsUTF8Bytes() {
        XCTAssertEqual(StrictURLEncoder.encode("caf\u{E9}"), "caf%C3%A9")
        XCTAssertEqual(StrictURLEncoder.encode("\u{2318}"), "%E2%8C%98")
    }

    func testNewlinesFollowTheTarget() {
        XCTAssertEqual(StrictURLEncoder.encode("a\nb"), "a%0Ab")
        XCTAssertEqual(StrictURLEncoder.encode("a\nb", lineBreak: .crlf), "a%0D%0Ab")
        // CRLF and bare CR both count as one break.
        XCTAssertEqual(StrictURLEncoder.encode("a\r\nb\rc", lineBreak: .lf), "a%0Ab%0Ac")
        XCTAssertEqual(StrictURLEncoder.encode("a\r\nb\rc", lineBreak: .crlf), "a%0D%0Ab%0D%0Ac")
    }

    func testAnInjectedParameterStaysInsideTheValue() {
        let encoded = StrictURLEncoder.encode("hi&bcc=eve@example.com")
        XCTAssertFalse(encoded.contains("&"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("@"))
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(StrictURLEncoder.encode(""), "")
    }
}
