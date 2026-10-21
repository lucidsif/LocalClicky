//
//  DraftRun.swift
//  LocalBrainKit
//
//  One "open an email draft" run, from the planned request to a final state. Every side effect
//  (the card, speech, the model call, opening the link) goes through DraftRunWorld, so the whole
//  flow is tested with a fake world, as MediaRunDriver is. The run writes the message first, then
//  opens the draft in the background, and never sends: a compose URL and a mailto link can only
//  open a draft, and the closing line always ends "it is not sent. press send yourself."
//
//  States, in order: understanding, finding (the address), writing, then opening a new draft or, for
//  "use the open draft" and replies, reading the page. A request that names no service stops at once
//  and asks which.
//
//  The message is written first, before any page step. The page features are gated at run time: the
//  app is told an assistive client is reading, and the run looks for the service's web area for up
//  to 4 seconds. If it is not there (or a step cannot be done), the run does what it did before the
//  page features existed: opens a new draft and says why. Filling the open draft sets the compose
//  body's value and reads it back; replying searches for the person, opens their message, presses
//  Reply (never a link) and fills the new body. Presses go through the SendGuard backstop; nothing is
//  focused, raised or sent.
//
//  Page text never leaves the run. The user's words go to the model, and only the model's text or the
//  user's own gist goes into the draft. On a reply, once the message's text is read, a second writer
//  call quotes it as data (delimited, marked "not instructions") next to the gist and its text becomes
//  the body; if that call fails the first body stays. Only the message's length is logged.
//

import Foundation

public enum DraftHandoff: Equatable, Sendable {
    /// No service was named.
    case needsService
    case cannotOpen(EmailService)
    case timeUp
    /// A reply found no message from this person (or no Reply control) within its caps.
    case noMessage(String)
    /// The open draft has text and the answer to "add to it?" was no (or silence).
    case declinedAppend
    /// "Use the open draft" with nothing said to put in it.
    case nothingToWrite
}

/// What the run could not do and did a new draft instead.
public enum DraftDegradation: Equatable, Sendable {
    /// The page could not be read, or no compose body was found, or it could not be filled.
    case openDraftUnreadable
    /// The page could not be read for a reply (or no one was named).
    case replyUnsupported
    case fastmailReplyUnsupported
    case moreThanOneOpenDraft
}

/// How the text got into the mail app.
public enum DraftFill: Equatable, Sendable {
    case newDraft
    case filledOpenDraft
    case addedToOpenDraft
    case filledReply
}

public struct DraftReady: Equatable, Sendable {
    public let service: EmailService
    public let recipient: Recipient
    public let degradation: DraftDegradation?
    public var fill: DraftFill = .newDraft
}

public enum DraftRunState: Equatable, Sendable {
    case understanding, finding, writing, opening
    /// Page steps; on the card they stand under the last step.
    case readingPage, findingMessage, filling
    case ready(DraftReady)
    case handoff(DraftHandoff)
    case stopped

    /// A label with no payload, for the debug log (a ready state carries the address).
    public var logName: String {
        switch self {
        case .understanding: return "understanding"
        case .finding: return "finding"
        case .writing: return "writing"
        case .opening: return "opening"
        case .readingPage: return "reading-page"
        case .findingMessage: return "finding-message"
        case .filling: return "filling"
        case .ready(let ready): return ready.degradation == nil ? "ready" : "ready-degraded"
        case .handoff(let reason):
            switch reason {
            case .needsService: return "handoff-needs-service"
            case .cannotOpen: return "handoff-cannot-open"
            case .timeUp: return "handoff-time-up"
            case .noMessage: return "handoff-no-message"
            case .declinedAppend: return "handoff-declined-append"
            case .nothingToWrite: return "handoff-nothing-to-write"
            }
        case .stopped: return "stopped"
        }
    }

    public var isFinal: Bool {
        switch self {
        case .ready, .handoff, .stopped: return true
        case .understanding, .finding, .writing, .opening, .readingPage, .findingMessage, .filling: return false
        }
    }
}

public enum DraftNarration {
    public static let notSent = "it is not sent. press send yourself."

