//
//  WritingToolsView+Output.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Combine
import Foundation
import SwiftUI
import UIKit

extension WritingToolsView {
    var outputPanel: some View {
        VStack(spacing: innerSpacing) {
            if taskPrompt == .segment {
                segmentOutputArea
            } else if output.isEmpty {
                ProgressView()
                    .tint(.white)
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else {
                StickToBottomScrollView {
                    VStack(spacing: 8) {
                        // While streaming, skip link detection: the text changes
                        // ~20 times a second and re-scanning it every frame costs
                        // more than an inert URL is worth. The finished answer is
                        // re-rendered with links.
                        Text(isRunning ? AttributedString(output) : AnswerLinkParser.linkified(output))
                            .multilineTextAlignment(.leading)
                            .font(.system(.footnote))
                            // Link colour comes from tint, not the run
                            // attributes: the host app's accent is a saturated
                            // blue that clashes with this panel.
                            .tint(AnswerLinkParser.tint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !isRunning, !outputCitations.isEmpty {
                            answerReferences
                        }
                        if !isRunning, showsAskWebHint {
                            askWebHint
                        }
                        Divider().hidden()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity.combined(with: .scale))
            }
            if taskPrompt == .translate {
                translateLanguagePicker(target: translateTarget, rerunOnSelect: true)
            }
            if taskPrompt == .segment {
                segmentStatsLine
                // Hammer It style: jump straight into a target app's search
                // with the picked words. Only while a selection exists.
                if !selectedSegmentIndexes.isEmpty {
                    segmentAppSearchMenu
                    // Act on the picked words: translate / ask / run a custom
                    // prompt — the 分词 mode as a general text-action entry.
                    segmentActionRow
                }
            } else if usage != nil || (isRunning && liveSpeed > 0) || segmentAskQuestion != nil {
                HStack(spacing: 8) {
                    if isRunning, liveSpeed > 0 {
                        Image(systemName: "bolt.fill")
                        Text("\(max(1, Int(liveSpeed))) 字/s")
                    }
                    if let usage {
                        Image(systemName: "chart.bar.fill")
                        Text("\(usage.totalTokens) tokens · \(usage.requestCount) req")
                    }
                    // Session depth. The answer area deliberately shows only the
                    // latest round — without this a multi-turn exchange looks
                    // exactly like a single one.
                    if let askTurnLabel {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text(askTurnLabel)
                    }
                    // The web consent belongs to the session, and the user has
                    // no other way to see which mode produced this answer — an
                    // offline round is exactly why "官网：" ends up empty.
                    if segmentAskQuestion != nil, askWebSearch {
                        Image(systemName: "globe")
                        Text("Web".localized)
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .transition(.opacity)
            }
            HStack(spacing: innerSpacing) {
                if isRunning {
                    BeautifulButton(title: "Cancel".localized) { cancelActiveStream() }
                } else if taskPrompt == .segment {
                    // Copy uses the remembered order on a plain tap; a long-press
                    // opens the order picker (source order / selection order).
                    Menu {
                        Button {
                            copySegmentResult(as: .source)
                        } label: {
                            Label("Copy in Source Order".localized, systemImage: "text.alignleft")
                        }
                        Button {
                            copySegmentResult(as: .selection)
                        } label: {
                            Label("Copy in Selection Order".localized, systemImage: "hand.tap")
                        }
                    } label: {
                        BeautifulMenuLabel(title: "Copy".localized)
                    } primaryAction: {
                        copySegmentResult()
                    }
                    BeautifulButton(title: "Share".localized) { shareSegmentResult() }
                    BeautifulButton(title: "Discard".localized) { discard() }
                    // The 4th slot always exists so inserting/removing Accept
                    // never re-flows the row (previously the other buttons
                    // visibly squeezed/shifted when a selection appeared).
                    segmentAcceptSlot()
                        .frame(maxWidth: .infinity)
                } else {
                    BeautifulButton(title: "Copy".localized) { copyOutput() }
                    BeautifulButton(title: "Share".localized) { shareOutput() }
                    BeautifulButton(title: "Discard".localized) { discard() }
                    if let askQuestion = segmentAskQuestion {
                        // 提问 session: a tap continues the conversation (the
                        // previous answer is replayed into the request), while
                        // the menu can start over. A plain "Again" here was dead
                        // weight — it re-sent the same prompt and got the same
                        // unsatisfactory answer back.
                        Menu {
                            Button {
                                presentSegmentAsk(followUp: true)
                            } label: {
                                Label("Follow Up".localized, systemImage: "arrow.turn.down.right")
                            }
                            Button {
                                presentSegmentAsk(prefill: askQuestion, followUp: false)
                            } label: {
                                Label("Ask Again".localized, systemImage: "questionmark.bubble")
                            }
                        } label: {
                            BeautifulMenuLabel(title: "Follow Up".localized)
                        } primaryAction: {
                            presentSegmentAsk(followUp: true)
                        }
                    } else {
                        BeautifulButton(title: "Again".localized) {
                            if let activeCustomPrompt {
                                // Re-run with the stored subject so a segment
                                // action (塞提示词/提问) keeps its picked-words
                                // scope; normal custom prompts stored nil and
                                // fall back to the live selection.
                                executeCustomPrompt(activeCustomPrompt, selectionOverride: segmentActionSubject)
                            } else {
                                executeCurrentTask()
                            }
                        }
                    }
                    BeautifulButton(title: "Accept".localized) { accept() }
                }
            }
            .frame(height: 40)
            .animation(.easeOut(duration: 0.15), value: selectedSegmentIndexes.isEmpty)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    /// Links the provider attached to this answer.
    ///
    /// Rendered under the text because the model frequently writes only a label
    /// ("官网：") and leaves the URL to the citation — the body alone is a dead
    /// end even though the link exists.
    private var answerReferences: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("References".localized)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            ForEach(outputCitations) { citation in
                Link(destination: citation.url) {
                    HStack(spacing: 5) {
                        Image(systemName: "link")
                        // NOTE: `View.underline(_:pattern:color:)` is iOS 16+,
                        // our deployment target is iOS 15 — the underline has to
                        // live on Text (iOS 13+) and be applied before the
                        // View-returning modifiers.
                        Text(citation.displayTitle)
                            .underline()
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(AnswerLinkParser.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .foregroundStyle(AnswerLinkParser.highlight)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    /// True when a 提问 round came back with no address at all.
    ///
    /// Offline is the common cause: without search results the model must not
    /// invent a domain, so it lists "官网：" and stops — the exact dead end this
    /// hint exists for. It also fires while online when the question was asking
    /// for an address (the upstream may simply have no live-search switch), so
    /// the browser escape hatch exists in both worlds without nagging on every
    /// ordinary answer.
    private var showsAskWebHint: Bool {
        guard segmentAskQuestion != nil else { return false }
        guard outputCitations.isEmpty else { return false }
        guard AnswerLinkParser.urls(in: output).isEmpty else { return false }
        if !askWebSearch { return true }
        let haystack = ((segmentAskQuestion ?? "") + "\n" + output).lowercased()
        let needles = ["链接", "地址", "官网", "网址", "下载", "link", "url", "download", "github"]
        return needles.contains { haystack.contains($0) }
    }

    /// One-tap re-run of the same question with web access enabled, plus the
    /// guaranteed escape hatch: hand the question to a real search engine.
    ///
    /// When the gateway already told us this upstream has no live-search switch,
    /// re-running online would just burn a request and change nothing — so the
    /// row states the reason and keeps only the browser link.
    private var askWebHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            if askUpstreamLive == false {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("This endpoint has no web search".localized)
                }
            } else {
                Button {
                    guard let question = segmentAskQuestion else { return }
                    runAskTurn(question: question, webSearch: true)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "globe")
                        // `Text.underline()` — the View-level underline is iOS 16+.
                        Text("No link found — search the web".localized).underline()
                    }
                }
            }
            Button {
                guard let question = segmentAskQuestion else { return }
                openWebSearch(question)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "safari")
                    Text("Search in Browser".localized).underline()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opens the system browser on a search engine result page for `query`.
    ///
    /// Bing rather than Google: the Google endpoint is unreachable from the
    /// mainland network this panel mostly runs on, and a link that fails to load
    /// is worse than no link.
    private func openWebSearch(_ query: String) {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://cn.bing.com/search?q=" + escaped)
        else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }

    /// "第 N 轮" indicator for a 提问 session; nil for every other task.
    ///
    /// `askTurns` only holds *finished* rounds, and the in-flight one is not in
    /// it yet, so the running round is counted separately.
    private var askTurnLabel: String? {
        guard segmentAskQuestion != nil else { return nil }
        let turn = max(1, askTurns.count + (isRunning ? 1 : 0))
        return String(format: "Turn %d".localized, turn)
    }

    /// The trailing slot of the segment button row. While nothing is selected
    /// it holds an invisible placeholder so the row keeps a stable 4-slot
    /// layout; the Accept button only cross-fades in and out.
    @ViewBuilder
    private func segmentAcceptSlot() -> some View {
        if !selectedSegmentIndexes.isEmpty {
            BeautifulButton(title: "Accept".localized) { acceptSegmentResult() }
                .transition(.opacity)
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }
}
