//
//  WritingToolsView.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import SwiftUI

struct WritingToolsView: View {
    @StateObject var cfg = Configurator.shared
    @StateObject var context: Presenter.Context
    @StateObject var textProxy: TextProxy

    @Environment(\.dismiss) var dismiss

    @State var isRunning: Bool = false

    @State var isRetrying: Bool = false
    @State var shouldRetryWhenActive: Bool = false

    @State var model: String = ""
    @State var modelList: ModelTree = .init(values: [:])
    @State var output: String = ""

    @State var headerDescription: String = ""
    @State var isHeaderDescriptionAnimated: Bool = true

    @State var error: Error? = nil
    @State var taskPrompt: Prompt = .rewrite
    @State var translateTarget: String = "Chinese"

    @State var customPrompts: [CustomPromptEntry] = []
    @State var activeCustomPrompt: CustomPromptEntry? = nil

    // Live streaming metrics (Feature: real-time token speed + cumulative usage)
    @State var liveChars: Int = 0
    @State var liveSpeed: Double = 0
    @State var usage: PanelUsage? = nil

    // Word segmentation (分词) state
    @State var segmentTokens: [SegmentToken] = []
    @State var selectedSegmentIndexes: Set<Int> = []
    /// Tap/drag order of the selected tokens, so Copy can emit them in the
    /// order the user picked them (independent of their order in the source).
    @State var segmentSelectionOrder: [Int] = []
    /// Mirror of `SegmentCopyOrder.remembered` so the stats line can show — and
    /// live-update — which ordering Copy will use next.
    @State var segmentCopyOrder: SegmentCopyOrder = SegmentCopyOrder.remembered
    @State var segmentActive: Bool = false
    @State var segmentTruncated: Bool = false

    // Selection gesture state (driven by the UIKit gesture layer)
    @State var segmentDragAnchor: Int? = nil
    @State var segmentIsDragging: Bool = false
    @State var segmentDragOriginalSelection: Set<Int> = []
    @State var segmentDragSelects: Bool = true

    // Subject of a segment action (翻译/提问/塞提示词): the picked words, kept so
    // re-runs (translate language switch / Again / retry) stay scoped to the
    // selection instead of falling back to the full selected text.
    @State var segmentActionSubject: String? = nil

    /// The question of the in-flight 提问 task (nil for every other task). It
    /// turns the output panel's "Again" button into "Ask" and pre-fills the
    /// alert, so a wrong answer can be re-asked with a tweaked question instead
    /// of discarding the panel and re-picking every word.
    @State var segmentAskQuestion: String? = nil

    @State var initialAnimation: CGFloat = 0
    @State var isClosePressed: Bool = false

    var shouldShowError: Bool {
        error != nil
    }

    var shouldShowOutput: Bool {
        isRunning || !output.isEmpty || segmentActive
    }

    var shouldShowSelectiveButtons: Bool {
        !shouldShowError && !shouldShowOutput
    }

    let spacing: CGFloat = 16
    let innerSpacing: CGFloat = 8

    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    init(context: Presenter.Context) {
        _context = .init(wrappedValue: context)
        _textProxy = .init(wrappedValue: context.textProxy)
    }

    public var body: some View {
        VStack(spacing: 16) {
            title
            if shouldShowError {
                errorView
            } else if shouldShowOutput {
                outputPanel
            } else {
                selectiveButtonPanels
            }
        }
        .animation(.spring, value: isRunning)
        .animation(.spring, value: output)
        .animation(.spring, value: error?.localizedDescription)
        .padding(16)
        .background(background)
        .foregroundStyle(.white)
        .onAppear {
            initialAnimation = 1
        }
        .onChange(of: context.scenePhase) { phase in
            switch phase {
            case .active:
                if shouldRetryWhenActive {
                    error = nil
                    isRetrying = true
                    shouldRetryWhenActive = false
                    executeCurrentTask(delayedForRetry: true)
                }
            default:
                break
            }
        }
        .onChange(of: shouldShowSelectiveButtons) { animated in
            isHeaderDescriptionAnimated = animated
        }
    }
}

extension WritingToolsView {
    struct ModelHandler: Codable, Identifiable, Equatable {
        let id: UUID
        let model: String
        let url: URL
    }

    /// A user-defined prompt fetched from the gate daemon.
    struct CustomPromptEntry: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let prompt: String
    }

    struct ModelTree: Codable, Equatable {
        var keys: [String] { Array(values.keys) }
        let values: [String: [ModelHandler]]
    }

    /// Cumulative token usage reported by the gate daemon (`/metrics?query=usage`).
    struct PanelUsage: Codable, Equatable {
        let promptTokens: Int
        let completionTokens: Int
        let requestCount: Int
        var totalTokens: Int { promptTokens + completionTokens }
    }
}