    /// The card's heading: "Draft to Bob in Gmail".
    public static func cardTitle(for request: EmailDraftRequest) -> String {
        let service = request.service.map { $0.rawValue.capitalized }
        let place = service.map { " in \($0)" } ?? ""
        switch request.recipient {
        case .address(let address): return "Draft to \(address)\(place)"
        case .nameOnly(let name): return "Draft to \(name)\(place)"
        case .none: return "Draft\(place)"
        }
    }

    /// The short label of a step on the card. `done` lets the address step say what it heard.
    public static func stepTitle(for state: DraftRunState, request: EmailDraftRequest, done: Bool = false) -> String {
        switch state {
        case .understanding: return "Reading your request"
        case .finding:
            guard done else { return "Reading the address" }
            switch request.recipient {
            case .address(let address): return "Heard \(address)"
            case .nameOnly(let name): return "Heard the name \(name), no address"
            case .none: return "No recipient heard"
            }
        case .writing: return request.gist.isEmpty ? "No message to write" : "Writing the message"
        case .opening: return "Opening the draft in the background"
        case .readingPage: return "Checking that the page can be read"
        case .findingMessage: return "Finding the message"
        case .filling: return "Writing into the draft"
        case .ready: return "Ready"
        case .handoff, .stopped: return "Stopped"
        }
    }

    /// Which states are said aloud; the others only update the card. The writing line is skipped when
    /// there is no message to write.
    public static func isSpoken(_ state: DraftRunState, request: EmailDraftRequest) -> Bool {
        switch state {
        case .understanding, .finding, .readingPage, .findingMessage, .filling: return false
        case .writing: return !request.gist.isEmpty
        case .opening, .ready, .handoff, .stopped: return true
        }
    }

    public static func line(for state: DraftRunState) -> String {
        switch state {
        case .understanding: return "reading your request."
        case .finding: return "reading the address."
        case .writing: return "writing the message."
        case .opening: return "opening the draft in the background."
        case .readingPage: return "checking that i can read the page."
        case .findingMessage: return "finding the message."
        case .filling: return "writing into the draft."
        case .ready(let ready): return readyLine(ready)
        case .handoff(let reason):
            switch reason {
            case .needsService: return "i heard a draft, but not gmail or fastmail. say which one."
            case .cannotOpen(let service): return "i could not open \(service.rawValue), so no draft was made."
            case .timeUp: return "that took too long, so no draft was made."
            case .noMessage(let name):
                return "i could not find a message from \(name) in gmail. say the address for a new draft, or open the message and ask again."
            case .declinedAppend: return "okay, i left the open draft as it is."
            case .nothingToWrite: return "tell me what to put in the open draft."
            }
        case .stopped: return "okay, no draft."
        }
    }

    /// "the draft to bob@example.com is in gmail. it is not sent. press send yourself." With a name only,
    /// it says the To field is empty; with a degradation, it says what was done instead.
    static func readyLine(_ ready: DraftReady) -> String {
        let service = ready.service.rawValue
        let base: String
        switch ready.fill {
        case .filledOpenDraft: base = "the text is in the open draft in \(service)."
        case .addedToOpenDraft: base = "the text is added to the open draft in \(service)."
        case .filledReply:
            base = "the reply is open in \(service) with your text."
        case .newDraft:
            switch ready.recipient {
            case .address(let address): base = "the draft to \(address) is in \(service)."
            case .nameOnly(let name): base = "the draft for \(name) is in \(service), but i have no address, so the to field is empty."
            case .none: base = "the draft is in \(service)."
            }
        }
        let because: String
        switch ready.degradation {
        case .openDraftUnreadable?: because = "i can not read the open draft yet, so i opened a new one. "
        case .replyUnsupported?: because = "i can not find the message to reply to yet, so this is a new draft. "
        case .fastmailReplyUnsupported?: because = "i can not reply in fastmail yet, so this is a new draft. "
        case .moreThanOneOpenDraft?: because = "more than one draft is open, so i opened a new one. "
        case nil: because = ""
        }
        return "\(because)\(base) \(DraftNarration.notSent)"
    }
}

