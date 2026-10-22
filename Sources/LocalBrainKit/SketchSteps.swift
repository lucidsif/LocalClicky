//
//  SketchSteps.swift
//  LocalBrainKit
//
//  Reads the reply of a freeform step sketch (SketchPrompts.stepSketch) into steps. A step is one
//  spoken sentence and the SHAPE tags drawn with it. SketchStepStream reads the reply as it streams and
//  hands over each step once it is complete (SketchStepParser.parse is the same stream fed the whole
//  reply, so the two cannot differ). CompanionManager closes a step's marks, then queues its sentence,
//  as each step arrives, so the marks bind to their own sentence.
//
//  Format: `[STEP] sentence` then the step's tags, one per line. Tag order inside a step does not
//  matter. Forgiving where that costs nothing:
//    - a reply with no [STEP] marker is one step (the old tags-then-sentence shape still works);
//    - tags before the first marker are a step of their own, words before it are dropped;
//    - a chunk with neither a sentence nor a valid tag is not a step.
//  Never guessed: a complete tag that does not validate, a HIGHLIGHT (a sketch marks nothing), and
//  anything past maxSteps steps or maxStepTags tags is dropped and counted, not repaired.
//

import CoreGraphics
import Foundation

public struct SketchStep: Equatable, Sendable {
    /// The spoken sentence. Empty when the step had none.
    public let sentence: String
    /// The step's shapes in the order written, labels already cut to SketchLimits.maxLabelWords.
    public let shapes: [ShapeTag]

    public init(sentence: String, shapes: [ShapeTag]) {
        self.sentence = sentence
        self.shapes = shapes
    }
}

public struct SketchReply: Equatable, Sendable {
    public let steps: [SketchStep]
    /// Complete tags that were not kept: invalid, HIGHLIGHT, or over a limit.
    public let droppedTags: Int

    public var tagCount: Int { steps.reduce(0) { $0 + $1.shapes.count } }
    public var labelCount: Int { steps.reduce(0) { $0 + $1.shapes.filter { $0.label != nil }.count } }
    /// What the app speaks when nothing could be drawn.
    public var isEmpty: Bool { tagCount == 0 }
}

/// Reads a step sketch reply as it streams. Feed it the accumulated text after every chunk; it returns
/// each step exactly once, as soon as the step is complete, which is when the next `[STEP]` marker has
/// fully arrived (its closing bracket included) or, for the last step, when `finish` is called. A tag or a
/// marker cut off at a chunk boundary is therefore never parsed early: the step it belongs to is still the
/// open one, and only closed steps are read. Like StreamingShapeDetector it assumes the text only grows by
/// appending, and it is safe to call from the streaming callback's thread.
///
/// The limits (steps, tags) are applied across the steps in the order they complete, exactly as
/// `SketchStepParser.parse` does: that function is this class fed the whole reply, so a reply read in
/// chunks and read whole give the same steps.
public final class SketchStepStream: @unchecked Sendable {
    private static let markerRegex = try! NSRegularExpression(pattern: #"\[STEP\b[^\[\]]*\]"#, options: [.caseInsensitive])

    private let lock = NSLock()
    private let maxSteps: Int
    private let maxTags: Int
    private var consumedMarkers = 0
    private var kept: [SketchStep] = []
    private var dropped = 0
    private var tagsKept = 0
    private var finished = false

    public init(maxSteps: Int = SketchLimits.maxSteps, maxTags: Int = SketchLimits.maxStepTags) {
        self.maxSteps = maxSteps
        self.maxTags = maxTags
    }

    /// The steps that completed with this text and were not returned before. Empty on most calls.
    public func feed(accumulated: String) -> [SketchStep] {
        lock.lock(); defer { lock.unlock() }
        return completeSteps(in: accumulated)
    }

    /// The stream ended: the open step is complete too. Returns it (and any step `feed` has not).
    public func finish(accumulated: String) -> [SketchStep] {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return [] }
        var steps = completeSteps(in: accumulated)
        finished = true
        let markers = Self.markerRegex.matches(in: accumulated, range: NSRange(accumulated.startIndex..., in: accumulated))
        // No marker at all: the whole reply is one step (the old tags-then-sentence shape).
        let start = markers.last.flatMap { Range($0.range, in: accumulated)?.upperBound } ?? accumulated.startIndex
        if let step = process(String(accumulated[start...]), isPreamble: false) { steps.append(step) }
        return steps
    }

