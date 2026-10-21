//
//  AgentRunPanel.swift
//  LocalClicky
//
//  The step card for an agent run: what Clicky is doing, one line per step with a
//  word for its state (so state never rests on colour alone), a Stop button, and,
//  while it waits for a yes, the consent question with Yes and No.
//
//  The card never activates LocalClicky, so the user's app stays in front. While asking
//  it becomes the key window (it is a nonactivating panel) so Return and Escape reach it
//  and VoiceOver moves to the question; once answered it gives key focus back. Screen
//  captures skip the card, so a screenshot turn never sees it.
//

import AppKit
import LocalBrainKit
import SwiftUI

/// A panel that can become key only while a consent question is up. While it is, Return and
/// Escape answer here directly, so they do not depend on SwiftUI's key equivalents alone. A
/// key can reach both paths; the run takes only the first answer.
final class AgentCardPanel: NSPanel {
    var allowsKey = false
    var onYes: (() -> Void)?
    var onNo: (() -> Void)?
    override var canBecomeKey: Bool { allowsKey }

    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let escapeKeyCode: UInt16 = 53

    override func keyDown(with event: NSEvent) {
        guard allowsKey else { return super.keyDown(with: event) }
        switch event.keyCode {
        case Self.returnKeyCode, Self.keypadEnterKeyCode: onYes?()
        case Self.escapeKeyCode: onNo?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard allowsKey else { return super.cancelOperation(sender) }
        onNo?()
    }
}

@MainActor
final class AgentRunPanelModel: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        let word: String
        let title: String
    }

    let query: String
    let consentSeconds: Int
    @Published fileprivate(set) var reachedStep = 0
    @Published fileprivate(set) var finalState: MediaRunState?
    @Published fileprivate(set) var finalLine: String?
    /// The link text under the question; non-nil exactly while the question is up.
    @Published fileprivate(set) var consentLabel: String?

    /// One representative state per step, so the titles come from AgentNarration. A run starts on the
    /// direct plan (read the search page, ask, open the video, check) and switches to the page plan if
    /// it has to fall back to opening the results page.
    private static let directPlan: [MediaRunState] = [
        .searching, .askingDirect(DirectResult(videoID: "", title: "")), .openingVideo(DirectResult(videoID: "", title: "")),
        .verifying(attempt: 0),
    ]
    private static let pagePlan: [MediaRunState] = {
        let none = LinkCandidate(label: "", url: "", frame: .zero)
        return [.opening, .locating, .asking(none), .pressing(none), .verifying(attempt: 0)]
    }()
    @Published fileprivate(set) var plan = AgentRunPanelModel.directPlan

    init(query: String, consentSeconds: Int) {
        self.query = query
        self.consentSeconds = consentSeconds
    }

    var rows: [Row] {
        plan.enumerated().map { index, state in
            let word: String
            switch finalState {
            case .none: word = index < reachedStep ? "Done" : index == reachedStep ? "Doing" : "Next"
            case .some(.playing): word = "Done"
            case .some: word = index < reachedStep ? "Done" : index == reachedStep ? "Stopped" : "Skipped"
            }
            return Row(id: index, word: word, title: AgentNarration.stepTitle(for: state))
        }
    }

    fileprivate func update(_ state: MediaRunState, line: String) {
        switch state {
        case .searching: plan = Self.directPlan; reachedStep = 0
        case .opening: plan = Self.pagePlan; reachedStep = 0
        case .locating: reachedStep = 1
        case .asking: reachedStep = 2
        case .askingDirect: reachedStep = 1
        case .openingVideo: reachedStep = 2
        case .pressing: reachedStep = 3
        case .verifying: reachedStep = plan.count - 1
        case .playing, .opened, .handoff, .stopped, .capped:
            finalState = state
            finalLine = line
        }
    }

    /// Whether the buttons name Return and Escape; false when the card could not take the keyboard.
    @Published fileprivate(set) var showsKeyHints = true

    fileprivate func showQuestion(label: String?) { consentLabel = label }
    fileprivate func setKeyHints(_ shown: Bool) { showsKeyHints = shown }
}

@MainActor
final class AgentRunPanel {
    private static let width: CGFloat = 340
    private static let screenMargin: CGFloat = 16

    private let model: AgentRunPanelModel
    private let onAnswer: (ConsentAnswer) -> Void
    private let onStop: () -> Void
    private var cardPanel: AgentCardPanel?
    private var hostingView: NSHostingView<AgentRunPanelView>?