public struct DraftCaps: Equatable, Sendable {
    /// The whole run. The message writer gets its own, longer window than a video run's 45 seconds.
    public var wallClockSeconds: Double
    public var writerSeconds: Double
    /// Looking for the service's web area after the access switch is set.
    public var gateSeconds: Double
    /// Finding and opening a person's message.
    public var messageSeconds: Double
    /// Waiting for the compose body to show up after Reply is pressed.
    public var composeSeconds: Double

    public init(wallClockSeconds: Double = 100, writerSeconds: Double = DraftWriter.defaultTimeoutSeconds,
                gateSeconds: Double = PageGate.seconds, messageSeconds: Double = 8, composeSeconds: Double = 5) {
        self.wallClockSeconds = wallClockSeconds
        self.writerSeconds = writerSeconds
        self.gateSeconds = gateSeconds
        self.messageSeconds = messageSeconds
        self.composeSeconds = composeSeconds
    }
}

/// The fields of the TEMP `draft` debug event. No address and no words of the message.
public struct DraftRunSummary: Equatable, Sendable {
    public let service: String?
    public let kind: String
    public let useOpenDraft: Bool
    public let recipientKind: String
    public let addressParsed: Bool
    public let gistChars: Int
    /// "model", "fallback", or "none" when there was no gist to write from.
    public let writer: String
    public let writerMs: Int
    public let bodyChars: Int
    public let opened: Bool
    public let fallbackReason: String?
    public let finalState: String
    /// Page features: whether the service's web area was found with children, and how long the look took.
    public let pageReadable: Bool?
    public let gateMs: Int?
    /// Length of the message being replied to, never its text.
    public let replyContextChars: Int
    public let bodiesFound: Int
    /// "new", "set", "append", "reply" or "none".
    public let bodyMode: String
    /// The second, quoting writer call of a reply: "model", "fallback" or "skipped".
    public let replyWriter: String

    public var logFields: [String: Any] {
        ["route": "draftEmail", "service": service ?? NSNull(), "kind": kind, "useOpenDraft": useOpenDraft,
         "recipientKind": recipientKind, "addressParsed": addressParsed, "gistChars": gistChars, "writer": writer,
         "writerMs": writerMs, "bodyChars": bodyChars, "opened": opened, "fallbackReason": fallbackReason ?? NSNull(),
         "finalState": finalState, "pageReadable": pageReadable ?? NSNull(), "gateMs": gateMs ?? NSNull(),
         "replyContextChars": replyContextChars, "bodiesFound": bodiesFound, "bodyMode": bodyMode,
         "replyWriter": replyWriter]
    }
}

/// A compose body found on the page. `index` is the world's own handle for it; `isEmpty` is what it held.
public struct ComposeBodyRef: Equatable, Sendable {
    public let index: Int
    public let isEmpty: Bool

    public init(index: Int, isEmpty: Bool) {
        self.index = index
        self.isEmpty = isEmpty
    }
}

/// What reading a message's page gave: its items in document order, and whether a Reply control was found.
public struct ThreadReading: Equatable, Sendable {
    public let items: [PageItem]
    public let hasReplyButton: Bool

    public init(items: [PageItem], hasReplyButton: Bool) {
        self.items = items
        self.hasReplyButton = hasReplyButton
    }
}

@MainActor
public protocol DraftRunWorld: AnyObject {
    /// Shows (and speaks, or announces) the line for a state.
    func show(_ state: DraftRunState, line: String) async
    /// Speaks one extra line (the writer fallback notice).
    func say(_ line: String) async
    /// The model call, built by the app: the same gateway client chat uses, with the draft model.
    func makeGenerator() -> DraftWriter.Generate
    /// Opens the link in its app without bringing the app forward. False when it could not be opened.
    func open(_ opening: ComposeTarget.Opening) async -> Bool
    /// True once the user pressed Stop or a talk key.
    func isStopRequested() -> Bool
    /// Seconds on a monotonic clock.
    func now() -> Double
    /// Called once, at the final state.
    func finished(_ summary: DraftRunSummary)

