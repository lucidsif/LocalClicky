import XCTest
@testable import LocalBrainKit

final class PointSnapTests: XCTestCase {
    private func window(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ title: String? = nil) -> SnapWindow {
        SnapWindow(title: title, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: window

    func testAPointInsideAWindowGoesToThatWindowsTitleBarCentre() {
        // The model said "title bar" and gave the middle of the window.
        let snap = PointSnap.windowSnap(modelPoint: CGPoint(x: 700, y: 500),
                                        windows: [window(400, 100, 600, 700, "Claude")])
        XCTAssertEqual(snap?.point, CGPoint(x: 700, y: 114))
        XCTAssertEqual(snap?.kind, .window)
        XCTAssertEqual(snap?.matchedLabel, "Claude")
    }

    func testAMenuBarPickGoesToTheNearestWindowBelowIt() {
        // y 14 is the menu bar strip, above every window.
        let windows = [window(400, 38, 600, 700, "Claude"), window(1100, 100, 300, 300, "Notes")]
        let snap = PointSnap.windowSnap(modelPoint: CGPoint(x: 650, y: 14), windows: windows)
        XCTAssertEqual(snap?.point, CGPoint(x: 700, y: 52))
        // Nearest by distance, not by list position.
        let other = PointSnap.windowSnap(modelPoint: CGPoint(x: 1250, y: 14), windows: windows)
        XCTAssertEqual(other?.matchedLabel, "Notes")
    }

    func testTheFrontmostWindowThatHoldsThePointWins() {
        let windows = [window(500, 300, 400, 300, "Front"), window(400, 100, 700, 700, "Back")]
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 600, y: 400), windows: windows)?.matchedLabel, "Front")
        XCTAssertEqual(PointSnap.windowSnap(modelPoint: CGPoint(x: 450, y: 150), windows: windows)?.matchedLabel, "Back")
    }

    func testNoWindowKeepsTheModelsPointAndATinyWindowIsNotAWindow() {
        XCTAssertNil(PointSnap.windowSnap(modelPoint: CGPoint(x: 10, y: 10), windows: []))
        XCTAssertNil(PointSnap.windowSnap(modelPoint: CGPoint(x: 10, y: 10), windows: [window(0, 0, 60, 24)]))
    }

    func testTheTitleBarPointStaysInsideAShortWindow() {
        let snap = PointSnap.windowSnap(modelPoint: CGPoint(x: 150, y: 110), windows: [window(100, 100, 200, 80)])
        XCTAssertEqual(snap?.point.y ?? 0, 114, accuracy: 0.001)
    }

    // MARK: control

    private func element(_ label: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 80, _ h: CGFloat = 30) -> SnapCandidate {
        SnapCandidate(labels: [label], frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func testTheElementUnderThePointIsKeptWhenItsLabelMatches() {
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 212), label: "send button",
                                         candidates: [element("Send", 400, 200), element("Cancel", 500, 200)])
        XCTAssertEqual(snap.kind, .ax)
        XCTAssertEqual(snap.point, CGPoint(x: 440, y: 215))
        XCTAssertEqual(snap.matchedLabel, "Send")
    }

    func testAMismatchedHitFallsBackToTheBestMatchWithinTheRadius() {
        // The point is on "Cancel"; the label says send; "Send" is 90 points away.
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 540, y: 215), label: "send button",
                                         candidates: [element("Cancel", 500, 200), element("Send", 400, 200)])
        XCTAssertEqual(snap.kind, .ax)
        XCTAssertEqual(snap.matchedLabel, "Send")
        XCTAssertEqual(snap.point, CGPoint(x: 440, y: 215))
    }

    func testAMatchBeyondTheRadiusIsIgnoredAndTheModelsPointStays() {
        let model = CGPoint(x: 1000, y: 215)
        let snap = PointSnap.controlSnap(modelPoint: model, label: "send button", candidates: [element("Send", 400, 200)])
        XCTAssertEqual(snap, PointSnapResult(point: model, kind: .none, matchedLabel: nil))
        XCTAssertEqual(PointSnap.searchRadius, 120)
    }

    func testNoLabelOrNoMatchKeepsTheModelsPoint() {
        let model = CGPoint(x: 410, y: 212)
        for label in [nil, "", "the", "zebra stripes"] as [String?] {
            XCTAssertEqual(PointSnap.controlSnap(modelPoint: model, label: label, candidates: [element("Send", 400, 200)]).kind, .none)
        }
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: model, label: "send", candidates: []).kind, .none)
    }

    func testTheNearestMatchWinsAmongEqualOnes() {
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 300, y: 215), label: "send",
                                         candidates: [element("Send", 400, 200), element("Send", 150, 200)])
        XCTAssertEqual(snap.point.x, 190, accuracy: 0.001)
    }

    func testAnEmptyFrameIsNeverSnappedTo() {
        let snap = PointSnap.controlSnap(modelPoint: CGPoint(x: 10, y: 10), label: "send",
                                         candidates: [SnapCandidate(labels: ["Send"], frame: .zero)])
        XCTAssertEqual(snap.kind, .none)
    }

    func testTheSmallestContainingMatchWinsOverALargerOne() {
        let big = SnapCandidate(labels: ["Send message"], frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let small = element("Send message", 400, 200)
        XCTAssertEqual(PointSnap.controlSnap(modelPoint: CGPoint(x: 410, y: 210), label: "send message", candidates: [big, small]).point,
                       CGPoint(x: 440, y: 215))
    }

    func testLabelMatching() {
        XCTAssertEqual(PointSnap.labelScore("Send", "send"), 1)
        XCTAssertEqual(PointSnap.labelScore("send button", "Send"), 0.5)
        XCTAssertEqual(PointSnap.labelScore("settings gear", "Settings"), 0.5)
        XCTAssertEqual(PointSnap.labelScore("setting", "Settings"), 1)
        XCTAssertEqual(PointSnap.labelScore("new tab", "New Window"), 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(PointSnap.labelScore("the send button", "send, button"), 1)
        XCTAssertEqual(PointSnap.labelScore("", "send"), 0)
        XCTAssertEqual(PointSnap.labelScore("the", "the"), 0)
        XCTAssertEqual(PointSnap.labelThreshold, 0.5)
        XCTAssertLessThan(PointSnap.labelScore("new tab", "New Window"), PointSnap.labelThreshold)
        XCTAssertLessThan(PointSnap.labelScore("send button", "send message"), PointSnap.labelThreshold)
        // Short tokens only match whole, so "tab" is not "table".
        XCTAssertEqual(PointSnap.labelScore("tab", "table"), 0)
    }

    func testProbePointsAreTheModelsPointThenTwoRings() {
        let points = PointSnap.probePoints(around: CGPoint(x: 500, y: 400))
        XCTAssertEqual(points.count, 17)
        XCTAssertEqual(points[0], CGPoint(x: 500, y: 400))
        for point in points.dropFirst().prefix(8) { XCTAssertEqual(hypot(point.x - 500, point.y - 400), 60, accuracy: 0.001) }
        for point in points.suffix(8) { XCTAssertEqual(hypot(point.x - 500, point.y - 400), 120, accuracy: 0.001) }
    }

    // MARK: coordinate spaces

    // The model's point is in screenshot pixels (the gateway rescaled norm1000). The app maps it to a Core Graphics
    // global point (top-left of the primary display, y down), the space of AX frames and window bounds, snaps
    // there, and maps the result back to pixels for the cursor. A second display above-right of a primary of
    // 1440x900 points makes the origin and the flip matter.
    func testScreenshotPixelsToCoreGraphicsPointsAndBack() {
        let primaryHeight: CGFloat = 900
        // Secondary display: 1920x1080 points, its AppKit frame bottom-left at (1440, 300): it spans AppKit y 300 to 1380.
        let mapping = ScreenMapping(displayFrame: CGRect(x: 1440, y: 300, width: 1920, height: 1080),
                                    displayWidthInPoints: 1920, displayHeightInPoints: 1080,
                                    screenshotWidthInPixels: 1152, screenshotHeightInPixels: 648)
        // Screenshot pixel (576, 324) is the display's centre: 960, 540 points into the display.
        let pixel = CGPoint(x: 576, y: 324)
        let local = mapping.displayLocalPoint(forImagePoint: pixel)
        XCTAssertEqual(local, CGPoint(x: 960, y: 540))
        let cg = mapping.cgGlobalPoint(forDisplayLocalPoint: local, primaryScreenHeight: primaryHeight)
        // x: 1440 + 960. AppKit y = 300 + (1080 - 540) = 840, CG y = 900 - 840 = 60.
        XCTAssertEqual(cg, CGPoint(x: 2400, y: 60))
        let back = mapping.imagePoint(forCGGlobalPoint: cg, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(back.x, pixel.x, accuracy: 0.001)
        XCTAssertEqual(back.y, pixel.y, accuracy: 0.001)

        // The display's top edge in CG is 900 - (300 + 1080) = -480: a point on the secondary display can have a negative y.
        let top = mapping.cgGlobalPoint(forDisplayLocalPoint: .zero, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(top, CGPoint(x: 1440, y: -480))
    }

    func testARoundTripHoldsOnThePrimaryDisplayAndForAnyPixel() {
        let mapping = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    displayWidthInPoints: 1440, displayHeightInPoints: 900,
                                    screenshotWidthInPixels: 1152, screenshotHeightInPixels: 720)
        for pixel in [CGPoint(x: 0, y: 0), CGPoint(x: 1152, y: 720), CGPoint(x: 14, y: 14), CGPoint(x: 800, y: 123.5)] {
            let cg = mapping.cgGlobalPoint(forDisplayLocalPoint: mapping.displayLocalPoint(forImagePoint: pixel), primaryScreenHeight: 900)
            // On the primary display, CG is display-local: top-left origin, 1440 points for 1152 pixels.
            XCTAssertEqual(cg.x, pixel.x * 1.25, accuracy: 0.001)
            XCTAssertEqual(cg.y, pixel.y * 1.25, accuracy: 0.001)
            let back = mapping.imagePoint(forCGGlobalPoint: cg, primaryScreenHeight: 900)
            XCTAssertEqual(back.x, pixel.x, accuracy: 0.001)
            XCTAssertEqual(back.y, pixel.y, accuracy: 0.001)
        }
    }

    // The log's example: a window request answered with y 14 in 1152x720 pixels is the menu bar strip.
    func testAMenuBarPixelSnapsToTheWindowBelowAndComesBackAsAPixelInsideTheWindow() {
        let mapping = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                    displayWidthInPoints: 1440, displayHeightInPoints: 900,
                                    screenshotWidthInPixels: 1152, screenshotHeightInPixels: 720)
        let cg = mapping.cgGlobalPoint(forDisplayLocalPoint: mapping.displayLocalPoint(forImagePoint: CGPoint(x: 600, y: 14)),
                                       primaryScreenHeight: 900)
        XCTAssertEqual(cg.y, 17.5, accuracy: 0.001)
        let claude = SnapWindow(title: "Claude", frame: CGRect(x: 300, y: 38, width: 900, height: 800))
        let snap = PointSnap.windowSnap(modelPoint: cg, windows: [claude])!
        XCTAssertEqual(snap.point, CGPoint(x: 750, y: 52))
        let pixel = mapping.imagePoint(forCGGlobalPoint: snap.point, primaryScreenHeight: 900)
        XCTAssertEqual(pixel.x, 600, accuracy: 0.001)
        XCTAssertEqual(pixel.y, 41.6, accuracy: 0.001)
    }
}
