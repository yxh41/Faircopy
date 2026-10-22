//
//  WritingToolsView.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import SwiftUI

/// One completed Q&A round of a 提问 session, replayed as a `user`/`assistant`
/// pair on every follow-up.
struct AskTurn: Equatable {
    let question: String
    let answer: String
}

/// A link that belongs to an answer: either a web-search citation returned by
/// the provider, or a URL the model wrote into the body.
struct AnswerCitation: Identifiable, Equatable {
    let url: URL
    /// Provider-supplied title, when it has one. Falls back to the host name.
    let title: String?

    var id: String { url.absoluteString }

    /// Short human label: "github.com" reads better in a tight panel than a full
    /// URL, and the full URL is what the tap opens anyway.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return url.host ?? url.absoluteString
    }
}

struct WritingToolsView: View {
    @StateObject var cfg = Configurator.shared
    @StateObject var context: Presenter.Context
    @StateObject var textProxy: TextProxy

    @Environment(\.dismiss) var dismiss

    @State var isRunning: Bool = false

    @State var isRetrying: Bool = false
    @State var shouldRetryWhenActive: Bool = false

    @State var model: String = ""
    @State var modelList: ModelTree = .init(values: [:])
    @State var output: String = ""

    @State var headerDescription: String = ""
    @State var isHeaderDescriptionAnimated: Bool = true

    @State var error: Error? = nil
    @State var taskPrompt: Prompt = .rewrite
    @State var translateTarget: String = "Chinese"

    /// Active panel-mode variant selected from a long-press sub-menu, or `nil` for
    /// a plain run. Carried across Again/retry so a variant re-runs with the same
    /// refinement; cleared on any normal (non-variant) mode tap.
    @State var activeVariant: FaircopyPanelVariant? = nil

    @State var customPrompts: [CustomPromptEntry] = []
    @State var activeCustomPrompt: CustomPromptEntry? = nil

    // Live streaming metrics (Feature: real-time token speed + cumulative usage)
    @State var liveChars: Int = 0
    @State var liveSpeed: Double = 0
    @State var usage: PanelUsage? = nil

    // Word segmentation (分词) state
    @State var segmentTokens: [SegmentToken] = []
    @State var selectedSegmentIndexes: Set<Int> = []
    /// Tap/drag order of the selected tokens, so Copy can emit them in the
    /// order the user picked them (independent of their order in the source).
    @State var segmentSelectionOrder: [Int] = []
    /// Mirror of `SegmentCopyOrder.remembered` so the stats line can show — and
    /// live-update — which ordering Copy will use next.
    @State var segmentCopyOrder: SegmentCopyOrder = SegmentCopyOrder.remembered
    @State var segmentActive: Bool = false
    @State var segmentTruncated: Bool = false

    // Selection gesture state (driven by the UIKit gesture layer)
    @State var segmentDragAnchor: Int? = nil
    @State var segmentIsDragging: Bool = false
    @State var segmentDragOriginalSelection: Set<Int> = []
    @State var segmentDragSelects: Bool = true

    // Subject of a segment action (翻译/提问/塞提示词): the picked words, kept so
    // re-runs (translate language switch / Again / retry) stay scoped to the
    // selection instead of falling back to the full selected text.
    @State var segmentActionSubject: String? = nil

    /// The question of the in-flight 提问 task (nil for every other task). It
    /// turns the output panel's "Again" button into "Ask" and pre-fills the
    /// alert, so a wrong answer can be re-asked with a tweaked question instead
    /// of discarding the panel and re-picking every word.
    @State var segmentAskQuestion: String? = nil

    /// Completed rounds of the current 提问 session. A follow-up like "那和 X
    /// 比呢" is meaningless to a model that never saw the previous answer, so
    /// these turns are replayed as real `user`/`assistant` messages instead of
    /// being folded back into the prompt.
    @State var askTurns: [AskTurn] = []

    /// System prompt of the current ask session — persona + rules + source
    /// text. Kept verbatim across turns so every follow-up answers against the
    /// same source under the same rules (including the 联网 variant).
    @State var askSystemPrompt: String? = nil

    /// Source text of the current ask session. Kept separately from
    /// `segmentActionSubject` so "重新提问" can rebuild the session after the
    /// chip selection is gone.
    @State var askSourceText: String? = nil

