//
//  AttemptGate.swift
//  LocalBrainKit
//
//  Decides whether to try a flaky one-time call for a key now. A key that succeeded is done for
//  good; a key that failed may be tried again, but no sooner than `minimumGapSeconds` after the
//  last try, so a polling loop does not hammer it. Pure; the caller supplies the clock.
//  Used for telling a Chromium browser an assistive client is reading: the first call can land
//  while the browser is still starting and fail.
//

import Foundation

public struct AttemptGate<Key: Hashable> {
    public let minimumGapSeconds: Double
    private var succeeded: Set<Key> = []
    private var lastAttemptAt: [Key: Double] = [:]

    public init(minimumGapSeconds: Double = 0.5) {
        self.minimumGapSeconds = minimumGapSeconds
    }

    /// True when the caller should try now. Counts as an attempt, so call `recordSuccess` after a good result.
    public mutating func shouldAttempt(_ key: Key, now: Double) -> Bool {
        if succeeded.contains(key) { return false }
        if let last = lastAttemptAt[key], now - last < minimumGapSeconds { return false }
        lastAttemptAt[key] = now
        return true
    }

    public mutating func recordSuccess(_ key: Key) {
        succeeded.insert(key)
    }

    /// Treats `key` as never seen, so its next run starts from scratch.
    public mutating func forget(_ key: Key) {
        succeeded.remove(key)
        lastAttemptAt[key] = nil
    }
}
