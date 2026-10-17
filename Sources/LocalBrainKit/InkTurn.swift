//
//  InkTurn.swift
//  LocalBrainKit
//
//  Everything the turn needs from the user's ink at key up, as pure steps on
//  top of ScreenMapping, InkStroke, GestureSummary and InkImage:
//    analyze: global samples on the captured display, analysed, worded, and
//             mapped to screenshot pixels, with the points to probe for
//             Accessibility;
//    render:  the stroke composited onto the press-time JPEG, and the close-up
//             cut around it.
//  `analyze` is cheap. `render` decodes and encodes JPEGs, so the app runs it
//  off the main thread.
//

import CoreGraphics
import Foundation

public struct InkTurnAnalysis: Equatable, Sendable {
    public let analysis: InkAnalysis
    /// One sentence in plain words, no coordinates.
    public let gestureSummary: String
    public var markCount: Int { analysis.marks.count }
    /// Mark points in screenshot pixels, ready to composite. A stroke that is
    /// only pauses has one single-point stroke per pause.
    public let strokesInImagePixels: [[CGPoint]]
    /// The ink's bounding box in screenshot pixels.
    public let boundsInImagePixels: CGRect
    /// Where to hit-test for Accessibility, in display-local points.
    public let probePointsInDisplayPoints: [CGPoint]
}

public struct InkTurnImages: Equatable, Sendable {
    public let compositedJPEG: Data
    public let cropJPEG: Data?
}

public enum InkTurn {
    /// Nil when there is no usable ink on this display: no samples here, a
    /// jiggle, or nothing left after analysis. Samples on other displays are
    /// ignored.
    public static func analyze(globalSamples: [InkSample], mapping: ScreenMapping) -> InkTurnAnalysis? {
        let local = globalSamples
            .filter { mapping.containsGlobalPoint($0.point) }
            .map { InkSample(point: mapping.displayLocalPoint(forGlobalPoint: $0.point), time: $0.time) }
        guard !local.isEmpty else { return nil }

        let analysis = InkStroke(samples: local).analyze()
        guard !analysis.isEmpty,
              let summary = GestureSummary.describe(analysis, screenSize: mapping.displaySizeInPoints),
              let bounds = InkAccessibilityGrid.bounds(of: analysis) else { return nil }

        func toImage(_ point: CGPoint) -> CGPoint { mapping.imagePoint(forOverlayPoint: point) }
        let strokes: [[CGPoint]] = analysis.marks.isEmpty
            ? analysis.dwells.map { [toImage($0.location)] }
            : analysis.marks.map { $0.points.map(toImage) }

        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY)].map(toImage)
        let imageBounds = CGRect(x: corners[0].x, y: corners[0].y,
                                 width: corners[1].x - corners[0].x, height: corners[1].y - corners[0].y)

        return InkTurnAnalysis(analysis: analysis,
                               gestureSummary: summary,
                               strokesInImagePixels: strokes,
                               boundsInImagePixels: imageBounds,
                               probePointsInDisplayPoints: InkAccessibilityGrid.probePoints(for: analysis))
    }

    /// The composited screenshot and the close-up. Nil if the JPEG cannot be
    /// decoded or encoded. The crop is nil only when it alone fails.
    public static func render(jpegData: Data, analysis: InkTurnAnalysis, style: InkStyle) -> InkTurnImages? {
        guard let composited = InkImage.compositeInk(jpegData: jpegData,
                                                     strokesInImagePixels: analysis.strokesInImagePixels,
                                                     style: style) else { return nil }
        let crop = InkImage.cropAround(jpegData: composited, rectInImagePixels: analysis.boundsInImagePixels)
        return InkTurnImages(compositedJPEG: composited, cropJPEG: crop?.jpegData)
    }
}
