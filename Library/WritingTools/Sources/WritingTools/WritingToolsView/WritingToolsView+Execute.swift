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
    func executeCurrentTask(delayedForRetry: Bool = false) {
        activeCustomPrompt = nil
        executeTask(
            systemPrompt: taskPrompt.prompt,
            examples: taskPrompt.chatExamplesAfterSystemMessage,
            sampling: taskPrompt.sampling(for: context.textProxy.selectedText.count),
            delayedForRetry: delayedForRetry
        )
    }

    func executeCustomPrompt(_ entry: CustomPromptEntry) {
        activeCustomPrompt = entry
        let selection = context.textProxy.selectedText
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
        let userText = entry.prompt.contains("{{selection}}") ? "" : nil
        executeTask(
            systemPrompt: resolvedPrompt + "\n\n" + Prompt.sharedRules,
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
        guard !output.isEmpty else { return }
        let activityController = UIActivityViewController(
            activityItems: [output],
            applicationActivities: nil
        )
        if let popover = activityController.popoverPresentationController {
            popover.sourceView = context.parentController.view
            popover.sourceRect = CGRect(
                x: context.parentController.view.bounds.midX,
                y: context.parentController.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        context.parentController.present(activityController, animated: true)
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
