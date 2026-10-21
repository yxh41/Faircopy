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
import OpenAI
import SwiftUI
import UIKit

/// How many earlier Q&A rounds a follow-up replays. Each round carries a whole
/// previous answer, so this bounds the request size (and cost) of a long
/// session; the most recent turns are the ones a follow-up refers to.
let kAskHistoryTurns = 8

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
        presentSegmentAsk(followUp: false)
    }

    /// Presents the 提问 prompt.
    ///
    /// `followUp` decides what the two submit buttons do: a follow-up appends a
    /// turn to the running conversation (so "那和 X 比呢" resolves against the
    /// previous answer), while a plain ask starts a new session and drops the
    /// replayed history.
    ///
    /// `prefill` is only useful when re-asking: reacting to a bad answer usually
    /// means tweaking the previous question, whereas a follow-up starts empty —
    /// pre-filling the old one would just have to be deleted.
    ///
    /// Two submit buttons instead of a toggle: offline is the cheaper default,
    /// and "go online" is a decision about *this session*, not a global switch
    /// (it must never leak into the next proofread/translate run).
    ///
    /// The consent is remembered for the whole session (`askWebSearch`) and the
    /// primary button repeats it — asking a follow-up used to reset it to
    /// offline, which quietly removed the search results the model was writing
    /// its addresses from.
    func presentSegmentAsk(prefill: String? = nil, followUp: Bool = false) {
        // On the output panel the picked words live in `segmentActionSubject`
        // (the chip selection may already be gone); a follow-up reads the source
        // from the session instead, which survives even that.
        let text = followUp ? (askSourceText ?? "") : (segmentActionSubject ?? segmentActionText)
        guard !text.isEmpty else { return }
        // A follow-up without a system prompt would send a question with no
        // source text and no rules — worse than doing nothing.
        guard !followUp || askSystemPrompt != nil else { return }
        // Logged so a re-ask that failed to carry the old question (or a first
        // ask that lost its subject) is diagnosable from the device console.
        print("[Faircopy] segment ask: prefilled \(prefill?.count ?? 0) chars over \(text.count) chars, followUp=\(followUp)")
        SegmentHaptics.light.impactOccurred()

        let heading = (followUp ? "Follow Up" : "Ask").localized
        // The session's consent is shown in the title so "why did it stop giving
        // me addresses" is answerable before sending, not after.
        let title = askWebSearch ? heading + " · " + "Web".localized : heading
        let alert = UIAlertController(
            title: title,
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
            if followUp {
                self.runAskTurn(question: question, webSearch: webSearch)
            } else {
                self.askSegmentSelection(question: question, context: text, webSearch: webSearch)
            }
        }
        // Primary = repeat the session's current setting, so a plain 追问 can
        // never silently downgrade a 联网 conversation to an offline one (that
        // downgrade is exactly why the model started answering "官网：" with no
        // address). The second button is the explicit flip.
        let keepWeb = askWebSearch
        let flipTitle = (keepWeb ? "Without Web" : "With Web").localized
        alert.addAction(UIAlertAction(title: heading, style: .default) { _ in submit(keepWeb) })
        alert.addAction(UIAlertAction(title: flipTitle, style: .default) { _ in submit(!keepWeb) })
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))

        // Present from the top-most controller (the panel is a popover on top of
        // the host app's controller); mirrors shareText's presenter walk.
        var presenter: UIViewController = context.parentController
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(alert, animated: true)
    }

    /// Starts a new 提问 session on `text` and sends its first round.
    ///
    /// The question is deliberately NOT part of the system prompt any more: it
    /// travels as a `user` message so later turns can be appended as a real
    /// conversation. The system prompt keeps only the persona, the rules and the
    /// source text, and every follow-up reuses it verbatim.
    ///
    /// A dedicated Q&A persona is used — NOT the rewriting `sharedRules` — because
    /// appending the rewriting rules made the model treat the picked words as text
    /// to rewrite, and a weak model would just echo "question + selection" back
    /// (e.g. ask "推荐一下" on "电脑" → "推荐一下电脑").
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
            - When part of the answer is not covered by the SOURCE TEXT, mark that part briefly and inline (in the question's language) so the user can tell sourced facts from added context.
            - Follow-up questions may refer back to your previous answers; keep the whole exchange in view.
            - When the answer names a site, repository, download page, document or app, put its full address on its own line right after that item, as plain text starting with https:// — no Markdown link syntax and no escaped numbering like "1\\.".
            - Use an address that came from the SOURCE TEXT or from the search results you were given; a well-known official domain you are genuinely sure about is also fine.
            - Never leave a label with nothing after it, never output a truncated fragment such as a bare "https", and never invent a deep link you are unsure of: if you have no reliable address, say so in the same line and name what to search for instead.
            - Be concise and faithful. Do not invent facts, prices, models, or names. If you are unsure, say you are unsure.
            - Respond in the same language as the question.
            - Output plain text only. No Markdown links, headings, lists, or quotes unless they already exist in the source.
            - Do not add meta commentary or disclaimers.
            """
            : """
            Rules:
            - Answer each question using ONLY the SOURCE TEXT.
            - Follow-up questions may refer back to your previous answers; keep the whole exchange in view.
            - If the SOURCE TEXT contains a URL, reproduce it exactly as written, on its own line.
            - Never leave a label with nothing after it and never output a truncated fragment such as a bare "https": if the exact address is not in the SOURCE TEXT, say so plainly on that line instead of guessing.
            - Be concise and faithful. Do not invent facts, prices, models, names, or links.
            - If the SOURCE TEXT does not contain the information needed to answer, say so plainly.
            - Respond in the same language as the question.
            - Output plain text only. No Markdown links, headings, lists, or quotes unless they already exist in the source.
            - Do not add meta commentary or disclaimers.
            """
        let system = """
        You are a question-answering assistant. The user has selected a piece of text and will ask questions about it, possibly over several turns.

        SOURCE TEXT:
        \(text)

        \(rules)
        """
        askSystemPrompt = system
        askSourceText = text
        segmentActionSubject = text
        askTurns = []
        askWebSearch = webSearch
        runAskTurn(question: question, webSearch: webSearch)
    }

    /// Sends one round of the ask conversation.
    ///
    /// Replays `askTurns` as `user`/`assistant` pairs — that is what lets the
    /// model resolve "它" / "那和 X 比呢" against the previous answer — and
    /// records the new turn once the stream finishes.
    ///
    /// Internal rather than private: the output panel's "no link came back" hint
    /// re-runs a round with web access from another file.
    func runAskTurn(question: String, webSearch: Bool) {
        guard let system = askSystemPrompt else { return }
        // Cap the replayed window: every turn carries a full previous answer, so
        // an unbounded session would grow the request (and the bill) linearly.
        // Recent turns are the ones a follow-up actually refers to.
        let history: [ChatQuery.ChatCompletionMessageParam] = askTurns.suffix(kAskHistoryTurns)
            .flatMap { turn -> [ChatQuery.ChatCompletionMessageParam] in
                [
                    .user(.init(content: .init(string: turn.question))),
                    .assistant(.init(content: turn.answer)),
                ]
            }
        // A round is an ask-context task like the first one: keep the output
        // panel's Ask/Follow-Up menu, and carry this round's web consent.
        activeCustomPrompt = nil
        segmentAskQuestion = question
        taskPrompt = .rewrite
        askWebSearch = webSearch
        FaircopyWebSearchStore.markRequested(webSearch)
        // Console only: the file log is reserved for things that went wrong, so
        // a normal session leaves a single "gate:" line per round behind.
        print("[Faircopy] ask turn \(askTurns.count + 1): replaying \(history.count) message(s), web=\(webSearch)")
        executeTask(
            systemPrompt: system,
            examples: [],
            sampling: SamplingConfig(temperature: 0.4),
            delayedForRetry: false,
            userText: question,
            userHeaderPrefix: false,
            history: history
        ) { answer in
            guard !answer.isEmpty else { return }
            askTurns.append(AskTurn(question: question, answer: answer))
            print("[Faircopy] ask session: \(askTurns.count) turn(s) kept")
        }
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
