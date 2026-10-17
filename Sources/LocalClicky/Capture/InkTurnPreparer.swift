//
//  InkTurnPreparer.swift
//  LocalClicky
//
//  Turns the user's ink into what the turn sends to the model. It starts at key
//  up and runs while the transcript is still being finalised:
//    1. map the recorded samples onto the captured display and analyse them
//       (a jiggle is no ink and ends here);
//    2. composite the stroke onto the press-time JPEG in the resolved user-ink
//       style, scaled from points to screenshot pixels, and cut the close-up;
//    3. in parallel, harvest the Accessibility elements inside the marked area.
//  The result is one package. Timings and counts go to the turn timer, never
//  content.
//

import AppKit
import LocalBrainKit

struct InkTurnPackage {
    /// The press-time capture with the ink composited into `imageData`. Every
    /// other field is the original capture's, so coordinate mapping is unchanged.
    let capture: CompanionScreenCapture
    /// The close-up of the marked area, for describe turns only.
    let cropImageData: Data?
    let gestureSummary: String
    /// Empty when there was nothing usable under the ink.
    let accessibilityBlock: String
    let markCount: Int
    /// "yellow", "red" and so on, for the prompt.
    let markerColourName: String
}

@MainActor
enum InkTurnPreparer {
    static func prepare(samples: [InkSample],
                        capture: CompanionScreenCapture,
                        trail: InkTrailModel,
                        timer: TurnTimer?) async -> InkTurnPackage? {
        let mapping = ScreenMapping(displayFrame: capture.displayFrame,
                                    displayWidthInPoints: capture.displayWidthInPoints,
                                    displayHeightInPoints: capture.displayHeightInPoints,
                                    screenshotWidthInPixels: capture.screenshotWidthInPixels,
                                    screenshotHeightInPixels: capture.screenshotHeightInPixels)
        guard let analysis = InkTurn.analyze(globalSamples: samples, mapping: mapping) else { return nil }

        // Widths are in points on the overlay; the screenshot is smaller or
        // larger than the display, so scale them to its pixels.
        let pointsToPixels = Double(capture.screenshotWidthInPixels) / Double(capture.displayWidthInPoints)
        let style = trail.resolvedStyle(pointsToPixelsScale: pointsToPixels)

        // The harvest starts now, in parallel with the image work below.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        let cgPoints = analysis.probePointsInDisplayPoints.map {
            mapping.cgGlobalPoint(forDisplayLocalPoint: $0, primaryScreenHeight: primaryHeight)
        }
        async let harvested = AccessibilityHarvester.harvest(atCGPoints: cgPoints)

        let jpeg = capture.imageData
        let userInk = style.userInk
        let images = await Task.detached(priority: .userInitiated) {
            InkTurn.render(jpegData: jpeg, analysis: analysis, style: userInk)
        }.value
        guard let images else { _ = await harvested; return nil }
        timer?.mark(.inkReady)

        let records = await harvested
        timer?.mark(.axReady)

        let composited = CompanionScreenCapture(
            imageData: images.compositedJPEG,
            label: capture.label,
            isCursorScreen: capture.isCursorScreen,
            displayWidthInPoints: capture.displayWidthInPoints,
            displayHeightInPoints: capture.displayHeightInPoints,
            displayFrame: capture.displayFrame,
            screenshotWidthInPixels: capture.screenshotWidthInPixels,
            screenshotHeightInPixels: capture.screenshotHeightInPixels)
        return InkTurnPackage(capture: composited,
                              cropImageData: images.cropJPEG,
                              gestureSummary: analysis.gestureSummary,
                              accessibilityBlock: AccessibilitySummary.summarize(records),
                              markCount: analysis.markCount,
                              markerColourName: style.userColourName)
    }
}
