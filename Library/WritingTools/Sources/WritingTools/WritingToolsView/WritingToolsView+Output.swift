//
//  WritingToolsView+Output.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Combine
import Foundation
import SwiftUI

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
                        Text(output)
                            .multilineTextAlignment(.leading)
                            .font(.system(.footnote))
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            } else if usage != nil || (isRunning && liveSpeed > 0) {
                HStack(spacing: 8) {
                    if isRunning, liveSpeed > 0 {
                        Image(systemName: "bolt.fill")
                        Text("\(max(1, Int(liveSpeed))) 字/s")
                    }
                    if let usage {
                        Image(systemName: "chart.bar.fill")
                        Text("\(usage.totalTokens) tokens · \(usage.requestCount) req")
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
                        // 提问 task: this slot re-opens the ask prompt pre-filled
                        // with the previous question, so a wrong answer is fixed
                        // by rewording it. A plain "Again" here is dead weight —
                        // it would re-send the identical prompt and hand back the
                        // same unsatisfactory answer.
                        BeautifulButton(title: "Ask".localized) {
                            presentSegmentAsk(prefill: askQuestion)
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
