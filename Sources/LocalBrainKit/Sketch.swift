//
//  Sketch.swift
//  LocalBrainKit
//
//  A sketch turn: "draw tic tac toe on the screen", "draw a smiley face". The
//  drawing marks nothing, so it is not a mark turn. The app composes every named
//  figure itself (SketchTemplate), in screenshot pixels, so there is no model
//  call and no coordinate risk; the model writes tags only for a figure with no
//  template (SketchFigure.freeform), and that path can be turned off with
//  SketchLimits.freeformEnabled. Only reachable while drawing is on, through
//  DrawingRouting.
//
//  SketchIntent returns nil whenever the words name something on the screen to
//  draw at ("around the error", "to the menu", "it"): those stay mark turns.
//

import CoreGraphics
import Foundation

public enum SketchFigure: Equatable, Sendable {
    case ticTacToe, box, line, arrow, circle, triangle, star, smiley, cross, check
    /// "a house", "a flowchart with three boxes": no template, the model draws it.
    case freeform(String)
}

public enum SketchLimits {
    /// One switch for the model-written path. When false, a figure with no template
    /// is answered with SketchTemplate.unsupportedSentence and no model call.
    public static let freeformEnabled = true
    /// The most tags a freeform sketch may draw.
    public static let maxTags = 8
    /// The prompt asks for no more than this many tokens: 8 tags and one sentence.
    public static let freeformAnswerMaxTokens = 400
    /// Spoken when the model's reply holds no valid tag.
    public static let failureSentence = "i could not draw that one."

    /// Spoken when tags closed but the reply holds no sentence (the prompt asks for one; a screen reader user needs it).
    public static let drawnSentence = "here is the drawing, in the middle of your screen."

