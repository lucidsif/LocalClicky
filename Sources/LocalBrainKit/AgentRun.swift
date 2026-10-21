//
//  AgentRun.swift
//  LocalBrainKit
//
//  The shared vocabulary of an agent run (see MediaRunMachine): what a step did to
//  the world, the caps that bound a run, a link read from a page, and the
//  per-step record written to the run log.
//

import CoreGraphics
import Foundation

/// What a step did, judged by reading the page again afterwards.
public enum ActionEffect: String, Codable, Sendable {
    case confirmed, noop, partial, unverifiable
}

/// The limits that bound one run, so a run can never loop or hang.
public struct AgentCaps: Equatable, Sendable {
    public var maxSteps: Int
    public var wallClockSeconds: Double
    public var retriesPerRung: Int
    public var consentTimeoutSeconds: Double
    public var pageLoadSeconds: Double
    /// The open step's cap when the browser was not running before the open (a cold launch).
    public var pageLoadColdSeconds: Double
    public var verifySeconds: Double

    public init(maxSteps: Int = 8,
                wallClockSeconds: Double = 45.0,
                retriesPerRung: Int = 1,
                consentTimeoutSeconds: Double = 20.0,
                pageLoadSeconds: Double = 6.0,
                pageLoadColdSeconds: Double = 15.0,
                verifySeconds: Double = 6.0) {
        self.maxSteps = maxSteps
        self.wallClockSeconds = wallClockSeconds
        self.retriesPerRung = retriesPerRung
        self.consentTimeoutSeconds = consentTimeoutSeconds
        self.pageLoadSeconds = pageLoadSeconds
        self.pageLoadColdSeconds = pageLoadColdSeconds
        self.verifySeconds = verifySeconds
    }
}

/// A link read from the page's accessibility tree.
public struct LinkCandidate: Equatable, Sendable {
    public let label: String
    public let url: String
    public let frame: CGRect

    public init(label: String, url: String, frame: CGRect) {
        self.label = label
        self.url = url
        self.frame = frame
    }
}

/// How the user answered the consent card.
public struct ConsentRecord: Codable, Equatable, Sendable {
    public let shown: Bool
    public let answer: String
    public let millis: Int

    public init(shown: Bool, answer: String, millis: Int) {
        self.shown = shown
        self.answer = answer
        self.millis = millis
    }
}

/// One line of the run log. Keys are the property names and stay stable.
public struct StepRecord: Codable, Equatable, Sendable {
    public let runId: String
    public let task: String
    public let index: Int
    public let step: String
    public let rung: String?
    public let effect: ActionEffect?
    public let consent: ConsentRecord?
    public let millisSinceStart: Int
    public let outcome: String

    public init(runId: String, task: String, index: Int, step: String, rung: String? = nil,
                effect: ActionEffect? = nil, consent: ConsentRecord? = nil,
                millisSinceStart: Int, outcome: String) {
        self.runId = runId
        self.task = task
        self.index = index
        self.step = step
        self.rung = rung
        self.effect = effect
        self.consent = consent
        self.millisSinceStart = millisSinceStart
        self.outcome = outcome
    }
}
