//
//  WritingToolsView+SegmentActions.swift
//  WritingTools
//
//  Feature: act on the words picked in 分词 (segment) mode — translate them,
//  ask the model about them, or run one of the user's custom prompts on them.
//  All three funnel through the same executeTask pipeline as the built-in
//  modes; the picked words (segmentActionText) become the subject instead of
//  the full selection. Tapping any action leaves segment mode and streams the
//  result into the normal output panel (Copy / Share / Discard / Again /
//  Accept).
//

import Foundation
import SwiftUI
import UIKit

extension WritingToolsView {
    /// The subject for segment actions: the picked words rejoined the way a
    /// search box expects (`segmentSearchKeyword`), falling back to the full
    /// selected text when nothing is picked.
    var segmentActionText: String {
        let keyword = segmentSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty { return keyword }
        return context.textProxy.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 翻译: translate the picked words into the current translate target.
    /// Routes through the normal translate mode so the language picker and the
    /// Again button keep working — `segmentActionSubject` carries the picked
    /// words so re-runs (switching language, Again, retry) stay scoped to them.
    func translateSegmentSelection() {
        let text = segmentActionText
        guard !text.isEmpty else { return }
        SegmentHaptics.light.impactOccurred()
        print("[Faircopy] segment action: translate \(text.count) chars")
        taskPrompt = .translate
        segmentActionSubject = text
        executeCurrentTask()
    }

    /// 提问: ask the model a question about the picked words. Prompts for the
    /// question, then runs it with the picked words as the source text.
    func askAboutSegmentSelection() {
        presentSegmentAsk()
    }

    /// Presents the 提问 prompt. `prefill` carries the previous question when
    /// re-asking from the output panel, so reacting to a bad answer is an edit
    /// instead of a full retype — and confirming it unchanged reproduces the
    /// old "Again" behaviour exactly.
    ///
    /// Two submit buttons instead of a toggle: the source-text-only answer is
    /// the right default (fast, cheap, faithful), and "go online" is a per-question
    /// decision — the user wants it "有时候", so making it sticky would bill and
    /// slow down every later proofread/translate in the same panel.
    func presentSegmentAsk(prefill: String? = nil) {
        // On the output panel the picked words live in `segmentActionSubject`
        // (the chip selection may already be gone). The chip-backed text stays
        // the fallback for the first ask.
        let text = segmentActionSubject ?? segmentActionText
        guard !text.isEmpty else { return }
        // Logged so a re-ask that failed to carry the old question (or a first
        // ask that lost its subject) is diagnosable from the device console.
        print("[Faircopy] segment ask: prefilled \(prefill?.count ?? 0) chars over \(text.count) chars")
        SegmentHaptics.light.impactOccurred()

        let alert = UIAlertController(
            title: "Ask".localized,
            message: text,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Type your question".localized
            field.text = prefill
            field.clearButtonMode = .whileEditing
        }
        let submit: (Bool) -> Void = { [weak alert] webSearch in
            let question = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !question.isEmpty else { return }
            self.askSegmentSelection(question: question, context: text, webSearch: webSearch)
        }
        alert.addAction(UIAlertAction(title: "Ask".localized, style: .default) { _ in submit(false) })
        alert.addAction(UIAlertAction(title: "Ask with Web".localized, style: .default) { _ in submit(true) })
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))