    /// Everything kept so far, and what was dropped.
    public var reply: SketchReply {
        lock.lock(); defer { lock.unlock() }
        return SketchReply(steps: kept, droppedTags: dropped)
    }

    private func completeSteps(in text: String) -> [SketchStep] {
        let markers = Self.markerRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard markers.count > consumedMarkers else { return [] }
        var steps: [SketchStep] = []
        for index in consumedMarkers..<markers.count {
            guard let end = Range(markers[index].range, in: text) else { continue }
            let start = index == 0 ? text.startIndex : (Range(markers[index - 1].range, in: text)?.upperBound ?? text.startIndex)
            // Words before the first marker are dropped unless they hold a tag.
            if let step = process(String(text[start..<end.lowerBound]), isPreamble: index == 0) { steps.append(step) }
        }
        consumedMarkers = markers.count
        return steps
    }

    /// One complete block of text as a step, applying the limits. Nil when it holds no step.
    private func process(_ chunk: String, isPreamble: Bool) -> SketchStep? {
        let (shapes, invalid) = SketchStepParser.shapes(in: chunk)
        if isPreamble, shapes.isEmpty, invalid == 0 { return nil }
        let sentence = SketchStepParser.sentence(in: chunk)
        dropped += invalid
        guard !shapes.isEmpty || !sentence.isEmpty else { return nil }
        if kept.count >= maxSteps {
            dropped += shapes.count
            return nil
        }
        let room = max(0, maxTags - tagsKept)
        dropped += max(0, shapes.count - room)
        let keptShapes = shapes.prefix(room).map(SketchStepParser.cutLabel)
        tagsKept += keptShapes.count
        let step = SketchStep(sentence: sentence, shapes: Array(keptShapes))
        kept.append(step)
        return step
    }
}

public enum SketchStepParser {
    /// The whole reply at once: the stream fed everything. Tags but not one sentence anywhere get
    /// `SketchLimits.drawnSentence` on the first step, as the one-step sketch always said it drew something.
    public static func parse(_ reply: String,
                             maxSteps: Int = SketchLimits.maxSteps,
                             maxTags: Int = SketchLimits.maxStepTags) -> SketchReply {
        let stream = SketchStepStream(maxSteps: maxSteps, maxTags: maxTags)
        _ = stream.feed(accumulated: reply)
        _ = stream.finish(accumulated: reply)
        let result = stream.reply
        guard needsDrawnSentence(result) else { return result }
        var steps = result.steps
        steps[0] = SketchStep(sentence: SketchLimits.drawnSentence, shapes: steps[0].shapes)
        return SketchReply(steps: steps, droppedTags: result.droppedTags)
    }

    /// Tags were kept but no step has a sentence.
    public static func needsDrawnSentence(_ reply: SketchReply) -> Bool {
        reply.tagCount > 0 && !reply.steps.contains(where: { !$0.sentence.isEmpty })
    }

    /// The valid shapes of a chunk, and how many complete tags were not valid shapes.
    static func shapes(in chunk: String) -> ([ShapeTag], Int) {
        var shapes: [ShapeTag] = []
        var invalid = 0
        let matches = ShapeTagParser.drawingRegex.matches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk))
        for match in matches {
            guard let range = Range(match.range, in: chunk),
                  case .shape(let tag)? = ShapeTagParser.parseTag(String(chunk[range])) else { invalid += 1; continue }
            shapes.append(tag)
        }
        return (shapes, invalid)
    }

    /// The chunk's words: complete tags removed, a tag cut off by the token cap removed, whitespace
    /// (including line breaks) collapsed.
    static func sentence(in chunk: String) -> String {
        ShapeTagParser.stripAllTags(from: chunk)
            .replacingOccurrences(of: #"\[[^\[\]]*$"#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// A label is at most maxLabelWords words; the screen number a sketch cannot use is dropped.
    static func cutLabel(_ tag: ShapeTag) -> ShapeTag {
        let words = (tag.label ?? "").split(whereSeparator: { $0.isWhitespace }).prefix(SketchLimits.maxLabelWords)
        let label = words.isEmpty ? nil : words.joined(separator: " ")
        return ShapeTag(kind: tag.kind, points: tag.points, label: label, screenNumber: nil)
    }
}
