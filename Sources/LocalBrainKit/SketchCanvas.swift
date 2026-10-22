//
//  SketchCanvas.swift
//  LocalBrainKit
//
//  The record behind a freeform sketch on the screen. The marks on screen are only a drawing of
//  this record, so the app can redraw them (a press clears an unkept sketch before "keep it" is
//  heard), extend them, take the last group back and read the steps out, all with no model call
//  except the extend itself.
//
//  Pure, and screen-free: the tags are stored on the 0 to 1000 grid the model writes in (converted
//  from screenshot pixels with the screenshot size), which is also what the extend prompt quotes.
//  The pixel size the sketch was first drawn at is kept so it can be redrawn the same.
//
//  States: empty (nothing drawn), showing (an unkept sketch: it fades after SketchTiming.holdSeconds,
//  and a key press already took it off the screen), kept (stays until "clear" or the app quits;
//  it is never saved to disk), extending (kept, with an extend turn in flight).
//

import CoreGraphics
import Foundation

/// What the router needs to know about the canvas.
public enum SketchCanvasStatus: Equatable, Sendable {
    case none, showing, kept
}

public struct SketchCanvas: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        /// The spoken sentences of the group's steps, for "describe the sketch".
        public let steps: [String]
        /// SHAPE tags on the 0 to 1000 grid.
        public let tags: [ShapeTag]

        public init(steps: [String], tags: [ShapeTag]) {
            self.steps = steps
            self.tags = tags
        }
    }

    public enum State: Equatable, Sendable {
        case empty, showing, kept, extending
    }

    public enum UndoResult: Equatable, Sendable {
        /// Nothing to undo (empty, or an extend is in flight).
        case nothing
        /// The last group is gone; others remain.
        case removedLast
        /// The only group was the last one, so the sketch is cleared.
        case cleared
    }

    /// Group 1 is the first sketch; each extend adds one.
    public private(set) var groups: [Group] = []
    /// False: fades after the hold.
    public private(set) var kept = false
    public private(set) var isExtending = false
    /// The screenshot size the first group was drawn at.
    public private(set) var imageWidth = 0
    public private(set) var imageHeight = 0

    public init() {}

    public var state: State {
        if groups.isEmpty { return .empty }
        if isExtending { return .extending }
        return kept ? .kept : .showing
    }

    public var status: SketchCanvasStatus {
        switch state {
        case .empty: return .none
        case .showing: return .showing
        case .kept, .extending: return .kept
        }
    }

    public var isEmpty: Bool { groups.isEmpty }

    /// What the extend prompt gets.
    public var allTags: [ShapeTag] { groups.flatMap(\.tags) }

    // MARK: - Changes

    /// A new sketch replaces whatever was there.
    public mutating func begin(_ group: Group, kept: Bool, imageWidth: Int, imageHeight: Int) {
        groups = [group]
        self.kept = kept
        isExtending = false
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// "Keep it". False when there is nothing to keep.
    @discardableResult
    public mutating func keep() -> Bool {
        guard !groups.isEmpty else { return false }
        kept = true
        return true
    }

    /// An extend turn starts. False unless the sketch is kept and no extend is running.
    @discardableResult
    public mutating func beginExtend() -> Bool {
        guard state == .kept else { return false }
        isExtending = true
        return true
    }

    /// The extend turn ended: its group (nil when it drew nothing or was cancelled) is appended.
    public mutating func finishExtend(with group: Group?) {
        guard isExtending else { return }
        isExtending = false
        if let group { groups.append(group) }
    }

    /// Takes the last group back. With one group left, it clears.
    public mutating func undo() -> UndoResult {
        guard !groups.isEmpty, !isExtending else { return .nothing }
        if groups.count == 1 {
            clear()
            return .cleared
        }
        groups.removeLast()
        return .removedLast
    }

    public mutating func clear() {
        groups = []
        kept = false
        isExtending = false
        imageWidth = 0
        imageHeight = 0
    }

    // MARK: - Reading back

    /// "step 1: ... step 2: ...", the steps of every group in order, or nil when nothing is drawn.
    public func describe() -> String? {
        let steps = groups.flatMap(\.steps).filter { !$0.isEmpty }
        guard !groups.isEmpty else { return nil }
        guard !steps.isEmpty else { return "there is a sketch with \(allTags.count) marks." }
        return steps.enumerated().map { "step \($0.offset + 1): \($0.element)" }.joined(separator: " ")
    }

    // MARK: - Pixels and the grid

    /// The group's shapes as drawings in the pixels the sketch was first drawn at.
    public func drawings(inGroup index: Int) -> [InkDrawing] {
        guard groups.indices.contains(index) else { return [] }
        return Self.pixelTags(from: groups[index].tags, imageWidth: imageWidth, imageHeight: imageHeight).map { .shape($0) }
    }

    /// Screenshot pixels to the 0 to 1000 grid, to whole numbers (the prompt quotes them).
    public static func gridTags(from pixelTags: [ShapeTag], imageWidth: Int, imageHeight: Int) -> [ShapeTag] {
        guard imageWidth > 0, imageHeight > 0 else { return [] }
        return pixelTags.map { tag in
            let points = tag.points.map {
                CGPoint(x: (Double($0.x) * 1000 / Double(imageWidth)).rounded(), y: (Double($0.y) * 1000 / Double(imageHeight)).rounded())
            }
            return ShapeTag(kind: tag.kind, points: points, label: tag.label, screenNumber: nil)
        }
    }

    /// The 0 to 1000 grid to screenshot pixels.
    public static func pixelTags(from gridTags: [ShapeTag], imageWidth: Int, imageHeight: Int) -> [ShapeTag] {
        gridTags.map { tag in
            let points = tag.points.map {
                CGPoint(x: Double($0.x) * Double(imageWidth) / 1000, y: Double($0.y) * Double(imageHeight) / 1000)
            }
            return ShapeTag(kind: tag.kind, points: points, label: tag.label, screenNumber: nil)
        }
    }

    /// A group from a reply's pixel tags and sentences.
    public static func group(steps: [String], pixelTags: [ShapeTag], imageWidth: Int, imageHeight: Int) -> Group {
        Group(steps: steps.filter { !$0.isEmpty },
              tags: gridTags(from: pixelTags, imageWidth: imageWidth, imageHeight: imageHeight))
    }
}