        // Present from the top-most controller (the panel is a popover on top of
        // the host app's controller); mirrors shareText's presenter walk.
        var presenter: UIViewController = context.parentController
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(alert, animated: true)
    }

    /// Runs the ask: the question is baked into a transient custom prompt so the
    /// Again button re-asks the same question; the picked words are the content.
    ///
    /// A dedicated Q&A persona is used — NOT the rewriting `sharedRules` — because
    /// appending the rewriting rules made the model treat the picked words as text
    /// to rewrite, and a weak model would just echo "question + selection" back
    /// (e.g. ask "推荐一下" on "电脑" → "推荐一下电脑"). The question and the source
    /// text are labelled explicitly so the model answers instead of rewriting.
    /// `webSearch` widens the persona: the default policy ("ONLY the SOURCE
    /// TEXT") is what makes an off-topic question come back as "源文本没有相关
    /// 信息" — correct but useless when the user is deliberately asking something
    /// extra. The gate then tells the gateway to ask the upstream for live
    /// results where the provider supports it.
    private func askSegmentSelection(question: String, context text: String, webSearch: Bool) {
        print("[Faircopy] segment action: ask \(question.count) chars over \(text.count) chars, web=\(webSearch)")
        // Two rule sets rather than one prompt with a flag sentence: a weak model
        // reads "using ONLY the SOURCE TEXT" as an absolute and ignores any
        // later softening, so the strict wording has to actually be absent.
        let rules = webSearch
            ? """
            Rules:
            - Start from the SOURCE TEXT, but you MAY go beyond it: use your own knowledge, and live web information when the model has web access.
            - Never contradict what the SOURCE TEXT actually states; prefer it for anything it covers.
            - When part of the answer is not covered by the SOURCE TEXT, mark that part briefly and inline (in the QUESTION's language) so the user can tell sourced facts from added context.
            - Be concise and faithful. Do not invent facts, prices, models, names, or links. If you are unsure, say you are unsure.
            - Respond in the same language as the QUESTION.
            - Output plain text only. Do not use Markdown, headings, lists, or quotes unless they already exist in the source.
            - Do not add meta commentary or disclaimers.
            """
            : """
            Rules:
            - Answer the QUESTION using ONLY the SOURCE TEXT.
            - Be concise and faithful. Do not invent facts, prices, models, names, or links.
            - If the SOURCE TEXT does not contain the information needed to answer, say so plainly.
            - Respond in the same language as the QUESTION.
            - Output plain text only. Do not use Markdown, headings, lists, or quotes unless they already exist in the source.
            - Do not add meta commentary or disclaimers.
            """
        let prompt =
            """
            You are a question-answering assistant. The user has selected a piece of text and asked a question about it.

            QUESTION:
            \(question)

            SOURCE TEXT:
            \("{{selection}}")

            \(rules)
            """
        let entry = CustomPromptEntry(id: UUID(), title: "Ask".localized, prompt: prompt)
        taskPrompt = .rewrite
        // `askQuestion` keeps the question around so the output panel can offer
        // "Ask" (pre-filled) instead of a useless "Again" that would re-run the
        // same prompt and most likely return the same unsatisfactory answer.
        executeCustomPrompt(
            entry,
            selectionOverride: text,
            appendSharedRules: false,
            askQuestion: question,
            webSearch: webSearch
        )
    }

    /// 塞提示词: run one of the user's custom prompts on the picked words
    /// (`{{selection}}` resolves to the picked words, not the full selection).
    func runCustomPromptOnSegment(_ entry: CustomPromptEntry) {
        let text = segmentActionText
        guard !text.isEmpty else { return }
        SegmentHaptics.light.impactOccurred()
        print("[Faircopy] segment action: insert prompt \(entry.title)")
        taskPrompt = .rewrite
        executeCustomPrompt(entry, selectionOverride: text)
    }

    /// Action row shown under the Search-in-Apps menu while words are picked.
    @ViewBuilder
    var segmentActionRow: some View {
        HStack(spacing: innerSpacing) {
            BeautifulButton(title: "Translate".localized, icon: "character.book.closed") {
                translateSegmentSelection()
            }
            BeautifulButton(title: "Ask".localized, icon: "questionmark.bubble") {
                askAboutSegmentSelection()
            }
            segmentInsertPromptButton
        }
        .frame(height: 56)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    /// 塞提示词 entry: a picker menu once custom prompts exist, otherwise a
    /// shortcut that opens the AIGate manager (mirrors `customPromptButton`).
    @ViewBuilder
    var segmentInsertPromptButton: some View {
        if customPrompts.isEmpty {
            BeautifulButton(title: "Insert into Prompt".localized, icon: "text.badge.plus") {
                openCustomPromptsManager()
            }
        } else {
            Menu {
                ForEach(customPrompts) { entry in
                    Button(entry.title) {
                        runCustomPromptOnSegment(entry)
                    }
                }
                Divider()
                Button("Manage Custom Prompts".localized) {
                    openCustomPromptsManager()
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "text.badge.plus")
                    Text("Insert into Prompt".localized)
                }
                .font(.system(.footnote))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .foregroundStyle(.white)
                        .opacity(0.1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
