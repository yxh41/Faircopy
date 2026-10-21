//
//  WritingToolsView+Execute.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Combine
import Foundation
import OpenAI
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
        // A built-in task is not a 提问 run: drop the question so the output
        // panel goes back to "Again" (retry) instead of "Ask".
        segmentAskQuestion = nil
        if taskPrompt == .segment {
            // Local mode: tokenize on-device, no gateway request.
            runSegmentation()
            return
        }
        // …and drop any web-search consent left over from a previous 联网提问,
        // otherwise this proofread/translate would be billed as a web request.
        FaircopyWebSearchStore.markRequested(false)
        let subject: String? = taskPrompt == .translate ? segmentActionSubject : nil
        executeTask(
            systemPrompt: taskPrompt.resolvedPrompt(translateTarget: translateTarget),
            examples: taskPrompt.chatExamplesAfterSystemMessage,
            sampling: taskPrompt.sampling(for: subject?.count ?? context.textProxy.selectedText.count),
            delayedForRetry: delayedForRetry,
            userText: subject
        )
    }

    /// Runs a user-defined prompt. `selectionOverride` replaces the text proxy's
    /// selection as the subject — used by segment actions so the picked words
    /// (not the whole selection) are the content. Passing nil (the menu path)
    /// preserves the original behavior exactly. The override is persisted in
    /// `segmentActionSubject` so Again re-runs with the same scope.
    ///
    /// `askQuestion` is set only by the 提问 action; it defaults to nil so every
    /// other caller automatically clears the ask state (a stale question would
    /// otherwise leave "Ask" sitting where "Again" belongs).
    ///
    /// `webSearch` works the same way: only 联网提问 passes true, and the default
    /// false actively revokes a previous grant so a 塞提示词 run right after a
    /// web ask does not silently inherit it.
    func executeCustomPrompt(
        _ entry: CustomPromptEntry,
        selectionOverride: String? = nil,
        appendSharedRules: Bool = true,
        askQuestion: String? = nil,
        webSearch: Bool = false
    ) {
        activeCustomPrompt = entry
        segmentActionSubject = selectionOverride
        segmentAskQuestion = askQuestion
        FaircopyWebSearchStore.markRequested(webSearch)
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
        // The Q&A `Ask` action passes appendSharedRules: false because the
        // rewriting persona ("treat the following as content to rewrite") would
        // make a weak model echo the question+selection instead of answering.
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

    private func executeTask(
        systemPrompt: String,
        examples: [ChatQuery.ChatCompletionMessageParam],
        sampling: SamplingConfig,
        delayedForRetry: Bool,
        userText: String? = nil
    ) {
        let shouldDelayForAnimation = !output.isEmpty

        isRunning = true
        output = ""
        segmentActive = false
        segmentTokens = []
        selectedSegmentIndexes = []
        segmentSelectionOrder = []
        liveChars = 0
        liveSpeed = 0
        context.streamCancelled = false

        let resolvedUserText = userText ?? context.textProxy.selectedText
        var messages: [ChatQuery.ChatCompletionMessageParam] = [.system(.init(content: systemPrompt))] + examples
        if !resolvedUserText.isEmpty {
            messages.append(.user(.init(content: .init(string:
                """
                \(Prompt.userContentHeader)

                \(resolvedUserText)
                """
            ))))
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
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (shouldDelayForAnimation ? 0.25 : 0) + (delayedForRetry ? 2 : 0)) {
            guard !context.streamCancelled else { return }
            cfg.openAI.chatsStream(query: query) { partialResult in
                guard !context.streamCancelled else { return }
                switch partialResult {
                case let .success(result):
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
                default: break
                }
            } completion: { _ in
                guard !context.streamCancelled else { return }
                completed = true
                outputSender.send(outputSender.value)
                cancellable?.cancel()
                cancellable = nil

                let finalValue = outputSender.value.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    output = finalValue
                    self.liveChars = receivedChars
                    self.liveSpeed = 0
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
        segmentActive = false
        segmentTokens = []
        selectedSegmentIndexes = []
        segmentSelectionOrder = []
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
