//
//  WritingToolsView+Execute.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Combine
import Foundation
import OpenAI
import SwiftUI
import UIKit
import WritingToolsLocalizable

extension WritingToolsView {
    /// Runs the current `taskPrompt` against the panel's subject text.
    /// `segmentActionSubject` contract: only segment actions (分词 → 翻译) set
    /// it, and only the translate task reads it, so re-runs (language switch /
    /// Again / retry) stay scoped to the picked words. Every built-in menu
    /// button clears it before calling, so a fresh task always runs on the
    /// live selection; `executeCustomPrompt` sets or clears it per run.
    func executeCurrentTask(delayedForRetry: Bool = false) {
        activeCustomPrompt = nil
        // A built-in task is not a 提问 run: forget the ask session so the output
        // panel goes back to "Again" (retry) and a stale transcript can never be
        // replayed into this request.
        resetAskSession()
        if taskPrompt == .segment {
            // Local mode: tokenize on-device, no gateway request.
            runSegmentation()
            return
        }
        let subject: String? = taskPrompt == .translate ? segmentActionSubject : nil
        // A long-press variant appends a refinement to the base prompt and may
        // override the sampling temperature. `segment` never reaches here (it
        // tokenizes locally), and ask-presets are handled before this call.
        let basePrompt = taskPrompt.resolvedPrompt(translateTarget: translateTarget)
        let systemPrompt: String
        if let variant = activeVariant, !variant.modifier.isEmpty {
            systemPrompt = basePrompt + "\n\n" + variant.modifier
        } else {
            systemPrompt = basePrompt
        }
        var sampling = taskPrompt.sampling(for: subject?.count ?? context.textProxy.selectedText.count)
        if let temperature = activeVariant?.temperature {
            sampling = SamplingConfig(temperature: temperature, topP: sampling.topP)
        }
        executeTask(
            systemPrompt: systemPrompt,
            examples: taskPrompt.chatExamplesAfterSystemMessage,
            sampling: sampling,
            delayedForRetry: delayedForRetry,
            userText: subject
        )
    }

    /// Drops the multi-turn ask session: replay history, system prompt, source
    /// text, the pending question, and the web-search consent that belonged to
    /// it.
    ///
    /// Called by every task entry point except the ask path itself. Without the
    /// web revoke, a proofread right after a 联网提问 would be billed as a web
    /// request; without the history clear, a follow-up from the previous session
    /// could be replayed into an unrelated question.
    func resetAskSession() {
        askTurns = []
        askSystemPrompt = nil
        askSourceText = nil
        segmentAskQuestion = nil
        askWebSearch = false
        askUpstreamLive = nil
        FaircopyWebSearchStore.markRequested(false)
    }

    /// Runs a user-defined prompt. `selectionOverride` replaces the text proxy's
    /// selection as the subject — used by segment actions so the picked words
    /// (not the whole selection) are the content. Passing nil (the menu path)
    /// preserves the original behavior exactly. The override is persisted in
    /// `segmentActionSubject` so Again re-runs with the same scope.
    ///
    /// 提问 does NOT come through here any more: a session needs replayed turns
    /// and a follow-up needs its own prompt, neither of which fits this path.
    /// `runAskTurn` drives that instead.
    func executeCustomPrompt(
        _ entry: CustomPromptEntry,
        selectionOverride: String? = nil,
        appendSharedRules: Bool = true
    ) {
        activeCustomPrompt = entry
        segmentActionSubject = selectionOverride
        // This is not an ask run — drop any session (and its web consent) left
        // behind by a previous 提问.
        resetAskSession()
        let selection = selectionOverride ?? context.textProxy.selectedText
        let clipboard = UIPasteboard.general.string ?? ""
        let language = Self.detectLanguage(selection)
        let resolvedPrompt = Self.resolvePlaceholders(
            in: entry.prompt,
            selection: selection,
            clipboard: clipboard,
            language: language
        )
        // When the user embeds {{selection}} themselves, don't also append the
        // selection as a separate user turn (avoids duplicating the text).
        // Otherwise, a segment action's picked words must be appended
        // explicitly — letting userText fall back to the text proxy would
        // silently widen the subject to the whole selection.
        let userText: String?
        if entry.prompt.contains("{{selection}}") {
            userText = ""
        } else if let selectionOverride {
            userText = selectionOverride
        } else {
            userText = nil
        }
        // Normal custom prompts get the rewriting `sharedRules` appended so they
        // inherit the "plain text / no markdown / same language" discipline.
        let systemPrompt = appendSharedRules
            ? resolvedPrompt + "\n\n" + Prompt.sharedRules
            : resolvedPrompt
        executeTask(
            systemPrompt: systemPrompt,
            examples: [],
            sampling: SamplingConfig(temperature: 0.4),
            delayedForRetry: false,
            userText: userText
        )
    }

