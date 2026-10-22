//
//  SpeechMarkScheduler.swift
//  LocalBrainKit
//
//  Ink out, timed to speech. A mark (a circle, an arrow...) should appear as
//  the words about it are spoken, not when its tag happens to close in the
//  stream, which can be seconds before the voice reaches that sentence.
//
//  This is the pure state machine for that. It knows nothing about audio or
//  clocks: the caller passes the time with each event and asks which marks are
//  due.
//
//    markClosed      a tag closed in the stream. The mark waits.
//    sentenceQueued  a sentence went to the speech queue. Every mark closed
//                    since the previous sentence binds to it, so a tag-first
//                    beat line ("[SHAPE ...] that is the save button.") binds
//                    to its own sentence. A sentence with no waiting mark is
//                    simply ignored.
//    clipStarted     the speech client reports that a sentence's clip started
//                    playing. Its marks become due.
//    release         the marks that are due, in the order their tags closed.
//    cancel          barge-in or a new press: everything waiting is dropped.
//
//  When a mark becomes due:
//    - clip started with audibleIn == 0: now. A client cannot announce a clip
//      before it plays, so there is no way to show the mark ahead of its words
//      and the lead is not applied (nothing is subtracted).
//    - clip started with audibleIn > 0 (the client knows audio is coming that
//      long after the notification, as with the silence the Piper client puts
//      in front of a cold start): now + max(0, audibleIn - lead), so the mark
//      lands `lead` seconds before the first word.
//    - no start notification within `startTimeout` of the tag closing (the
//      speech failed, the text was empty, or no sentence ever followed the
//      tag): at closing time + `startTimeout`. A mark is never held longer.
//
//  Marks are released strictly in closing order. Each mark's own timeout is at
//  least as late as every earlier mark's, so ordering never holds one past its
//  own timeout.
//
//  Hold mode (`holdsBoundMarks`, off by default, used by step sketches). A step
//  sketch closes each step's marks and queues its sentence as the step streams
//  in, so step 3's clip starts seconds after its marks closed (the clips play
//  one after another). The timeout above would show step 3 during step 1. In hold mode a
//  mark bound to a sentence has no timeout: it waits for its clip, or for any
//  later clip to start (a clip whose synthesis failed never announces itself,
//  and a later clip starting proves the earlier ones are over). Marks that no
//  sentence ever bound keep the timeout. Because a held mark can wait forever if
//  speech fails, the caller ends the wait with `flush` once the speech has had
//  its chance (see CompanionManager.startMarkDriver).
//

import Foundation

public enum SpeechMarkTiming {
    /// How long before the first word a mark appears, when the clip's start is
    /// known that far ahead (see the file comment for when it is not).
    public static let lead: Double = 0.15
    /// A mark appears this long after its tag closed even if no start
    /// notification arrived.
    public static let startTimeout: Double = 1.5
}

public struct SpeechMarkScheduler<Mark> {
    private struct Entry {
        let mark: Mark
        var clip: Int?
        var dueAt: Double
    }

    private var entries: [Entry] = []
    private var nextClipID: Int
    private let holdsBoundMarks: Bool
    public private(set) var closedCount = 0
    public private(set) var releasedCount = 0

    public init(firstClipID: Int = 1, holdsBoundMarks: Bool = false) {
        nextClipID = firstClipID
        self.holdsBoundMarks = holdsBoundMarks
    }

    /// True in hold mode: a bound mark waits for its clip with no timeout.
    public var isHolding: Bool { holdsBoundMarks }

    /// Marks waiting to be shown.
    public var pendingCount: Int { entries.count }
    public var hasPending: Bool { !entries.isEmpty }

    /// The earliest moment `release` could return something, or nil when
    /// nothing waits. The front of the line sets it, since marks leave in order.
    public var nextDueTime: Double? { entries.first?.dueAt }

    public mutating func markClosed(_ mark: Mark, at now: Double) {
        closedCount += 1
        entries.append(Entry(mark: mark, clip: nil, dueAt: now + SpeechMarkTiming.startTimeout))
    }

