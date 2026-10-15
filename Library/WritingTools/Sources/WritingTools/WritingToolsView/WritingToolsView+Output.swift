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
            if output.isEmpty {
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
            HStack(spacing: innerSpacing) {
                if isRunning {
                    BeautifulButton(title: "Cancel".localized) { cancelActiveStream() }
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