    // Page features. Each has a default below that answers "the page is not readable", so a world that
    // reads no page gets today's new-draft behavior.

    /// Tells the service's app an assistive client is reading (AXBackend.beginWebContentAccess).
    func beginPageAccess(service: EmailService) async
    /// Looks for the service's web area, with children, for up to `seconds`.
    func awaitPage(service: EmailService, seconds: Double) async -> PageGate.Result
    /// Puts the app back as it was. Safe to call more than once; the driver calls it at the end of every run.
    func endPageAccess(service: EmailService)
    /// The compose bodies on the service's page, waiting up to `seconds` for one to appear.
    func composeBodies(service: EmailService, seconds: Double) async -> [ComposeBodyRef]
    /// Writes `text` into the body (after the old text and a blank line when `appending`) and reads it back.
    func fillBody(_ body: ComposeBodyRef, text: String, appending: Bool, service: EmailService) async -> Bool
    /// Finds the first message row that names the person, presses it and checks that the page address changed.
    func openMessage(from person: Recipient, service: EmailService, seconds: Double) async -> Bool
    /// Reads the open message page in document order and finds its last Reply control.
    func readThread(service: EmailService) async -> ThreadReading
    /// Presses that Reply control.
    func pressReply(service: EmailService) async -> Bool
    /// Asks "the open draft already has text. add to it?" on the card and aloud. False for no or silence.
    func askToAppend() async -> Bool
}

public extension PageGate {
    struct Result: Equatable, Sendable {
        public let readable: Bool
        public let milliseconds: Int

        public init(readable: Bool, milliseconds: Int) {
            self.readable = readable
            self.milliseconds = milliseconds
        }
    }
}

@MainActor
public extension DraftRunWorld {
    func beginPageAccess(service: EmailService) async {}
    func awaitPage(service: EmailService, seconds: Double) async -> PageGate.Result { PageGate.Result(readable: false, milliseconds: 0) }
    func endPageAccess(service: EmailService) {}
    func composeBodies(service: EmailService, seconds: Double) async -> [ComposeBodyRef] { [] }
    func fillBody(_ body: ComposeBodyRef, text: String, appending: Bool, service: EmailService) async -> Bool { false }
    func openMessage(from person: Recipient, service: EmailService, seconds: Double) async -> Bool { false }
    func readThread(service: EmailService) async -> ThreadReading { ThreadReading(items: [], hasReplyButton: false) }
    func pressReply(service: EmailService) async -> Bool { false }
    func askToAppend() async -> Bool { false }
}

@MainActor
public final class DraftRunDriver {
    private let request: EmailDraftRequest
    private let caps: DraftCaps
    private let gmailAccountIndex: Int
    private let userName: String
    private let world: DraftRunWorld

    public init(request: EmailDraftRequest, caps: DraftCaps = DraftCaps(),
                gmailAccountIndex: Int = ComposeTarget.defaultGmailAccountIndex, userName: String = "", world: DraftRunWorld) {
        self.userName = userName
        self.request = request
        self.caps = caps
        self.gmailAccountIndex = gmailAccountIndex
        self.world = world
    }

    private var writerName = "none"
    private var writerMs = 0
    private var bodyChars = 0
    private var fallbackReason: DraftFallbackReason?
    private var opened = false
    private var accessBegunFor: EmailService?
    private var pageReadable: Bool?
    private var gateMs: Int?
    private var replyContextChars = 0
    private var bodiesFound = 0
    private var bodyMode = "none"
    private var replyWriter = "skipped"
    private var startedAt = 0.0

    private var timeIsUp: Bool { world.now() - startedAt > caps.wallClockSeconds }