    /// What a freeform sketch speaks: the failure sentence with no valid tag, else the reply's own words with
    /// every complete tag removed and a tag cut off by the token cap dropped, else `drawnSentence`.
    public static func spokenSentence(in reply: String, closedTags: Int) -> String {
        guard closedTags > 0 else { return failureSentence }
        let words = ShapeTagParser.stripAllTags(from: reply)
            .replacingOccurrences(of: #"\[[^\[\]]*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? drawnSentence : words
    }

    /// Whether a freeform sketch may draw this tag: shapes only (the prompt has no HIGHLIGHT) and at most `maxTags`.
    public static func admits(_ drawing: InkDrawing, alreadyClosed: Int) -> Bool {
        guard case .shape = drawing else { return false }
        return alreadyClosed < maxTags
    }
}

public enum SketchTiming {
    /// A sketch is the point of its turn, so it stays this long after the speech
    /// (a mark that accompanies a sentence holds 1.5 s). A key press or "clear that" ends it sooner.
    public static let holdSeconds: Double = 10
}

public enum SketchIntent {
    /// The figure the words ask to draw, or nil when they do not ask for a sketch.
    public static func figure(_ transcript: String) -> SketchFigure? {
        var text = transcript.lowercased()
        // "draw up", "draw conclusions" and "draw attention" are not drawing.
        guard text.range(of: #"\bdraw\s+(?:up|conclusions?|attention)\b"#, options: .regularExpression) == nil else { return nil }
        for placement in placements {
            text = text.replacingOccurrences(of: placement, with: " ", options: .regularExpression)
        }
        // A target cue means the words draw at something on the screen: a mark turn.
        guard targetCues.allSatisfy({ text.range(of: $0, options: .regularExpression) == nil }) else { return nil }
        guard let verb = text.range(of: #"\b(?:draw|sketch|doodle)\b"#, options: .regularExpression) else { return nil }

        let afterVerb = text[verb.upperBound...].replacingOccurrences(of: #"[^a-z' -]"#, with: " ", options: .regularExpression)
        var words = afterVerb.split(separator: " ").map(String.init)
        if let first = words.first, ["a", "an", "the", "some"].contains(first) { words.removeFirst() }
        guard !words.isEmpty else { return nil }
        let phrase = words.prefix(4).joined(separator: " ")
        for (pattern, figure) in named where phrase.range(of: pattern, options: .regularExpression) != nil {
            return figure
        }
        return .freeform(phrase)
    }

    /// Where on the screen and how big: not targets, so they are dropped before the cue check.
    private static let placements: [String] = [
        #"\b(?:on|in|at|across|over|onto)\s+(?:the|my)\s+(?:(?:top|bottom|left|right|middle|center|centre)\s+)*(?:screen|display|desktop|corner|middle|center|centre|top|bottom|left|right)(?:\s+of\s+(?:the|my)\s+(?:screen|display|desktop))?\b"#,
        #"\b(?:top|bottom)\s+(?:left|right)\b"#,
        #"\bin the middle\b"#,
        #"\b(?:big|large|huge|small|tiny|little|quick|simple)\b"#,
        #"\bfor me\b|\bme\b"#,
    ]

    private static let targetCues: [String] = [
        #"\b(?:it|this|that|them|these|those|here)\b"#,
        #"\b(?:around|under|underneath|over|above|below|beside|next to|near|at|to|toward|towards|through|on|onto|pointing (?:at|to))\s+(?:the|this|that|my|those|these|it|them)\b"#,
        #"\b(?:button|menu|icon|field|tab|link|word|line of|error|title|total|price|name)\b"#,
    ]

    /// The head of the phrase after the verb decides the figure; anything else is freeform.
    private static let named: [(String, SketchFigure)] = [
        (#"^(?:tic[ -]?tac[ -]?toe|noughts and crosses|grid)\b"#, .ticTacToe),
        (#"^(?:box|square|rectangle)\b"#, .box),
        (#"^line\b"#, .line),
        (#"^arrow\b"#, .arrow),
        (#"^(?:circle|ring)\b"#, .circle),
        (#"^triangle\b"#, .triangle),
        (#"^star\b"#, .star),
        (#"^(?:smiley|happy face|face)\b"#, .smiley),
        (#"^(?:cross|x)\b"#, .cross),
        (#"^(?:check ?mark|check|tick)\b"#, .check),
    ]
}

public enum ClearMarksIntent {
    /// "clear that", "erase the drawing", "wipe the board". False for a clear
    /// that is about something else ("clear my inbox", "clear the cache"), and for
    /// a bare "that" after remove, undo or get rid of ("undo that" after a click
    /// turn undoes nothing that was drawn): those verbs need a drawing object.
    public static func wants(_ transcript: String) -> Bool {
        let text = transcript.lowercased()
        let drawing = "the screen|that drawing|the drawings?|your drawings?|the sketch|the marks|your marks|what you drew|the board|the grid|tic tac toe"
        let tail = #"(?:\s+(?:please|now|again|for me))?[\s.!?]*$"#
        let withObject = #"\b(?:clear|erase|wipe|remove|get rid of|undo)\s+(?:all\s+)?(?:of\s+)?(?:\#(drawing))"# + tail
        let bareThat = #"\b(?:clear|erase|wipe)\s+that"# + tail
        return [withObject, bareThat].contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

/// What the app draws for a template figure: the marks, in screenshot pixels, and the one sentence
/// that says what they are (the whole content for someone who cannot see the screen).
public struct SketchPlan: Equatable, Sendable {
    public let drawings: [InkDrawing]
    public let spokenSentence: String

    public init(drawings: [InkDrawing], spokenSentence: String) {
        self.drawings = drawings
        self.spokenSentence = spokenSentence
    }
}

public enum SketchTemplate {
    /// The tic tac toe board's side, as a fraction of the shorter side of the screenshot.
    public static let sideFraction = 0.5
    /// The side or span of the other figures, as a fraction of the shorter side.
    public static let figureFraction = 0.35
    /// 9 cells, row-major: O top left, X centre, X bottom right.
    public static let defaultBoard = "O...X...X"
    /// Spoken when a figure has no template and the model-written path is off.
    public static let unsupportedSentence = "i can draw a box, a line, an arrow, a circle, a triangle, a star, a smiley or tic tac toe."

    /// Nil for `.freeform`: the model draws that one.
    public static func plan(_ figure: SketchFigure, imageWidth: Int, imageHeight: Int, board: String = defaultBoard) -> SketchPlan? {
        let width = Double(imageWidth), height = Double(imageHeight)
        let m = min(width, height)
        let cx = width / 2, cy = height / 2
        func shape(_ kind: ShapeKind, _ points: [(Double, Double)]) -> InkDrawing {
            .shape(ShapeTag(kind: kind, points: points.map { CGPoint(x: $0.0, y: $0.1) }, label: nil, screenNumber: nil))
        }
        func plan(_ drawings: [InkDrawing], _ sentence: String) -> SketchPlan {
            SketchPlan(drawings: drawings, spokenSentence: sentence)
        }
        switch figure {
        case .freeform:
            return nil
        case .ticTacToe:
            return ticTacToe(board: board, imageWidth: imageWidth, imageHeight: imageHeight)
        case .box:
            let h = figureFraction * m / 2
            return plan([shape(.polygon, [(cx - h, cy - h), (cx + h, cy - h), (cx + h, cy + h), (cx - h, cy + h)])],
                        "here is a square box in the middle of your screen.")
        case .line:
            return plan([shape(.line, [(cx - 0.2 * m, cy), (cx + 0.2 * m, cy)])],
                        "here is a straight line across the middle of your screen.")
        case .arrow:
            return plan([shape(.arrow, [(cx, cy + 0.17 * m), (cx, cy - 0.17 * m)])],
                        "here is an arrow in the middle of your screen, pointing up.")
        case .circle:
            return plan([shape(.circle, [(cx, cy), (cx + 0.175 * m, cy)])],
                        "here is a circle in the middle of your screen.")
        case .triangle:
            let h = figureFraction * m / 2
            return plan([shape(.polygon, [(cx, cy - h), (cx + h, cy + h), (cx - h, cy + h)])],
                        "here is a triangle in the middle of your screen.")
        case .star:
            let corners = (0..<10).map { index -> (Double, Double) in
                let radius = (index % 2 == 0 ? 0.2 : 0.08) * m
                let angle = (Double(index) * 36 - 90) * .pi / 180
                return (cx + radius * cos(angle), cy + radius * sin(angle))
            }
            return plan([shape(.polygon, corners)], "here is a star in the middle of your screen.")
        case .smiley:
            let eyeY = cy - 0.07 * m
            let mouth = [30.0, 60, 90, 120, 150].map { degrees -> (Double, Double) in
                (cx + 0.12 * m * cos(degrees * .pi / 180), cy + 0.12 * m * sin(degrees * .pi / 180))
            }
            return plan([shape(.circle, [(cx, cy), (cx + 0.2 * m, cy)]),
                         shape(.circle, [(cx - 0.075 * m, eyeY), (cx - 0.075 * m + 0.025 * m, eyeY)]),
                         shape(.circle, [(cx + 0.075 * m, eyeY), (cx + 0.075 * m + 0.025 * m, eyeY)]),
                         shape(.curve, mouth)],
                        "here is a smiley face in the middle of your screen.")
        case .cross:
            let h = 0.175 * m
            return plan([shape(.line, [(cx - h, cy - h), (cx + h, cy + h)]),
                         shape(.line, [(cx + h, cy - h), (cx - h, cy + h)])],
                        "here is a cross in the middle of your screen.")
        case .check:
            return plan([shape(.line, [(cx - 0.15 * m, cy), (cx - 0.05 * m, cy + 0.12 * m)]),
                         shape(.line, [(cx - 0.05 * m, cy + 0.12 * m), (cx + 0.18 * m, cy - 0.14 * m)])],
                        "here is a check mark in the middle of your screen.")
        }
    }

    static let cellNames = ["top left", "top", "top right", "left", "centre", "right", "bottom left", "bottom", "bottom right"]

    /// The board is 9 characters, row-major: `X`, `O`, anything else is an empty cell (a short
    /// board is padded). The grid is four lines, then the moves in play order: X first, then
    /// alternating, each side's moves in cell order.
    static func ticTacToe(board: String, imageWidth: Int, imageHeight: Int) -> SketchPlan {
        let side = sideFraction * Double(min(imageWidth, imageHeight))
        let x0 = (Double(imageWidth) - side) / 2, y0 = (Double(imageHeight) - side) / 2
        let cell = side / 3
        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> InkDrawing {
            .shape(ShapeTag(kind: .line, points: [CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)], label: nil, screenNumber: nil))
        }
        var drawings = [line(x0 + cell, y0, x0 + cell, y0 + side), line(x0 + 2 * cell, y0, x0 + 2 * cell, y0 + side),
                        line(x0, y0 + cell, x0 + side, y0 + cell), line(x0, y0 + 2 * cell, x0 + side, y0 + 2 * cell)]

        let cells = Array(board.uppercased().prefix(9)) + Array(repeating: Character("."), count: max(0, 9 - board.count))
        let xs = cells.indices.filter { cells[$0] == "X" }, os = cells.indices.filter { cells[$0] == "O" }
        var moves: [(mark: Character, index: Int)] = []
        for turn in 0..<max(xs.count, os.count) {
            if turn < xs.count { moves.append(("X", xs[turn])) }
            if turn < os.count { moves.append(("O", os[turn])) }
        }
        var spoken: [String] = []
        for move in moves {
            let centreX = x0 + (Double(move.index % 3) + 0.5) * cell, centreY = y0 + (Double(move.index / 3) + 0.5) * cell
            let half = 0.3 * cell
            if move.mark == "X" {
                drawings.append(line(centreX - half, centreY - half, centreX + half, centreY + half))
                drawings.append(line(centreX + half, centreY - half, centreX - half, centreY + half))
            } else {
                drawings.append(.shape(ShapeTag(kind: .circle, points: [CGPoint(x: centreX, y: centreY), CGPoint(x: centreX + half, y: centreY)],
                                                label: nil, screenNumber: nil)))
            }
            spoken.append("an \(move.mark == "X" ? "x" : "o") in the \(cellNames[move.index])")
        }
        let start = "here is a tic tac toe board in the middle of your screen"
        let sentence: String
        switch spoken.count {
        case 0: sentence = start + ", with no moves yet."
        case 1: sentence = start + ", with \(spoken[0])."
        default: sentence = start + ", with \(spoken.dropLast().joined(separator: ", ")) and \(spoken[spoken.count - 1])."
        }
        return SketchPlan(drawings: drawings, spokenSentence: sentence)
    }
}
