import XCTest
@testable import LocalBrainKit

final class InkPromptTests: XCTestCase {
    private let summary = "The user drew 1 mark while speaking: circled an area in the top right."

    func testAddendumNamesTheMarkerAndAsksForAnAnswerAboutTheArea() {
        let text = LocalPrompts.inkAddendum(gestureSummary: summary, markerColourName: "yellow", hasCloseUp: false)
        XCTAssertTrue(text.contains("a yellow marker"))
        XCTAssertTrue(text.contains("answer about the marked area"))
        XCTAssertTrue(text.contains(summary))
    }

    func testCloseUpLineOnlyWhenTheSecondImageIsSent() {
        let withCrop = LocalPrompts.inkAddendum(gestureSummary: summary, markerColourName: "yellow", hasCloseUp: true)
        let without = LocalPrompts.inkAddendum(gestureSummary: summary, markerColourName: "yellow", hasCloseUp: false)
        XCTAssertTrue(withCrop.contains("the second image is a close-up of the marked area"))
        XCTAssertFalse(without.contains("second image"))
    }

    func testCloseUpLineSaysTheSecondImageHasNoInk() {
        let text = LocalPrompts.inkAddendum(gestureSummary: summary, markerColourName: "yellow", hasCloseUp: true)
        XCTAssertTrue(text.contains("the second image is a close-up of the marked area, shown without the ink."))
    }

    func testMarkerColourFollowsThePreset() {
        let red = LocalPrompts.inkAddendum(gestureSummary: summary, markerColourName: "red", hasCloseUp: false)
        XCTAssertTrue(red.contains("a red marker"))
        XCTAssertFalse(red.contains("yellow"))
    }

    func testAccessibilityBlockIsAddedOnlyWhenPresent() {
        let block = "Elements inside the circled area, in reading order:\n- button \"Save\""
        let with = LocalPrompts.inkAddendum(gestureSummary: summary, markerColourName: "yellow",
                                            hasCloseUp: true, accessibilityBlock: block)
        XCTAssertTrue(with.hasSuffix(block))
        XCTAssertTrue(with.contains("read directly from the app itself"))
        XCTAssertTrue(with.contains("use them exactly as written"))
        let sentenceIndex = with.range(of: "read directly from the app itself")!.lowerBound
        XCTAssertLessThan(sentenceIndex, with.range(of: block)!.lowerBound)
        let empty = LocalPrompts.inkAddendum(gestureSummary: summary, markerColourName: "yellow",
                                             hasCloseUp: true, accessibilityBlock: "  \n ")
        XCTAssertFalse(empty.contains("Elements inside"))
        XCTAssertFalse(empty.contains("read directly from the app"))
        XCTAssertFalse(empty.hasSuffix("\n"))
    }

    func testNoEmDashesInTheAddendum() {
        let text = LocalPrompts.inkAddendum(gestureSummary: summary, markerColourName: "yellow", hasCloseUp: true)
        XCTAssertFalse(text.contains("\u{2014}"))
    }

    func testPointingPromptsAreUnchangedByTheInkWork() {
        // The addendum is appended by the caller; the system prompts stay exact.
        XCTAssertFalse(LocalPrompts.screenPointResponse(imageWidthInPixels: 1152, imageHeightInPixels: 748).contains("marker"))
        XCTAssertFalse(LocalPrompts.screenClickResponse(imageWidthInPixels: 1152, imageHeightInPixels: 748).contains("marker"))
        XCTAssertFalse(LocalPrompts.screenDescribe(imageWidthInPixels: 1152, imageHeightInPixels: 748).contains("marker"))
    }
}