    public func run() async -> DraftRunState {
        startedAt = world.now()

        await show(.understanding)
        guard let service = request.service else { return await finish(.handoff(.needsService)) }
        if world.isStopRequested() { return await finish(.stopped) }

        await show(.finding)

        // The message is written before any page step.
        await show(.writing)
        var body = ""
        if !request.gist.isEmpty {
            let remaining = max(1, caps.wallClockSeconds - (world.now() - startedAt))
            let written = await DraftWriter.write(gist: request.gist, recipient: request.recipient, userName: userName,
                                                  timeoutSeconds: min(caps.writerSeconds, remaining),
                                                  generate: world.makeGenerator())
            body = written.text
            writerName = written.usedModel ? "model" : "fallback"
            writerMs = written.millis
            bodyChars = body.count
            fallbackReason = written.fallbackReason
            if world.isStopRequested() || written.fallbackReason == .cancelled { return await finish(.stopped) }
            if let reason = written.fallbackReason { await world.say(DraftWriter.spokenLine(for: reason)) }
        }
        if world.isStopRequested() { return await finish(.stopped) }
        if timeIsUp { return await finish(.handoff(.timeUp)) }

        if request.useOpenDraft {
            return await fillOpenDraft(service: service, body: body)
        }
        if request.kind == .reply {
            if service == .fastmail { return await openNewDraft(service: service, body: body, degradation: .fastmailReplyUnsupported) }
            return await reply(body: body)
        }
        return await openNewDraft(service: service, body: body, degradation: nil)
    }

    // MARK: - A new draft

    private func openNewDraft(service: EmailService, body: String, degradation: DraftDegradation?) async -> DraftRunState {
        await show(.opening)
        var address = ""
        if case .address(let found) = request.recipient { address = found }
        let opening = ComposeTarget.opening(service: service, to: address, subject: request.subject ?? "", body: body,
                                            gmailAccountIndex: gmailAccountIndex)
        opened = await world.open(opening)
        guard opened else { return await finish(.handoff(.cannotOpen(service))) }
        if bodyMode == "none" { bodyMode = "new" }
        return await finish(.ready(DraftReady(service: service, recipient: request.recipient, degradation: degradation)))
    }

    // MARK: - The draft that is already open

    private func fillOpenDraft(service: EmailService, body: String) async -> DraftRunState {
        guard await pageIsReadable(service: service) else {
            return await openNewDraft(service: service, body: body, degradation: .openDraftUnreadable)
        }
        let bodies = await world.composeBodies(service: service, seconds: 1)
        bodiesFound = bodies.count
        if world.isStopRequested() { return await finish(.stopped) }
        if bodies.isEmpty { return await openNewDraft(service: service, body: body, degradation: .openDraftUnreadable) }
        if bodies.count > 1 { return await openNewDraft(service: service, body: body, degradation: .moreThanOneOpenDraft) }
        // The draft is there and readable, but there is nothing to put in it.
        if body.isEmpty { return await finish(.handoff(.nothingToWrite)) }
        return await fill(bodies[0], body: body, service: service, fallback: .openDraftUnreadable, mode: .filledOpenDraft)
    }

    /// Writes into the one compose body. A body that already has text is only added to after a yes.
    private func fill(_ target: ComposeBodyRef, body: String, service: EmailService, fallback: DraftDegradation,
                      mode: DraftFill) async -> DraftRunState {
        var appending = false
        if !target.isEmpty {
            guard await world.askToAppend() else { return await finish(.handoff(.declinedAppend)) }
            appending = true
        }
        if world.isStopRequested() { return await finish(.stopped) }
        await show(.filling)
        guard await world.fillBody(target, text: body, appending: appending, service: service) else {
            return await openNewDraft(service: service, body: body, degradation: fallback)
        }
        bodyMode = mode == .filledReply ? "reply" : (appending ? "append" : "set")
        let fill: DraftFill = mode == .filledReply ? .filledReply : (appending ? .addedToOpenDraft : .filledOpenDraft)
        return await finish(.ready(DraftReady(service: service, recipient: request.recipient, degradation: nil, fill: fill)))
    }

    // MARK: - A reply (Gmail)

