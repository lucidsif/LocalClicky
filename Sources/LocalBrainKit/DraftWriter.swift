//
//  DraftWriter.swift
//  LocalBrainKit
//
//  Writes the body of a draft from the gist. The model call is injected (the app passes the same
//  gateway client chat uses, with the draft model), so this stays pure and testable. Run before any
//  page step.
//
//  The Studio connection may be off: the gateway then answers HTTP 503, and the writer falls back
//  to the gist itself, lightly cleaned, as the body. The fallback is a normal path, not an error:
//  it carries a reason and a short spoken line saying the body is the user's own words. A model
//  answer is trimmed, stripped of a subject line or quotes, and cut at 2000 characters.
//

import Foundation

public enum DraftFallbackReason: String, Equatable, Sendable {
    case studioOff = "studio-off"
    case failed
    case emptyOutput = "empty-output"
    case timedOut = "timed-out"
    case cancelled
}

public struct DraftBody: Equatable, Sendable {
    public let text: String
    public let usedModel: Bool
    public let fallbackReason: DraftFallbackReason?
    public let millis: Int
}

public enum DraftWriter {
    public static let maxBodyCharacters = 2000
    public static let defaultTimeoutSeconds = 30.0

    /// The default model, a config value (the app stores it in ModelPreferences). Same gateway as chat.
    public static let defaultModel = "studio:clicky"

    /// Spoken when the fallback body is used. Short, and says why.
    public static let studioOffLine = "the studio model is off, so the body is your words."
    public static let failedLine = "the writer did not answer, so the body is your words."

    public static func spokenLine(for reason: DraftFallbackReason) -> String {
        reason == .studioOff ? studioOffLine : failedLine
    }

    public typealias Generate = @Sendable (_ system: String, _ user: String) async throws -> String

    /// Asks the model for the body; on any failure, returns the cleaned gist instead.
    public static func write(gist: String, recipient: Recipient, quotedMessage: String? = nil, userName: String = "",
                             timeoutSeconds: Double = defaultTimeoutSeconds,
                             clock: @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                             generate: @escaping Generate) async -> DraftBody {
        let started = clock()
        func finished(_ text: String, model: Bool, reason: DraftFallbackReason?) -> DraftBody {
            DraftBody(text: text, usedModel: model, fallbackReason: reason, millis: Int((clock() - started) * 1000))
        }
        let system = quotedMessage == nil ? DraftPrompts.system(userName: userName) : DraftPrompts.replySystem(userName: userName)
        let user = DraftPrompts.user(recipient: recipient, gist: gist, quotedMessage: quotedMessage)
        let outcome = await race(timeoutSeconds: timeoutSeconds) { try await generate(system, user) }
        switch outcome {
        case .success(let output):
            let body = clean(modelOutput: output)
            if body.isEmpty { return finished(fallbackBody(gist: gist), model: false, reason: .emptyOutput) }
            return finished(body, model: true, reason: nil)
        case .failure(let error):
            return finished(fallbackBody(gist: gist), model: false, reason: classify(error))
        }
    }

    // MARK: - Failures

    struct TimedOut: Error {}

    /// 503 or the gateway's "studio connection is off" text means the Studio is off; a timeout and a
    /// cancel are their own; anything else is a plain failure.
    static func classify(_ error: Error) -> DraftFallbackReason {
        if error is TimedOut { return .timedOut }
        if error is CancellationError { return .cancelled }
        if let ollama = error as? OllamaError, case .httpStatus(let code, let body) = ollama {
            if code == 503 || body.lowercased().contains("studio connection is off") { return .studioOff }
        }
        return .failed
    }

    private static func race(timeoutSeconds: Double,
                             _ work: @escaping @Sendable () async throws -> String) async -> Result<String, Error> {
        guard timeoutSeconds > 0 else {
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        return await withTaskGroup(of: Result<String, Error>.self) { group in
            group.addTask {
                do { return .success(try await work()) } catch { return .failure(error) }
            }
            group.addTask {
                do { try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)) }
                catch { return .failure(CancellationError()) }
                return .failure(TimedOut())
            }
            let first = await group.next() ?? .failure(CancellationError())
            group.cancelAll()
            return first
        }
    }

    // MARK: - Text

    /// The model's answer made fit to put in a draft: no wrapping quotes or code fence, no "subject:" first
    /// line, trimmed, cut at `maxBodyCharacters` on a word.
    static func clean(modelOutput: String) -> String {
        var text = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.drop(while: { $0 == "`" }).drop(while: { !$0.isNewline }).trimmingCharacters(in: .whitespacesAndNewlines)
            if let fence = text.range(of: "```") { text = String(text[..<fence.lowerBound]) }
        }
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.lowercased().hasPrefix("subject:") { lines.removeFirst() }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 1 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cut(text)
    }

    private static func cut(_ text: String) -> String {
        guard text.count > maxBodyCharacters else { return text }
        let head = String(text.prefix(maxBodyCharacters))
        if let space = head.lastIndex(where: \.isWhitespace) { return String(head[..<space]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return head
    }

    /// The gist as an email body when no model wrote one: whitespace collapsed, "i" and "i'm" capitalised, the
    /// first letter capitalised, and a full stop at the end when there is no end mark.
    public static func fallbackBody(gist: String) -> String {
        var text = gist.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "" }
        text = text.replacingOccurrences(of: #"\bi\b(?!\.\w)"#, with: "I", options: .regularExpression)
        if let first = text.first { text = first.uppercased() + text.dropFirst() }
        if let last = text.last, !".!?".contains(last) { text += "." }
        return cut(text)
    }
}