/// The words about a sketch that is on the screen or was just there. Pure, and only consulted while
/// drawing is on and the canvas allows it (DrawingRouting): "keep it" and "add the curb" mean nothing
/// without a sketch.
public enum SketchCanvasIntent {
    private static let lead = #"^(?:(?:please|ok|okay|yes|yeah|yep|and|now|then|just|can you|could you|would you)\s+)*"#
    private static let tail = #"(?:\s+(?:please|for me|now|there))*[\s.!?]*$"#

    /// "keep it", "keep that on the screen", "pin it", "leave it on screen", "don't clear it": the whole
    /// utterance, so "keep it short" and "keep it up" are not it.
    public static func wantsKeep(_ transcript: String) -> Bool {
        let core = #"(?:keep\s+(?:it|that|this|the\s+(?:sketch|drawing|diagram))(?:\s+on(?:\s+(?:the|my))?\s+screen)?"#
            + #"|leave\s+(?:it|that|the\s+(?:sketch|drawing|diagram))\s+on(?:\s+(?:the|my))?\s+screen"#
            + #"|pin\s+(?:it|that|this)"#
            + #"|(?:don'?t|do\s+not)\s+(?:clear|remove|erase)\s+(?:it|that))"#
        return matches(transcript, lead + core + tail)
    }

    /// "undo that", "undo the last part".
    public static func wantsUndo(_ transcript: String) -> Bool {
        matches(transcript, lead + #"undo\s+(?:that|the\s+last\s+(?:part|step|bit|thing|one)|last\s+(?:part|step))"# + tail)
    }

    /// "describe the sketch", "what did you draw", "read back the drawing".
    public static func wantsDescribe(_ transcript: String) -> Bool {
        let core = #"(?:(?:describe|read(?:\s+back)?)\s+(?:me\s+)?(?:the|this|that|your)\s+(?:sketch|drawing|diagram)"#
            + #"|(?:tell\s+me\s+)?what\s+(?:did|have)\s+you\s+(?:just\s+)?(?:draw|drawn|sketch|sketched|made|make)"#
            + #"|tell\s+me\s+what\s+you\s+(?:just\s+)?(?:drew|sketched|drawn)"#
            + #"|what(?:'s|\s+is)\s+(?:in|on)\s+(?:the|your)\s+(?:sketch|drawing|diagram))"#
        return matches(transcript, lead + core + tail)
    }

    /// "add the curb", "label the car", "show the next step", "draw the stop line too", "also draw ...".
    /// Only with a kept sketch. "add a reminder", "add two to that" and "add milk to my list" are not it.
    public static func wantsExtend(_ transcript: String) -> Bool {
        let text = normalised(transcript)
        let objectNouns = "reminders?|events?|notes?|tasks?|todos?|contacts?|alarms?|timers?|appointments?|meetings?|items?|songs?|emails?|passwords?|accounts?|calendars?|tabs?|bookmarks?|numbers?"
        let notDrawing = [
            #"\badd\s+(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|up|these|them|it\s+up)\b"#,
            #"\badd\s+(?:an?\s+|the\s+|my\s+)?(?:\#(objectNouns))\b"#,
            #"\bto\s+(?:my|the)\s+(?:list|lists|calendar|cart|reminders?|notes?|contacts?|playlist|queue|bookmarks?|favou?rites|shopping|basket|wishlist)\b"#,
        ]
        let isAddOrLabel = text.range(of: lead + #"(?:add|label)\b"#, options: .regularExpression) != nil
        if isAddOrLabel { return !notDrawing.contains { text.range(of: $0, options: .regularExpression) != nil } }
        let others = [
            lead + #"(?:show|draw|do|give|sketch)(?:\s+me)?(?:\s+the)?\s+next\s+(?:step|part|bit)\b"#,
            #"\b(?:draw|sketch|show|add)\b.*\b(?:too|as\s+well)[\s.!?]*$"#,
            lead + #"also\s+(?:draw|add|show|label|sketch)\b"#,
            lead + #"(?:extend|continue)\s+(?:the|this|that)\s+(?:sketch|drawing|diagram)\b"#,
        ]
        return others.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func normalised(_ transcript: String) -> String {
        transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ transcript: String, _ pattern: String) -> Bool {
        normalised(transcript).range(of: pattern, options: .regularExpression) != nil
    }
}