    /// Mints the id for the next queued sentence and binds every unbound
    /// waiting mark to it. The caller hands the id to the speech client with
    /// the sentence.
    @discardableResult
    public mutating func sentenceQueued() -> Int {
        let id = nextClipID
        nextClipID += 1
        for index in entries.indices where entries[index].clip == nil {
            entries[index].clip = id
            if holdsBoundMarks { entries[index].dueAt = .infinity }
        }
        return id
    }

    /// The clip for `id` started playing; `audibleIn` is how long after that
    /// the first word is heard (0 when unknown).
    public mutating func clipStarted(id: Int, audibleIn: Double = 0, at now: Double) {
        let due = now + max(0, audibleIn - SpeechMarkTiming.lead)
        for index in entries.indices {
            guard let clip = entries[index].clip else { continue }
            if clip == id {
                entries[index].dueAt = min(entries[index].dueAt, due)
            } else if holdsBoundMarks, clip < id {
                // An earlier clip never announced itself; a later one playing means it is over.
                entries[index].dueAt = min(entries[index].dueAt, now)
            }
        }
    }

    /// Makes every waiting mark due at `now`, in their order. Hold mode's end of the wait:
    /// the speech finished or never started, so nothing more will announce a clip.
    public mutating func flush(at now: Double) {
        for index in entries.indices { entries[index].dueAt = min(entries[index].dueAt, now) }
    }

    /// The marks due at `now`, oldest first. They are removed from the line.
    public mutating func release(at now: Double) -> [Mark] {
        var due: [Mark] = []
        while let first = entries.first, first.dueAt <= now {
            due.append(first.mark)
            entries.removeFirst()
        }
        releasedCount += due.count
        return due
    }

    /// Drops everything waiting (barge-in or a new press). Returns how many.
    @discardableResult
    public mutating func cancel() -> Int {
        let dropped = entries.count
        entries.removeAll()
        return dropped
    }
}

/// The scheduler behind a lock, for the streaming callback's thread (which
/// closes marks and queues sentences, in text order) and the main actor (which
/// releases them and hears the clip starts). One lock means the order the
/// stream produced is the order the machine sees.
public final class SpeechMarkSchedulerBox<Mark>: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduler: SpeechMarkScheduler<Mark>
    private var inputFinished = false
    private var speechQueued = false
    private var cancelled = false
    private let clock: @Sendable () -> Double

    public init(firstClipID: Int = 1,
                holdsBoundMarks: Bool = false,
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        scheduler = SpeechMarkScheduler(firstClipID: firstClipID, holdsBoundMarks: holdsBoundMarks)
        self.clock = clock
    }

    /// True in hold mode (see SpeechMarkScheduler).
    public var isHolding: Bool { scheduler.isHolding }

    /// Every waiting mark is shown at the next release (see SpeechMarkScheduler.flush).
    public func flush() {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        scheduler.flush(at: now)
    }

    public func markClosed(_ mark: Mark) {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        scheduler.markClosed(mark, at: now)
    }

    /// The id to give the speech client for this sentence.
    public func sentenceQueued() -> Int {
        lock.lock(); defer { lock.unlock() }
        return scheduler.sentenceQueued()
    }

    public func clipStarted(id: Int, audibleIn: Double = 0) {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        scheduler.clipStarted(id: id, audibleIn: audibleIn, at: now)
    }

    public func release() -> [Mark] {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        return scheduler.release(at: now)
    }

    /// The stream has produced everything it will; no more marks will close.
    public func finishInput() {
        lock.lock(); defer { lock.unlock() }
        inputFinished = true
    }

    /// Every sentence of the turn has been handed to the speech client (hold mode's cue that the clip
    /// starts it is waiting for are all that can still come).
    public func markSpeechQueued() {
        lock.lock(); defer { lock.unlock() }
        speechQueued = true
    }

    public var isSpeechQueued: Bool {
        lock.lock(); defer { lock.unlock() }
        return speechQueued
    }

    /// Barge-in or a new press: drops what waits and ignores later marks.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        scheduler.cancel()
    }

    public var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduler.hasPending
    }

    /// True when nothing is waiting and nothing more can arrive.
    public var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return (inputFinished || cancelled) && !scheduler.hasPending
    }

    /// How many marks closed this turn (shown, waiting, or dropped by a cancel).
    public var closedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return scheduler.closedCount
    }

    public var releasedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return scheduler.releasedCount
    }
}