    /// - Parameters:
    ///   - history: earlier `user`/`assistant` turns, replayed between the
    ///     few-shot examples and the new question. Empty for every single-shot
    ///     task; the 提问 session fills it so follow-ups see what was said.
    ///   - userHeaderPrefix: set false for chat-style turns. The
    ///     `[User Content As Follow]` header marks text to be processed, which
    ///     would tell the model a question is content to operate on.
    ///   - onFinished: called on the main thread with the final answer, after
    ///     `output` is updated. Used to record the turn for the next follow-up.
    func executeTask(
        systemPrompt: String,
        examples: [ChatQuery.ChatCompletionMessageParam],
        sampling: SamplingConfig,
        delayedForRetry: Bool,
        userText: String? = nil,
        userHeaderPrefix: Bool = true,
        history: [ChatQuery.ChatCompletionMessageParam] = [],
        onFinished: ((String) -> Void)? = nil
    ) {
        let shouldDelayForAnimation = !output.isEmpty
        // Captured on the caller's (main) thread: the gateway's verdict about
        // the upstream is only meaningful for a round that actually asked for
        // web access, and the completion below runs off-main.
        let webRequested = askWebSearch

        // Flip inside an explicit animated transaction so the button-grid exit
        // transition is guaranteed to play. The old body VStack stacked a
        // `.animation(.spring, value: output)` alongside the isRunning easeInOut;
        // that spring shadowed the takeover and timed the grid's fade-out with a
        // spring (slow start -> dwell -> fast drop = "lingers then snaps"). 0.5s
        // easeInOut is a clear fade, not a linger, not a snap. (Faircopy 3.0.70)
        // 3.0.72 re-times it to 0.30s: the real 1s stall was the native context
        // menu retracting before the task began, so the exit no longer has to
        // cover for it — the pressed button bounces first, then the grid is gone.
        withAnimation(.easeInOut(duration: 0.30)) {
            isRunning = true
        }
        print("[Faircopy] task start: grid fade-out via withAnimation easeInOut 0.30 (3.0.72)")
        output = ""
        outputCitations = []
        segmentActive = false
        segmentTokens = []
        selectedSegmentIndexes = []
        segmentSelectionOrder = []
        liveChars = 0
        liveSpeed = 0
        context.streamCancelled = false

        let resolvedUserText = userText ?? context.textProxy.selectedText
        // Few-shot examples first, then the replayed conversation, then the new
        // question — the same order a real transcript would have.
        var messages: [ChatQuery.ChatCompletionMessageParam] = [.system(.init(content: systemPrompt))] + examples + history
        if !resolvedUserText.isEmpty {
            let body = userHeaderPrefix
                ? "\(Prompt.userContentHeader)\n\n\(resolvedUserText)"
                : resolvedUserText
            messages.append(.user(.init(content: .init(string: body))))
        }
        let query = ChatQuery(
            messages: messages,
            model: cfg.mid,
            temperature: sampling.temperature,
            topP: sampling.topP
        )

        var completed = false
        let outputSender = CurrentValueSubject<String, Never>("")
        var cancellable: (any Cancellable)? = outputSender
            .throttle(for: .seconds(0.05), scheduler: DispatchQueue.global(qos: .userInteractive), latest: true)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink {
                guard !completed, !context.streamCancelled else { return }
                output = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }

        let streamStart = Date()
        var receivedChars = 0
        // Citations arrive on the delta, not in the text, and only for providers
        // that searched the web for this request. Collected here and published
        // when the stream ends.
        var collectedCitations: [AnswerCitation] = []
        var seenCitationURLs: Set<String> = []
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (shouldDelayForAnimation ? 0.25 : 0) + (delayedForRetry ? 2 : 0)) {
            guard !context.streamCancelled else { return }
            cfg.openAI.chatsStream(query: query) { partialResult in
                guard !context.streamCancelled else { return }
                switch partialResult {
                case let .success(result):
                    for annotation in result.choices.flatMap({ $0.delta.annotations ?? [] }) {
                        guard let citation = annotation.urlCitation,
                              let raw = citation.url,
                              let url = URL(string: raw),
                              url.scheme?.hasPrefix("http") == true
                        else { continue }
                        guard seenCitationURLs.insert(raw).inserted else { continue }
                        collectedCitations.append(AnswerCitation(url: url, title: citation.title))
                    }
                    let newToken = result.choices.compactMap(\.delta.content).joined()
                    receivedChars += newToken.count
                    let elapsed = Date().timeIntervalSince(streamStart)
                    let speed = elapsed > 0 ? Double(receivedChars) / elapsed : 0
                    DispatchQueue.main.async {
                        self.liveChars = receivedChars
                        self.liveSpeed = speed
                    }
                    let value = outputSender.value + newToken
                    outputSender.send(value)
                case let .failure(error):
                    // Not fatal: the stream may still finish. Console only — the
                    // upstream reports its own billing / capacity errors through
                    // this path, which is why it is worth keeping visible.
                    print("[Faircopy] stream chunk failed: \(error.localizedDescription)")
                }
            } completion: { streamError in
                guard !context.streamCancelled else { return }
                if let streamError {
                    print("[Faircopy] stream finished with error: \(streamError.localizedDescription)")
                }
                completed = true
                outputSender.send(outputSender.value)
                cancellable?.cancel()
                cancellable = nil

                let finalValue = outputSender.value.trimmingCharacters(in: .whitespacesAndNewlines)
                // A URL the model already wrote into the body is already
                // tappable there; listing it again under the answer is noise.
                let bodyURLs = Set(AnswerLinkParser.urls(in: finalValue).map(\.absoluteString))
                let references = collectedCitations.filter { !bodyURLs.contains($0.url.absoluteString) }
                // Printed for both outcomes: "the answer has no address" is
                // either the model's choice (0 citations, 0 body URLs, no web
                // access) or a parsing miss (citations arrive but get dropped),
                // and this one line tells them apart.
                let summary = "\(finalValue.count) chars, \(bodyURLs.count) body url(s), \(collectedCitations.count) citation(s)"
                print("[Faircopy] answer ready: \(summary)")
                let upstreamLive = webRequested ? FaircopyWebCapability.last()?.live : nil
                DispatchQueue.main.async {
                    output = finalValue
                    self.liveChars = receivedChars
                    self.liveSpeed = 0
                    outputCitations = references
                    self.askUpstreamLive = upstreamLive
                    if !references.isEmpty {
                        print("[Faircopy] answer citations: \(references.count) link(s) attached")
                    }
                    // Recorded on the main thread so the turn list is updated in
                    // the same pass as `output` — a follow-up fired right after
                    // the stream ends must already see this turn.
                    onFinished?(finalValue)
                }

                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.1) {
                    onCompletion()
                }
            }
        }
    }

    /// Stops the in-flight stream, keeping any partial output on screen.
    func cancelActiveStream() {
        context.streamCancelled = true
        Configurator.shared.openAI.cancelStreamingRequests()
        DispatchQueue.main.async {
            isRunning = false
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        UIPasteboard.general.string = output
    }

    func shareOutput() {
        shareText(output)
    }

    func shareText(_ text: String) {
        guard !text.isEmpty else { return }
        let activityController = UIActivityViewController(
            activityItems: [text],
            applicationActivities: nil
        )
        // Present from the top-most view controller. The writing panel itself
        // is a popover presented from parentController (i.e. parentController
        // already has a presentedViewController). Presenting straight from
        // parentController while its popover is up silently no-ops, so walk
        // the presented chain first.
        var presenter: UIViewController = context.parentController
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed
        {
            presenter = presented
        }
        if let popover = activityController.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(activityController, animated: true)
    }

    static let spawnURL = URL(string: "faircopy://spawn")

    func onCompletion() {
        assert(!Thread.isMainThread)

        if !output.isEmpty {
            completeNormally()
            return
        }

        let request = Configurator.shared.gateErrorCheckRequest
        var checkError: NSError?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data else { return }
            guard let json = try? JSONSerialization.jsonObject(
                with: data, options: []
            ) as? [String: String] else { return }
            guard let lastError = json["last_error"] else { return }
            checkError = NSError(
                domain: WritingToolsLocalizable.shared.localizedMenuItemTitle(),
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: lastError,
                ]
            )
        }.resume()
        _ = sem.wait(timeout: .now() + 3)

        guard let checkError else {
            completeWithError(NSError(
                domain: WritingToolsLocalizable.shared.localizedMenuItemTitle(),
                code: kErrorCodeRetry,
                userInfo: [
                    NSLocalizedDescriptionKey: WritingToolsLocalizable.shared.localizedString(
                        forKey: "Unable to establish a secure connection to daemon"
                    ),
                ]
            ))
            return
        }

        completeWithError(checkError)
    }

    func completeNormally() {
        DispatchQueue.main.async {
            isRunning = false
            error = nil
            liveSpeed = 0
            fetchUsage()
        }
    }

    func completeWithError(_ error: NSError) {
        var shouldOpenAIGate = false
        let spawnURL = Self.spawnURL
        if error.code == kErrorCodeRetry, let spawnURL {
            // canOpenURL is intentionally NOT used here: this code runs inside
            // arbitrary host apps (injected), whose Info.plist cannot declare the
            // faircopy scheme, so canOpenURL would always return false and the
            // auto-relaunch-and-retry path would never fire. open(_:completionHandler:)
            // requires no LSApplicationQueriesSchemes entry.
            shouldOpenAIGate = true
        }
        DispatchQueue.main.async {
            if shouldOpenAIGate, !isRetrying, let spawnURL {
                UIApplication.shared.open(spawnURL) { success in
                    if !success {
                        print("[*] failed to spawn AIGate via \(spawnURL.absoluteString)")
                    }
                }
                self.setNeedsRetryWhenActive()
            }
            isRunning = false
            self.liveSpeed = 0
            self.error = error
        }
    }

    func discard() {
        cancelActiveStream()
        output = ""
        outputCitations = []
        segmentActive = false
        segmentTokens = []
        selectedSegmentIndexes = []
        segmentSelectionOrder = []
        // Discarding the answer ends the 提问 session too: nothing is left on
        // screen to follow up on.
        resetAskSession()
    }

    func accept() {
        dismiss()
        context.textProxy.replaceText(with: output)
    }

    private func location(forTextRagne textRange: UITextRange, inTextView textView: UITextView) -> Int {
        let beginning = textView.beginningOfDocument
        let start = textRange.start
        return textView.offset(from: beginning, to: start)
    }

    private func length(forTextRange textRange: UITextRange, inTextView textView: UITextView) -> Int {
        let start = textRange.start
        let end = textRange.end
        return textView.offset(from: start, to: end)
    }

    private func stringRange(forTextRange textRange: UITextRange, inTextView textView: UITextView) -> NSRange {
        let location = location(forTextRagne: textRange, inTextView: textView)
        let length = length(forTextRange: textRange, inTextView: textView)
        return NSRange(location: location, length: length)
    }
}

// MARK: - Placeholder resolution for custom prompts

private extension WritingToolsView {
    /// Substitutes runtime context into a user-defined prompt template.
    /// Supported tokens: {{selection}} {{clipboard}} {{language}}
    static func resolvePlaceholders(
        in prompt: String,
        selection: String,
        clipboard: String,
        language: String
    ) -> String {
        prompt
            .replacingOccurrences(of: "{{selection}}", with: selection)
            .replacingOccurrences(of: "{{clipboard}}", with: clipboard)
            .replacingOccurrences(of: "{{language}}", with: language)
    }

    /// Best-effort language detection for the {{language}} token.
    static func detectLanguage(_ text: String) -> String {
        guard !text.isEmpty else { return "unknown" }
        guard let tag = NSLinguisticTagger.dominantLanguage(for: text) else { return "unknown" }
        switch tag {
        case "zh-Hans", "zh-Hant", "zh", "yue": return "Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "en": return "English"
        default: return tag
        }
    }
}
