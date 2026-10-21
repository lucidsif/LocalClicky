//
//  GhostPointerWindow.swift
//  LocalClicky
//
//  A faint arrow that shows where the agent is about to press. It is only a picture:
//  clicks go through it, screen captures skip it, and assistive technology ignores it
//  (the step card says the same thing in words). The real cursor is never moved.
//

import AppKit
import SwiftUI

@MainActor
final class GhostPointerWindow {
    private static let size: CGFloat = 22
    private static let moveSeconds = 0.25

    private lazy var window: NSWindow = {
        let ghost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                             styleMask: .borderless, backing: .buffered, defer: false)
        ghost.isOpaque = false
        ghost.backgroundColor = .clear
        ghost.hasShadow = false
        ghost.level = .floating
        ghost.alphaValue = 0.45
        ghost.ignoresMouseEvents = true
        ghost.sharingType = .none
        ghost.isReleasedWhenClosed = false
        ghost.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        ghost.setAccessibilityElement(false)
        let arrow = NSHostingView(rootView: GhostArrow().accessibilityHidden(true))
        arrow.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        ghost.contentView = arrow
        return ghost
    }()

    /// Points the arrow's tip at a Core Graphics global point (origin top-left of the primary display).
    func show(atCGGlobalPoint point: CGPoint) {
        // The inverse of ClickActionExecutor.cgGlobalPoint, anchored on the same primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
        // The arrow's tip is the window's top-left corner.
        let origin = CGPoint(x: point.x, y: primaryHeight - point.y - Self.size)
        if window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.moveSeconds
                window.animator().setFrameOrigin(origin)
            }
        } else {
            window.setFrameOrigin(origin)
        }
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

/// A filled arrow with an outline, tip at the top-left corner of its frame.
private struct GhostArrow: View {
    var body: some View {
        ArrowShape()
            .fill(DS.Colors.overlayCursorBlue)
            .overlay(ArrowShape().stroke(Color.white, lineWidth: 1.5))
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 1, y: 1))
        path.addLine(to: CGPoint(x: 1, y: 19))
        path.addLine(to: CGPoint(x: 6, y: 14.5))
        path.addLine(to: CGPoint(x: 12.5, y: 13))
        path.closeSubpath()
        return path
    }
}
