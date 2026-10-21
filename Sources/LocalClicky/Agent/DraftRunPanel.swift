//
//  DraftRunPanel.swift
//  LocalClicky
//
//  The step card for an email draft run: a heading naming the draft, one line per step with a word
//  for its state (state never rests on colour alone), a Stop button while it works, and the closing
//  line. Like the media card it never activates LocalClicky and never takes the keyboard, and screen
//  captures skip it. It holds no message text and no page text, only the heading and the fixed lines.
//  It can also ask one yes or no question ("the open draft already has text. add to it?"). While it
//  asks it becomes the key window (a nonactivating panel, so the user's app stays in front) so Return
//  and Escape reach it; once answered it gives key focus back.
//

import AppKit
import LocalBrainKit
import SwiftUI

@MainActor
final class DraftRunPanelModel: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        let word: String
        let title: String
    }

    let request: EmailDraftRequest
    @Published fileprivate(set) var reachedStep = 0
    @Published fileprivate(set) var finalState: DraftRunState?
    @Published fileprivate(set) var finalLine: String?
    /// The question under the steps; non-nil exactly while it is up.
    @Published fileprivate(set) var question: String?
    @Published fileprivate(set) var showsKeyHints = true
    @Published fileprivate(set) var lastState: DraftRunState = .understanding

    fileprivate func showQuestion(_ text: String?) { question = text }
    fileprivate func setKeyHints(_ shown: Bool) { showsKeyHints = shown }

    private static let plan: [DraftRunState] = [.understanding, .finding, .writing, .opening]

    init(request: EmailDraftRequest) { self.request = request }

    var heading: String { DraftNarration.cardTitle(for: request) }

    var rows: [Row] {
        Self.plan.enumerated().map { index, state in
            let word: String
            switch finalState {
            case .none: word = index < reachedStep ? "Done" : index == reachedStep ? "Doing" : "Next"
            case .some(.ready): word = "Done"
            case .some: word = index < reachedStep ? "Done" : index == reachedStep ? "Stopped" : "Skipped"
            }
            // The last row shows the page step the run is on, when it is on one.
            var shown = state
            if index == Self.plan.count - 1 {
                switch lastState {
                case .readingPage, .findingMessage, .filling: shown = lastState
                default: break
                }
            }
            return Row(id: index, word: word,
                       title: DraftNarration.stepTitle(for: shown, request: request, done: word == "Done"))
        }
    }

    fileprivate func update(_ state: DraftRunState, line: String) {
        lastState = state
        switch state {
        case .understanding: reachedStep = 0
        case .finding: reachedStep = 1
        case .writing: reachedStep = 2
        case .opening, .readingPage, .findingMessage, .filling: reachedStep = 3
        case .ready, .handoff, .stopped:
            finalState = state
            finalLine = line
        }
    }
}

@MainActor
final class DraftRunPanel {
    private static let width: CGFloat = 340
    private static let screenMargin: CGFloat = 16

    private let model: DraftRunPanelModel
    private let onStop: () -> Void
    private let onAnswer: (ConsentAnswer) -> Void
    private var cardPanel: AgentCardPanel?
    private var hostingView: NSHostingView<DraftRunPanelView>?

    init(request: EmailDraftRequest, onAnswer: @escaping (ConsentAnswer) -> Void, onStop: @escaping () -> Void) {
        model = DraftRunPanelModel(request: request)
        self.onAnswer = onAnswer
        self.onStop = onStop
    }

    /// Shows the question and makes the card the key window, without activating the app.
    func beginAsking(_ question: String) {
        model.showQuestion(question)
        let panel = ensurePanel()
        panel.allowsKey = true
        fitToContent()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Whether the card really is the key window now, which is what lets Return and Escape reach it.
    /// Checks once more after a moment before saying no.
    func confirmKeyboardAnswers() async -> Bool {
        var isKey = cardPanel?.isKeyWindow ?? false
        if !isKey {
            try? await Task.sleep(nanoseconds: 100_000_000)
            isKey = cardPanel?.isKeyWindow ?? false
        }
        model.setKeyHints(isKey)
        return isKey
    }

    /// Hides the question and gives key focus back to the user's window.
    func endAsking() {
        model.showQuestion(nil)
        guard let panel = cardPanel else { return }
        panel.allowsKey = false
        panel.resignKey()
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        fitToContent()
    }

    func show(_ state: DraftRunState, line: String) {
        model.update(state, line: line)
        ensurePanel().orderFrontRegardless()
        fitToContent()
    }

    func hide() { cardPanel?.orderOut(nil) }

    private func ensurePanel() -> AgentCardPanel {
        if let cardPanel { return cardPanel }
        let view = DraftRunPanelView(model: model, onYes: { [weak self] in self?.onAnswer(.yes) },
                                     onNo: { [weak self] in self?.onAnswer(.no) }, onStop: { [weak self] in self?.onStop() })
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

private struct DraftRunPanelView: View {
    @ObservedObject var model: DraftRunPanelModel
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
                Text(model.heading)
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

            if let question = model.question {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(question)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($questionFocused)
                    Text("No answer in 20 seconds counts as no.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                    HStack(spacing: DS.Spacing.sm) {
                        Button(model.showsKeyHints ? "Yes (Return)" : "Yes", action: onYes)
                            .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                            .keyboardShortcut(.defaultAction)
                            .accessibilityLabel("Yes, add to the open draft")
                        Button(model.showsKeyHints ? "No (Escape)" : "No", action: onNo)
                            .buttonStyle(DSOutlinedButtonStyle(isFullWidth: false))
                            .keyboardShortcut(.cancelAction)
                            .accessibilityLabel("No, leave the open draft as it is")
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
