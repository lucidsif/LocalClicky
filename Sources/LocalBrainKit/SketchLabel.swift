//
//  SketchLabel.swift
//  LocalBrainKit
//
//  Where the label of a sketch's SHAPE tag is drawn, and the colours it is drawn in. Pure, so the
//  placement and the contrast are tested. The overlay (AssistantMarksLayer) only draws what this
//  file returns. Only a freeform sketch draws labels; the draw route's marks never do.
//

import CoreGraphics
import Foundation

/// A label ready to draw: its text and the centre of its box, in the overlay's points
/// (display-local, top-left origin, the space MarkGeometry is in).
public struct MarkLabel: Equatable, Sendable {
    public let text: String
    public let position: CGPoint

    public init(text: String, position: CGPoint) {
        self.text = text
        self.position = position
    }
}

public enum SketchLabelStyle {
    public static let fontSize: Double = 15
    /// White text on a black backing at this opacity.
    public static let backingOpacity: Double = 0.85
    /// WCAG AA for normal text.
    public static let requiredContrast: Double = 4.5

    /// The contrast of white text on the backing over the worst background, a white one (a lighter
    /// background leaks the most through a translucent black).
    public static var worstCaseContrast: Double {
        let leaked = 1 - backingOpacity   // a white background (1.0) seen through black at `backingOpacity`
        let backgroundLuminance = relativeLuminance(ofGray: leaked)
        return (1 + 0.05) / (backgroundLuminance + 0.05)
    }

    static func relativeLuminance(ofGray value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

public enum SketchLabelPlacement {
    /// How far above a shape's top edge the label's centre sits.
    public static let gapAboveTopEdge: Double = 16
    /// The least distance from the label's centre to the screen edge, vertically.
    public static let verticalMargin: Double = 14
    /// Rough width of one character of the label font, plus the backing's padding, to keep a long
    /// label on screen. An estimate: the view lays the real text out.
    public static let estimatedCharacterWidth: Double = 8.5
    public static let backingPadding: Double = 20

    /// A line or arrow is labelled at its centre. A circle, curve or polygon is labelled above its
    /// top edge, centred on it. Nil for a highlight or an empty label. The centre is kept on the
    /// screen (`bounds` is the overlay's size).
    public static func label(for drawing: OverlayDrawing, text: String?, bounds: CGSize) -> MarkLabel? {
        guard case .shape(let kind, let points) = drawing, !points.isEmpty,
              let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let anchor: CGPoint
        switch kind {
        case .line, .arrow:
            guard points.count == 2 else { return nil }
            anchor = CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        case .circle:
            guard points.count == 2 else { return nil }
            let radius = max(MarkGeometryBuilder.minimumCircleRadius, Double(InkGeometry.distance(points[0], points[1])))
            anchor = CGPoint(x: points[0].x, y: points[0].y - CGFloat(radius) - CGFloat(gapAboveTopEdge))
        case .curve, .polygon:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min() else { return nil }
            anchor = CGPoint(x: (minX + maxX) / 2, y: minY - CGFloat(gapAboveTopEdge))
        }
        let half = (Double(text.count) * estimatedCharacterWidth + backingPadding) / 2
        let x = min(max(Double(anchor.x), half), max(half, Double(bounds.width) - half))
        let y = min(max(Double(anchor.y), verticalMargin), max(verticalMargin, Double(bounds.height) - verticalMargin))
        return MarkLabel(text: text, position: CGPoint(x: x, y: y))
    }
}

/// The pill that tells the user a sketch is kept and how to remove it. Drawn in the kept window, near
/// the bottom of the kept sketch's bounds. It is sighted-only: VoiceOver already hears
/// "kept. say clear to remove it." (the spoken confirmation), so the pill is hidden from accessibility
/// and says nothing itself. The colours are the labels' (white on black at 0.85), so the contrast is the
/// same worst case, at least 4.5:1 over any background.
public enum KeptBadge {
    public static let text = "Kept. Say clear to remove."
    public static let gapBelowSketch: Double = 14
    /// Rough height of the pill (label font plus its vertical padding), to keep it on the screen.
    public static let estimatedHeight: Double = 26
    public static let screenMargin: Double = 10

    public static var worstCaseContrast: Double { SketchLabelStyle.worstCaseContrast }

    /// The box around every point of the given marks, or nil when they hold none.
    public static func bounds(of geometries: [MarkGeometry]) -> CGRect? {
        let points = geometries.flatMap { $0.passes.flatMap { $0.flatMap(\.points) } }
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The centre of the pill: centred under the sketch, kept on the screen (`screen` is the overlay's
    /// size). A sketch that reaches the bottom edge gets the pill at the bottom margin, over its lowest part.
    public static func position(sketchBounds: CGRect, screen: CGSize) -> CGPoint {
        let half = (Double(text.count) * SketchLabelPlacement.estimatedCharacterWidth + SketchLabelPlacement.backingPadding) / 2
        let x = min(max(Double(sketchBounds.midX), half + screenMargin), max(half + screenMargin, Double(screen.width) - half - screenMargin))
        let wantedY = Double(sketchBounds.maxY) + gapBelowSketch + estimatedHeight / 2
        let lowest = Double(screen.height) - screenMargin - estimatedHeight / 2
        return CGPoint(x: x, y: min(wantedY, max(estimatedHeight / 2, lowest)))
    }
}
