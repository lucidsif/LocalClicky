//
//  KeptSketchWindows.swift
//  LocalClicky
//
//  Where a kept sketch lives: one click-through window per screen that holds only the kept marks,
//  with `sharingType = .none`. It is separate from OverlayWindow on purpose:
//    - `sharingType = .none` on the overlay would also hide the blue cursor from the user's own
//      screen sharing and recordings, which nobody asked for;
//    - OverlayWindowManager removes the overlay when the transient cursor hides, and a kept sketch
//      must survive that.
//  The sketch stays out of the screenshots the model sees twice over: CompanionScreenCaptureUtility
//  already excludes every window of this app from its capture filter, and `sharingType = .none`
//  keeps it out of any other capture. (Neither is checked live yet: the first build of this has
//  to be tried with a pointing turn while a sketch is kept.)
//
//  It also holds the "Kept. Say clear to remove." pill (KeptBadge), under the sketch; the pill goes when
//  the marks do and is hidden from VoiceOver, which hears the spoken confirmation instead.
//
//  The window sits one level below the overlay, so the blue cursor and its bubbles stay on top.
//  A key press does not touch it; "clear" (AssistantMarksModel.clearNow on the kept model) does.
//

import AppKit
import LocalBrainKit
import SwiftUI

final class KeptSketchWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // One below the cursor overlay (.screenSaver).
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        ignoresMouseEvents = true
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        setAccessibilityElement(false)
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One screen's kept marks: the marks layer over nothing, and the "Kept" pill under them.
struct KeptSketchView: View {
    @ObservedObject var marks: AssistantMarksModel
    @ObservedObject var inkTrail: InkTrailModel
    let screenFrame: CGRect

    var body: some View {
        ZStack {
            AssistantMarksLayer(marks: marks, style: inkTrail.style, screenFrame: screenFrame)
            // Gone with the sketch: no marks on this screen, no pill.
            if let center = badgeCenter {
                Text(KeptBadge.text)
                    .font(.system(size: SketchLabelStyle.fontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, SketchLabelPlacement.backingPadding / 2)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(SketchLabelStyle.backingOpacity)))
                    .position(center)
                    .allowsHitTesting(false)
                    // VoiceOver already hears "kept. say clear to remove it." when the sketch is kept.
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var badgeCenter: CGPoint? {
        let mine = marks.marks.filter { $0.displayFrame == screenFrame }
        guard let bounds = KeptBadge.bounds(of: mine.map(\.geometry)) else { return nil }
        return KeptBadge.position(sketchBounds: bounds, screen: screenFrame.size)
    }
}

@MainActor
final class KeptSketchWindowManager {
    private var windows: [KeptSketchWindow] = []

    /// Opens a window on every screen if none is open. Safe to call repeatedly.
    func show(marks: AssistantMarksModel, inkTrail: InkTrailModel) {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = KeptSketchWindow(screen: screen)
            let hosting = NSHostingView(rootView: KeptSketchView(marks: marks, inkTrail: inkTrail, screenFrame: screen.frame))
            hosting.frame = screen.frame
            window.contentView = hosting
            windows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }
}