    /// Whether the current 提问 session has web access consented.
    ///
    /// Per-turn consent (3.0.51) turned out to be a trap: the first round is
    /// asked with 联网, then every plain 追问 silently drops the flag, the model
    /// loses the search results it was relying on, and — bound by "don't invent
    /// links" — answers with bare labels like "官网：" and no address at all.
    /// The consent now belongs to the session: a follow-up inherits it unless
    /// the user explicitly flips it from the alert's second button.
    @State var askWebSearch: Bool = false

    /// The gateway's verdict on the upstream of the last round: `true` when the
    /// request really carried a web-search switch, `false` when the endpoint has
    /// none (prompt-only), `nil` when unknown. Drives the "why is there no
    /// address" line under the answer instead of making the user retry blindly.
    @State var askUpstreamLive: Bool? = nil

    /// Links the provider attached to the answer (web search citations), plus
    /// any URL the model wrote into the body. Rendered as a tappable block under
    /// the answer so "官网：" is never a dead end.
    @State var outputCitations: [AnswerCitation] = []

    @State var isClosePressed: Bool = false

    var shouldShowError: Bool {
        error != nil
    }

    var shouldShowOutput: Bool {
        isRunning || !output.isEmpty || segmentActive
    }

    var shouldShowSelectiveButtons: Bool {
        !shouldShowError && !shouldShowOutput
    }

    let spacing: CGFloat = 16
    let innerSpacing: CGFloat = 8

    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(context: Presenter.Context) {
        _context = .init(wrappedValue: context)
        _textProxy = .init(wrappedValue: context.textProxy)
    }

    public var body: some View {
        VStack(spacing: 16) {
            title
            if shouldShowError {
                errorView
            } else if shouldShowOutput {
                outputPanel
            } else {
                selectiveButtonPanels
            }
        }
        // The task-takeover swap (button grid -> output panel) is the ONLY
        // animation this VStack owns, and it must NOT share the modifier chain
        // with any `.spring`. A stacked `.animation(.spring, value: output)` (or
        // `error`) shadowed the isRunning easeInOut for the `isRunning` flip, so
        // the grid's exit transition was timed by a spring — which starts slow,
        // dwells, then drops, reading exactly as "lingers ~1s then snaps".
        // Keeping ONLY the isRunning easeInOut here (and driving the flip with
        // `withAnimation` in executeTask) makes the grid fade out smoothly.
        // Streaming `output` and the error view update without animation — that
        // is correct: streamed text should change per token, not spring.
        // (Faircopy 3.0.70)
        .animation(.easeInOut(duration: 0.5), value: isRunning)
        .padding(16)
        .background(background)
        .foregroundStyle(.white)
        .onAppear {
            // Warm the shared light-impact generator before the first tap. Every
            // press fires `impactOccurred()` on a cold engine otherwise, and a
            // cold engine delays or drops it — which is why the first button
            // press after opening the panel could feel silent.
            SegmentHaptics.light.prepare()
            print("[Faircopy] panel ready: press scale 0.96, spring response 0.25 damping 0.7, haptic prepared")
        }
        .onChange(of: context.scenePhase) { phase in
            switch phase {
            case .active:
                if shouldRetryWhenActive {
                    error = nil
                    isRetrying = true
                    shouldRetryWhenActive = false
                    executeCurrentTask(delayedForRetry: true)
                }
            default:
                break
            }
        }
        .onChange(of: shouldShowSelectiveButtons) { animated in
            isHeaderDescriptionAnimated = animated
            // A running task hands the panel over the moment `isRunning` flips;
            // the button grid fades out (渐隐) so the stale mode buttons never
            // linger on top of the streaming answer. Logged when the grid goes
            // away so field triage can confirm the takeover fired. (Faircopy 3.0.68)
            if !animated {
                print("[Faircopy] button grid removed: task takeover, fade-out, local spring removed (3.0.71)")
            }
        }
    }
}

extension WritingToolsView {
    struct ModelHandler: Codable, Identifiable, Equatable {
        let id: UUID
        let model: String
        let url: URL
    }

    /// A user-defined prompt fetched from the gate daemon.
    struct CustomPromptEntry: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let prompt: String
    }

    struct ModelTree: Codable, Equatable {
        var keys: [String] { Array(values.keys) }
        let values: [String: [ModelHandler]]
    }

    /// Cumulative token usage reported by the gate daemon (`/metrics?query=usage`).
    struct PanelUsage: Codable, Equatable {
        let promptTokens: Int
        let completionTokens: Int
        let requestCount: Int
        var totalTokens: Int { promptTokens + completionTokens }
    }
}
