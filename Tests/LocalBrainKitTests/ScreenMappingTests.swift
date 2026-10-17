import XCTest
import CoreGraphics
@testable import LocalBrainKit

final class ScreenMappingTests: XCTestCase {
    private func assertPoint(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-6,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    /// The math of CompanionManager.globalScreenLocation(forImagePoint:in:),
    /// copied verbatim, so any drift in ScreenMapping shows up here.
    private func referenceForward(_ point: CGPoint, frame: CGRect, displayW: Int, displayH: Int,
                                  shotW: Int, shotH: Int) -> CGPoint {
        let screenshotWidth = CGFloat(shotW)
        let screenshotHeight = CGFloat(shotH)
        let displayWidth = CGFloat(displayW)
        let displayHeight = CGFloat(displayH)
        let clampedX = max(0, min(point.x, screenshotWidth))
        let clampedY = max(0, min(point.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY
        return CGPoint(x: displayLocalX + frame.origin.x, y: appKitY + frame.origin.y)
    }

    private let primary = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        displayWidthInPoints: 1512, displayHeightInPoints: 982,
                                        screenshotWidthInPixels: 1152, screenshotHeightInPixels: 748)
    /// A second monitor to the left of the primary.
    private let left = ScreenMapping(displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                     displayWidthInPoints: 1920, displayHeightInPoints: 1080,
                                     screenshotWidthInPixels: 1280, screenshotHeightInPixels: 720)
    /// A monitor sitting above the primary (AppKit y grows upward).
    private let above = ScreenMapping(displayFrame: CGRect(x: 0, y: 982, width: 1512, height: 982),
                                      displayWidthInPoints: 1512, displayHeightInPoints: 982,
                                      screenshotWidthInPixels: 1152, screenshotHeightInPixels: 748)

    func testForwardMatchesCompanionManagerMath() {
        let samples = [CGPoint(x: 0, y: 0), CGPoint(x: 576, y: 374), CGPoint(x: 1152, y: 748),
                       CGPoint(x: 100.5, y: 33.25), CGPoint(x: -40, y: 900), CGPoint(x: 5000, y: -3)]
        for mapping in [primary, left, above] {
            for point in samples {
                let expected = referenceForward(point, frame: mapping.displayFrame,
                                                displayW: mapping.displayWidthInPoints,
                                                displayH: mapping.displayHeightInPoints,
                                                shotW: mapping.screenshotWidthInPixels,
                                                shotH: mapping.screenshotHeightInPixels)
                XCTAssertEqual(mapping.globalPoint(forImagePoint: point), expected)
            }
        }
    }

    func testForwardCornersOnPrimary() {
        // Top-left pixel is the display's top-left, which is AppKit y = height.
        assertPoint(primary.globalPoint(forImagePoint: .zero), CGPoint(x: 0, y: 982))
        assertPoint(primary.globalPoint(forImagePoint: CGPoint(x: 1152, y: 748)), CGPoint(x: 1512, y: 0))
        assertPoint(primary.globalPoint(forImagePoint: CGPoint(x: 576, y: 374)), CGPoint(x: 756, y: 491))
    }

    func testForwardOnLeftMonitorUsesNegativeOrigin() {
        assertPoint(left.globalPoint(forImagePoint: .zero), CGPoint(x: -1920, y: 1080))
        assertPoint(left.globalPoint(forImagePoint: CGPoint(x: 1280, y: 720)), CGPoint(x: 0, y: 0))
        assertPoint(left.globalPoint(forImagePoint: CGPoint(x: 640, y: 360)), CGPoint(x: -960, y: 540))
    }

    func testForwardOnMonitorAboveAddsOriginY() {
        assertPoint(above.globalPoint(forImagePoint: .zero), CGPoint(x: 0, y: 982 + 982))
        assertPoint(above.globalPoint(forImagePoint: CGPoint(x: 1152, y: 748)), CGPoint(x: 1512, y: 982))
    }

    func testForwardClampsOutOfRangePixels() {
        assertPoint(primary.globalPoint(forImagePoint: CGPoint(x: -50, y: -50)),
                    primary.globalPoint(forImagePoint: .zero))
        assertPoint(primary.globalPoint(forImagePoint: CGPoint(x: 9999, y: 9999)),
                    primary.globalPoint(forImagePoint: CGPoint(x: 1152, y: 748)))
    }

    func testRoundTripImageToGlobalAndBack() {
        // Fractions of each mapping's own screenshot, corners included.
        let fractions = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.279, y: 0.856), CGPoint(x: 0.78, y: 0.016)]
        for mapping in [primary, left, above] {
            for fraction in fractions {
                let point = CGPoint(x: fraction.x * CGFloat(mapping.screenshotWidthInPixels),
                                    y: fraction.y * CGFloat(mapping.screenshotHeightInPixels))
                let global = mapping.globalPoint(forImagePoint: point)
                assertPoint(mapping.imagePoint(forGlobalPoint: global), point, accuracy: 1e-9)
            }
        }
    }

    func testRoundTripGlobalToImageAndBack() {
        for mapping in [primary, left, above] {
            let origin = mapping.displayFrame.origin
            let global = CGPoint(x: origin.x + 400.5, y: origin.y + 123.75)
            let image = mapping.imagePoint(forGlobalPoint: global)
            assertPoint(mapping.globalPoint(forImagePoint: image), global, accuracy: 1e-9)
        }
    }

    func testOverlayPointToImageAndBack() {
        // Overlay space is the display-local top-left space: (0,0) is the
        // screenshot's (0,0), and the far corner is the far corner.
        assertPoint(primary.imagePoint(forOverlayPoint: .zero), .zero)
        assertPoint(primary.imagePoint(forOverlayPoint: CGPoint(x: 1512, y: 982)), CGPoint(x: 1152, y: 748))
        let image = primary.imagePoint(forOverlayPoint: CGPoint(x: 756, y: 491))
        assertPoint(image, CGPoint(x: 576, y: 374))
        assertPoint(primary.overlayPoint(forImagePoint: image), CGPoint(x: 756, y: 491), accuracy: 1e-9)
        assertPoint(left.imagePoint(forOverlayPoint: CGPoint(x: 960, y: 540)), CGPoint(x: 640, y: 360))
    }

    func testOverlayAndGlobalAgree() {
        // The same physical spot, expressed both ways, lands on the same pixel.
        let overlay = CGPoint(x: 300, y: 200)
        let global = CGPoint(x: left.displayFrame.origin.x + 300, y: left.displayFrame.origin.y + 1080 - 200)
        assertPoint(left.imagePoint(forGlobalPoint: global), left.imagePoint(forOverlayPoint: overlay), accuracy: 1e-9)
    }

    func testContainsGlobalPoint() {
        XCTAssertTrue(left.containsGlobalPoint(CGPoint(x: -100, y: 500)))
        XCTAssertFalse(left.containsGlobalPoint(CGPoint(x: 100, y: 500)))
        XCTAssertFalse(above.containsGlobalPoint(CGPoint(x: 100, y: 500)))
    }

    func testDisplaySize() {
        XCTAssertEqual(primary.displaySizeInPoints, CGSize(width: 1512, height: 982))
    }
}
