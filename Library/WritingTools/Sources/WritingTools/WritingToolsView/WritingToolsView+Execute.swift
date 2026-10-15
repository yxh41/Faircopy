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
        executeTask(
            systemPrompt: entry.prompt + "\n\n" + Prompt.sharedRules,
            examples: [],
            sampling: SamplingConfig(temperature: 0.4),
            delayedForRetry: false
        )
    }

    private func executeTask(
        systemPrompt: String,
        examples: [ChatQuery.ChatCompletionMessageParam],
        sampling: SamplingConfig,
        delayedForRetry: Bool
    ) {
        let shouldDelayForAnimation = !output.isEmpty

        isRunning = true
        output = ""
        context.streamCancelled = false

        let text = context.textProxy.selectedText
        let query = ChatQuery(
            messages: [.system(.init(content: systemPrompt))]
                + examples
                + [.user(.init(content: .init(string:
                    """
                    \(Prompt.userContentHeader)

                    \(text)
                    """
                )))],
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

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (shouldDelayForAnimation ? 0.25 : 0) + (delayedForRetry ? 2 : 0)) {
            guard !context.streamCancelled else { return }
            cfg.openAI.chatsStream(query: query) { partialResult in
                guard !context.streamCancelled else { return }
                switch partialResult {
                case let .success(result):
                    let newToken = result.choices.compactMap(\.delta.content).joined()
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
