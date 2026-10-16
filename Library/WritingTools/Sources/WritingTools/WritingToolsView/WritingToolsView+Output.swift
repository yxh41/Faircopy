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
                    BeautifulButton(title: "Copy".localized) { copySegmentResult() }
                    BeautifulButton(title: "Share".localized) { shareText(segmentSpacedText) }
                    BeautifulButton(title: "Discard".localized) { discard() }
                    if !selectedSegmentIndexes.isEmpty {
                        BeautifulButton(title: "Accept".localized) { acceptSegmentResult() }
                    }
                } else {
                    BeautifulButton(title: "Copy".localized) { copyOutput() }
                    BeautifulButton(title: "Share".localized) { shareOutput() }
                    BeautifulButton(title: "Discard".localized) { discard() }
                    BeautifulButton(title: "Again".localized) {
                        if let activeCustomPrompt {
                            executeCustomPrompt(activeCustomPrompt)
                        } else {
                            executeCurrentTask()
                        }
                    }
                    BeautifulButton(title: "Accept".localized) { accept() }
                }
            }
            .frame(height: 40)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}