    private func reply(body: String) async -> DraftRunState {
        let service = EmailService.gmail
        guard let term = LabelMap.searchTerm(for: request.recipient) else {
            return await openNewDraft(service: service, body: body, degradation: .replyUnsupported)
        }
        await world.beginPageAccess(service: service)
        accessBegunFor = service
        let search = ComposeTarget.Opening(url: ComposeTarget.gmailSearchURL(from: term, accountIndex: gmailAccountIndex),
                                           bundleIdentifier: ComposeTarget.chromeBundleIdentifier)
        opened = await world.open(search)
        guard opened else { return await finish(.handoff(.cannotOpen(service))) }
        guard await pageIsReadable(service: service) else {
            return await openNewDraft(service: service, body: body, degradation: .replyUnsupported)
        }

        await show(.findingMessage)
        let found = await world.openMessage(from: request.recipient, service: service, seconds: caps.messageSeconds)
        if world.isStopRequested() { return await finish(.stopped) }
        guard found, !timeIsUp else { return await finish(.handoff(.noMessage(term))) }

        let thread = await world.readThread(service: service)
        let context = ReplyContext.extract(from: thread.items)
        replyContextChars = context?.count ?? 0
        var body = body
        if let context { body = await rewriteReply(body: body, context: context) }
        guard thread.hasReplyButton, await world.pressReply(service: service) else {
            return await finish(.handoff(.noMessage(term)))
        }
        if world.isStopRequested() { return await finish(.stopped) }

        let bodies = await world.composeBodies(service: service, seconds: caps.composeSeconds)
        bodiesFound = bodies.count
        if bodies.isEmpty { return await finish(.handoff(.noMessage(term))) }
        if bodies.count > 1 { return await openNewDraft(service: service, body: body, degradation: .moreThanOneOpenDraft) }
        return await fill(bodies[0], body: body, service: service, fallback: .replyUnsupported, mode: .filledReply)
    }

    /// The reply answers the newest message: a second writer call quotes the message as data next to the gist.
    /// Skipped when there is no gist or the first call already fell back (the same model would fail again).
    /// A failed call keeps the first body and says nothing more.
    private func rewriteReply(body: String, context: String) async -> String {
        guard !request.gist.isEmpty, writerName == "model", !timeIsUp else { return body }
        let remaining = max(1, caps.wallClockSeconds - (world.now() - startedAt))
        let written = await DraftWriter.write(gist: request.gist, recipient: request.recipient, quotedMessage: context, userName: userName,
                                              timeoutSeconds: min(caps.writerSeconds, remaining), generate: world.makeGenerator())
        replyWriter = written.usedModel ? "model" : "fallback"
        guard written.usedModel else { return body }
        bodyChars = written.text.count
        return written.text
    }

    // MARK: - The page gate

    /// Tells the app an assistive client is reading (once) and looks for the page for up to the gate cap.
    private func pageIsReadable(service: EmailService) async -> Bool {
        if accessBegunFor == nil {
            await world.beginPageAccess(service: service)
            accessBegunFor = service
        }
        await show(.readingPage)
        let gate = await world.awaitPage(service: service, seconds: caps.gateSeconds)
        pageReadable = gate.readable
        gateMs = gate.milliseconds
        return gate.readable && !world.isStopRequested()
    }

    // MARK: - Ending

    private func show(_ state: DraftRunState) async {
        await world.show(state, line: DraftNarration.line(for: state))
    }

    private func finish(_ state: DraftRunState) async -> DraftRunState {
        // The app is put back before anything else is said, on every path.
        if let service = accessBegunFor {
            world.endPageAccess(service: service)
            accessBegunFor = nil
        }
        await show(state)
        world.finished(DraftRunSummary(
            service: request.service?.rawValue, kind: request.kind.rawValue, useOpenDraft: request.useOpenDraft,
            recipientKind: request.recipient.kindName,
            addressParsed: { if case .address = request.recipient { return true } else { return false } }(),
            gistChars: request.gist.count, writer: writerName, writerMs: writerMs, bodyChars: bodyChars, opened: opened,
            fallbackReason: fallbackReason?.rawValue, finalState: state.logName, pageReadable: pageReadable, gateMs: gateMs,
            replyContextChars: replyContextChars, bodiesFound: bodiesFound, bodyMode: bodyMode, replyWriter: replyWriter))
        return state
    }
}
