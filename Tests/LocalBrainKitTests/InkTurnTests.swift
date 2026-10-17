import XCTest
import CoreGraphics
import ImageIO
@testable import LocalBrainKit

final class InkTurnTests: XCTestCase {
    // Display 1000 x 600 points at AppKit (0, 0); screenshot 500 x 300 pixels.
    private let mapping = ScreenMapping(displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                                        displayWidthInPoints: 1000, displayHeightInPoints: 600,
                                        screenshotWidthInPixels: 500, screenshotHeightInPixels: 300)
    private let style = InkPalette.resolve(preset: .standard, increaseContrast: false,
                                           differentiateWithoutColor: false, reduceMotion: false,
                                           pointsToPixelsScale: 0.5).userInk

    /// A full circle in GLOBAL AppKit points (y up), centre (400, 300).
    private func circle(center: CGPoint = CGPoint(x: 400, y: 300), radius: Double = 80) -> [InkSample] {
        (0...48).map { step in
            let angle = 2 * Double.pi * Double(step) / 48
            return InkSample(point: CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)),
                             time: Double(step) * 0.016)
        }
    }

    private func makeJPEG(width: Int, height: Int, gray: CGFloat = 0.5) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [gray, gray, gray, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!,
                                   [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    func testCircleIsAnalysedAndWorded() throws {
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: circle(), mapping: mapping))
        XCTAssertEqual(result.markCount, 1)
        XCTAssertEqual(result.analysis.marks.first?.kind, .circle)
        XCTAssertEqual(result.gestureSummary, "The user drew 1 mark while speaking: circled an area in the center.")
    }

    func testRegionNamesUseTheTopLeftFlip() throws {
        // AppKit y 520 is near the TOP of a 600 pt display.
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: circle(center: CGPoint(x: 120, y: 520), radius: 60),
                                                   mapping: mapping))
        XCTAssertEqual(result.gestureSummary, "The user drew 1 mark while speaking: circled an area in the top left.")
    }

    func testMarkPointsLandInScreenshotPixels() throws {
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: circle(), mapping: mapping))
        // Centre (400, 300) AppKit is display-local (400, 300), pixel (200, 150).
        let bounds = result.boundsInImagePixels
        XCTAssertEqual(bounds.midX, 200, accuracy: 1)
        XCTAssertEqual(bounds.midY, 150, accuracy: 1)
        XCTAssertEqual(bounds.width, 80, accuracy: 1)
        XCTAssertEqual(result.strokesInImagePixels.count, 1)
    }

    func testJiggleGivesNoInk() {
        let jiggle = (0..<6).map { InkSample(point: CGPoint(x: 300 + Double($0 % 2) * 3, y: 300), time: Double($0) * 0.02) }
        XCTAssertNil(InkTurn.analyze(globalSamples: jiggle, mapping: mapping))
    }

    func testEmptyAndOffDisplaySamplesGiveNoInk() {
        XCTAssertNil(InkTurn.analyze(globalSamples: [], mapping: mapping))
        XCTAssertNil(InkTurn.analyze(globalSamples: circle(center: CGPoint(x: 3000, y: 300)), mapping: mapping))
    }

    func testOnlySamplesOnThisDisplayCount() throws {
        let mixed = circle() + circle(center: CGPoint(x: 3000, y: 300))
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: mixed, mapping: mapping))
        XCTAssertEqual(result.markCount, 1)
        XCTAssertEqual(result.boundsInImagePixels.midX, 200, accuracy: 1)
    }

    func testProbePointsAreInsideTheDisplay() throws {
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: circle(), mapping: mapping))
        XCTAssertGreaterThanOrEqual(result.probePointsInDisplayPoints.count, 36)
        for point in result.probePointsInDisplayPoints {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1000, height: 600).contains(point))
        }
    }

    func testRenderKeepsTheSizeAndAddsACrop() throws {
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: circle(), mapping: mapping))
        let source = makeJPEG(width: 500, height: 300)
        let images = try XCTUnwrap(InkTurn.render(jpegData: source, analysis: result, style: style))
        let composited = try XCTUnwrap(decode(images.compositedJPEG))
        XCTAssertEqual(composited.width, 500)
        XCTAssertEqual(composited.height, 300)
        XCTAssertNotEqual(images.compositedJPEG, source)
        let crop = try XCTUnwrap(images.cropJPEG.flatMap(decode))
        XCTAssertLessThanOrEqual(max(crop.width, crop.height), 768)
        XCTAssertGreaterThan(crop.width, 100)
    }

    func testInkLandsOnTheRingInTheComposite() throws {
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: circle(), mapping: mapping))
        let images = try XCTUnwrap(InkTurn.render(jpegData: makeJPEG(width: 500, height: 300), analysis: result, style: style))
        let image = try XCTUnwrap(decode(images.compositedJPEG))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: 500 * 300 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 500, height: 300, bitsPerComponent: 8, bytesPerRow: 2000,
                                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 500, height: 300))
        }
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = (y * 500 + x) * 4
            return (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
        }
        // The ring's rightmost point is image pixel (240, 150): yellow core.
        let ring = rgb(240, 150)
        XCTAssertGreaterThan(ring.0, 180)
        XCTAssertGreaterThan(ring.1, 160)
        XCTAssertLessThan(ring.2, 150)
        // The centre of the circle is untouched grey.
        let centre = rgb(200, 150)
        XCTAssertEqual(centre.0, 128, accuracy: 6)
    }

    func testRenderFailsOnGarbageJPEG() throws {
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: circle(), mapping: mapping))
        XCTAssertNil(InkTurn.render(jpegData: Data([1, 2, 3]), analysis: result, style: style))
    }

    func testPauseOnlyStrokeStillComposites() throws {
        // A drift, a long hold, a drift: each moving piece is under 30 pt, so
        // there are no marks, but the hold is a dwell and the stroke is usable.
        var samples = (0...8).map { InkSample(point: CGPoint(x: 300 + Double($0) * 2, y: 300), time: Double($0) * 0.016) }
        samples += (1...30).map { InkSample(point: CGPoint(x: 316 + Double($0 % 2), y: 300), time: 0.2 + Double($0) * 0.05) }
        samples += (1...8).map { InkSample(point: CGPoint(x: 316 + Double($0) * 2, y: 300), time: 1.8 + Double($0) * 0.016) }
        let result = try XCTUnwrap(InkTurn.analyze(globalSamples: samples, mapping: mapping))
        XCTAssertEqual(result.markCount, 0)
        XCTAssertEqual(result.analysis.dwells.count, 1)
        XCTAssertEqual(result.strokesInImagePixels.count, 1)
        XCTAssertEqual(result.strokesInImagePixels[0].count, 1)
        XCTAssertTrue(result.gestureSummary.hasPrefix("The user paused about"))
        XCTAssertNotNil(InkTurn.render(jpegData: makeJPEG(width: 500, height: 300), analysis: result, style: style))
    }
}
