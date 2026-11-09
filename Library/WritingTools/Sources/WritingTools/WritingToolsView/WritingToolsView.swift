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
    /// 3.0.106: the activated endpoint's id, as reported by `/metrics?query=model`.
    ///
    /// The menu used to decide its checkmark from `model`, a model *name*, and
    /// two endpoints serving the same name are a normal setup — so the check sat
    /// on both rows and a real switch looked like a no-op. Empty means the
    /// gateway predates this field; the name comparison is kept for that case.
    @State var activeEndpointID: String = ""
    @State var modelList: ModelTree = .init(values: [:])
    @State var output: String = ""

    /// 3.0.107: the words this panel is working on, captured once.
    ///
    /// `textProxy.selectedText` is live — a Replace rewrites it — so the source
    /// is copied when the panel is built. Text that changed while the user was
    /// comparing it against the answer would be worse than showing none.
    ///
    /// No new file, no new field: this is the same `PanelPending.keyword` the
    /// caller already sent, which the presenter put into the text proxy as the
    /// subject. Showing it is purely a UI change.
    @State var sourceSubject: String = ""
    /// 3.0.130: the exact text submitted to the model for the current `output`.
    ///
    /// `sourceSubject` is a *snapshot* of the full selection (e.g. the whole
    /// OCR'd screen, or the entire 分词 source); but a 分词→翻译 action only
    /// submits the picked words (`segmentActionSubject`). Pairing the answer
    /// against `sourceSubject` then aligns thousands of untranslated lines with
    /// a handful of translated ones. The comparison must use what was actually
    /// sent, so `executeTask` records it here at submit time.
    @State var translatedSource: String = ""
    /// 3.0.130: the 原文 card became a button that pops a panel-internal sheet,
    /// so its expansion flag is no longer needed.
    @State var showsSourceSheet: Bool = false

    /// 3.0.129: 原文对照 (bilingual comparison) for Translate results. Off by
    /// default so the panel looks as before; once flipped on it persists per host
    /// app and pairs each source sentence with its translation.
    @State var compareMode: Bool = CompareMode.remembered

    /// 3.0.108: which height tier the handle has been flicked to. 1 is the size
    /// the presenter measured, so a panel nobody touches looks exactly as before.
    @State var heightTier: Int = 1

    @State var headerDescription: String = ""
    @State var isHeaderDescriptionAnimated: Bool = true

    @State var error: Error? = nil
    @State var taskPrompt: Prompt = .rewrite
    @State var translateTarget: String = "Chinese"

    /// 3.0.78: guards `context.autoSegment` so the tokenize runs exactly once,
    /// no matter how often SwiftUI re-evaluates body / re-fires onAppear.
    @State var didApplyAutoSegment: Bool = false

    /// 3.0.96: same guard for `context.autoTranslate`. A second automatic run
    /// would be a second billed request, so it must never happen.
    @State var didApplyAutoTranslate: Bool = false

    /// Active panel-mode variant selected from a long-press sub-menu, or `nil` for
    /// a plain run. Carried across Again/retry so a variant re-runs with the same
    /// refinement; cleared on any normal (non-variant) mode tap.
    @State var activeVariant: FaircopyPanelVariant? = nil

    /// Mode whose variant menu is currently open (long-press on a panel button),
    /// or `nil` when no menu is showing. Drives the custom modal overlay — we do
    /// NOT use `.contextMenu` any more: besides flashing a source highlight over
    /// the button, iOS retracts it for ~1s before it delivers the selection,
    /// which froze the panel with the mode grid still on screen. (Faircopy 3.0.72)
    @State var variantMenuModeID: String? = nil

    /// Mode whose button should play the "choice accepted" beat right now. Set
    /// for ~0.22s between the menu row tap and the task actually starting, so the
    /// grid acknowledges the pick before it fades out. (Faircopy 3.0.72)
    @State var confirmVariantModeID: String? = nil

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
        // 3.0.78: choose the mode before the first frame. Doing it only in
        // onAppear let one frame of the button grid show for a `mode=segment`
        // panel, which reads as a flicker right as the card lands.
        // 3.0.96: `mode=translate` gets the same treatment — the panel opens on
        // the translating task rather than flashing the grid first.
        let initial: Prompt = context.autoMode == "segment" ? .segment
            : (context.autoMode == "translate" ? .translate : .rewrite)
        _taskPrompt = .init(initialValue: initial)
        // 3.0.107: captured before the first frame so the source is already
        // there when the panel lands. `onAppear` re-checks it, because a
        // synthesized standalone view can be filled a beat after the presenter
        // builds this context.
        _sourceSubject = .init(initialValue: context.textProxy.selectedText)
    }

    public var body: some View {
        VStack(spacing: 16) {
            if showsHeightGrip {
                heightGrip
            }
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
        //
        // 3.0.72: re-timed 0.5 -> 0.30. The long stall was never this fade (it was
        // the native context menu retracting before the task even started), so the
        // exit can be the crisp cross-fade the demo showed: the pressed button
        // bounces, then the grid is gone in 0.3s while the spinner rises.
        .animation(.easeInOut(duration: 0.30), value: isRunning)
        .padding(16)
        .background(background)
        .foregroundStyle(.white)
        // Custom long-press menu (3.0.72). Sits above the gradient, laid out to the
        // panel's own content box so it covers exactly the visible card. Its
        // appearance is driven by `withAnimation` where the state is set, never by
        // a container-level `.animation(value:)` — a second animation modifier on
        // this chain is what shadowed the grid's exit for four releases.
        .overlay {
            if let menuID = variantMenuModeID {
                variantMenuOverlay(menuID)
                    // Scale + fade so the card springs up from the centre. The
                    // animation itself lives in `withAnimation` at the set site —
                    // never a container `.animation(value:)` on this chain.
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        // 3.0.130: the 原文 popup. Layered over the whole card so it reads as a
        // dialog inside the panel rather than an inline expander. Its transition
        // is driven by `withAnimation` at the toggle site, not a container
        // `.animation(value:)` — the same rule as the variant menu above.
        .overlay {
            if showsSourceSheet {
                sourceSheetOverlay
            }
        }
        .onAppear {
            // 3.0.107: the floor under the init-time capture above.
            if sourceSubject.isEmpty {
                sourceSubject = context.textProxy.selectedText
            }
            // 3.0.112: the controller decides which tier a drag settles on, the
            // handle only draws it. Only the handle's brightness depends on
            // this, so it can arrive after the fact.
            //
            // Captures the `State` value rather than `self`: the context
            // outlives this body, and a stored closure holding the view (which
            // holds the context) would keep the whole panel alive after
            // dismissal.
            let tierState = _heightTier
            context.heightTierCommitted = { tier in
                let clamped = min(max(tier, 1), 3)
                if tierState.wrappedValue != clamped { tierState.wrappedValue = clamped }
            }
            // Warm the shared light-impact generator before the first tap. Every
            // press fires `impactOccurred()` on a cold engine otherwise, and a
            // cold engine delays or drops it — which is why the first button
            // press after opening the panel could feel silent.
            SegmentHaptics.light.prepare()
            // 3.0.78: `faircopy://panel?…&mode=segment` — the subject is already
            // in the anchor and already selected, so tokenizing it here saves the
            // tap that would otherwise be the only thing between the gesture and
            // the word chips.
            applyAutoSegmentIfNeeded()
            // 3.0.96: `mode=translate` — start the translation the moment the
            // card lands, so the button that promised 翻译 delivers it.
            applyAutoTranslateIfNeeded()
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
        .onChange(of: showsHeightGrip) { visible in
            // 3.0.110: the handle only lives on 分词 and 翻译, but the height it
            // sets belongs to the card, not to the screen inside it. Leaving an
            // expanded panel for the button grid used to leave a 754pt card
            // holding a 500pt grid, with the remainder empty.
            guard !visible else { return }
            heightTier = 1
            context.requestNaturalHeight()
        }
        .onChange(of: shouldShowSelectiveButtons) { animated in
            isHeaderDescriptionAnimated = animated
            // A running task hands the panel over the moment `isRunning` flips;
            // the button grid fades out (渐隐) so the stale mode buttons never
            // linger on top of the streaming answer. Logged when the grid goes
            // away so field triage can confirm the takeover fired. (Faircopy 3.0.72)
            if !animated {
                variantMenuModeID = nil
                confirmVariantModeID = nil
                print("[Faircopy] button grid removed: task takeover, fade-out, local spring removed (3.0.72)")
            }
        }
    }
}

extension WritingToolsView {
    // MARK: - Panel height (3.0.108)

    /// Only on the two screens that overflow.
    ///
    /// 分词 chips and a translation both run past the card and both already
    /// scroll — the handle decides how much of them is visible at once. The
    /// button grid is sized to fit its content, so a handle there would promise
    /// something it cannot deliver.
    var showsHeightGrip: Bool {
        guard shouldShowOutput else { return false }
        return taskPrompt == .segment || taskPrompt == .translate
    }

    /// The card's own height handle.
    ///
    /// The height belongs to UIKit (`preferredContentSize`), so following the
    /// finger means one resize per frame — which 3.0.113 did from inside
    /// `onChanged`, the SwiftUI update that is running the gesture, and that
    /// locked the main thread. 3.0.114 keeps the gesture callback to two plain
    /// assignments and lets the controller apply the height on its own display
    /// link beat; releasing snaps to the nearest of the three tiers, which stay
    /// the only resting states.
    ///
    /// 2pt of travel starts the gesture: the capsule sits in its own strip above
    /// the title, but a zero-distance drag would also swallow a plain tap.
    var heightGrip: some View {
        Capsule()
            .fill(.white.opacity(heightTier > 1 ? 0.7 : 0.42))
            .frame(width: 38, height: 4)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // Up is negative in SwiftUI's translation; the card grows
                        // upward while staying centred, so negative = taller.
                        // Nothing is resized here — the controller only records
                        // the travel and applies it on its own display-link beat.
                        context.beginHeightDrag()
                        context.moveHeightDrag(growth: -value.translation.height)
                    }
                    .onEnded { _ in
                        context.endHeightDrag()
                    }
            )
            .animation(.easeInOut(duration: 0.2), value: heightTier)
    }

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