    init(query: String, consentSeconds: Int, onAnswer: @escaping (ConsentAnswer) -> Void, onStop: @escaping () -> Void) {
        model = AgentRunPanelModel(query: query, consentSeconds: consentSeconds)
        self.onAnswer = onAnswer
        self.onStop = onStop
    }

    /// Updates the steps (and the final line) and puts the card on screen without taking focus.
    func show(_ state: MediaRunState, line: String) {
        model.update(state, line: line)
        ensurePanel().orderFrontRegardless()
        fitToContent()
    }

    /// Shows the question and makes the card the key window, without activating the app, so
    /// Return and Escape reach the buttons while the user's app stays in front.
    func beginAsking(label: String) {
        model.showQuestion(label: label)
        let panel = ensurePanel()
        panel.allowsKey = true
        fitToContent()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Whether the card really is the key window now, which is what lets Return and Escape reach
    /// it. A nonactivating panel can silently fail to become key, and then Return would go to the
    /// user's app, so the buttons and the spoken line name the keys only when this is true. Checks
    /// once more after a moment before saying no.
    func confirmKeyboardAnswers() async -> Bool {
        var isKey = cardPanel?.isKeyWindow ?? false
        if !isKey {
            try? await Task.sleep(nanoseconds: 100_000_000)
            isKey = cardPanel?.isKeyWindow ?? false
        }
        model.setKeyHints(isKey)
        return isKey
    }

    /// Hides the question and gives key focus back to the user's window. The card goes out and
    /// straight back in, now unable to take key focus.
    func endAsking() {
        model.showQuestion(label: nil)
        guard let panel = cardPanel else { return }
        panel.allowsKey = false
        panel.resignKey()
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        fitToContent()
    }

    func hide() {
        cardPanel?.orderOut(nil)
    }

    private func ensurePanel() -> AgentCardPanel {
        if let cardPanel { return cardPanel }
        let view = AgentRunPanelView(model: model,
                                     onYes: { [weak self] in self?.onAnswer(.yes) },
                                     onNo: { [weak self] in self?.onAnswer(.no) },
                                     onStop: { [weak self] in self?.onStop() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 200)
        let panel = AgentCardPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.onYes = { [weak self] in self?.onAnswer(.yes) }
        panel.onNo = { [weak self] in self?.onAnswer(.no) }
        panel.contentView = hosting
        cardPanel = panel
        hostingView = hosting
        return panel
    }

    /// Sizes the card to its content and pins it under the menu bar at the top right.
    /// SwiftUI lays out on the next turn of the run loop, so this measures then.
    private func fitToContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.cardPanel, let hosting = self.hostingView else { return }
            let height = hosting.fittingSize.height
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            panel.setFrame(NSRect(x: visible.maxX - Self.width - Self.screenMargin,
                                  y: visible.maxY - height - Self.screenMargin,
                                  width: Self.width, height: height), display: true)
        }
    }
}

private struct AgentRunPanelView: View {
    @ObservedObject var model: AgentRunPanelModel
    let onYes: () -> Void
    let onNo: () -> Void
    let onStop: () -> Void

    @AccessibilityFocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Clicky")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Playing \(model.query) on YouTube")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(model.rows) { row in
                    HStack(spacing: DS.Spacing.sm) {
                        Text(row.word)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(row.word == "Doing" ? DS.Colors.accentText : DS.Colors.textSecondary)
                            .frame(width: 60, alignment: .leading)
                        Text(row.title)
                            .font(.system(size: 13))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if let line = model.finalLine {
                Text(line)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let label = model.consentLabel {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("Play this on youtube.com?")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($questionFocused)
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("No answer in \(model.consentSeconds) seconds counts as no.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                    HStack(spacing: DS.Spacing.sm) {
                        Button(model.showsKeyHints ? "Yes (Return)" : "Yes", action: onYes)
                            .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                            .keyboardShortcut(.defaultAction)
                            .accessibilityLabel("Yes, play it")
                        Button(model.showsKeyHints ? "No (Escape)" : "No", action: onNo)
                            .buttonStyle(DSOutlinedButtonStyle(isFullWidth: false))
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel("No, do not play it")
                    }
                }
                .onAppear { questionFocused = true }
            }

            if model.finalState == nil {
                Button("Stop", action: onStop)
                    .buttonStyle(DSTertiaryButtonStyle())
                    .accessibilityLabel("Stop")
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                .fill(DS.Colors.surface1)
                .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1))
        )
        .environment(\.colorScheme, .dark)
    }
}
