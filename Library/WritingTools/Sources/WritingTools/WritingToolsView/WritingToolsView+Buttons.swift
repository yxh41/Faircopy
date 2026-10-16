//
//  WritingToolsView+Buttons.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Foundation
import SwiftUI

private let kTranslateLanguages = [
    "English", "中文", "日本語", "한국어",
    "Français", "Deutsch", "Español", "Русский",
    "Italiano", "Português"
]

extension WritingToolsView {
    @ViewBuilder
    var selectiveButtonPanels: some View {
        VStack(spacing: innerSpacing) {
            HStack(spacing: innerSpacing) {
                BeautifulButton(title: "Proofread".localized, icon: "doc.text.magnifyingglass") {
                    taskPrompt = .proofread
                    executeCurrentTask()
                }
                BeautifulButton(title: "Rewrite".localized, icon: "arrow.counterclockwise") {
                    taskPrompt = .rewrite
                    executeCurrentTask()
                }
                BeautifulButton(title: "Translate".localized, icon: "character.book.closed") {
                    taskPrompt = .translate
                    executeCurrentTask()
                }
            }
            .frame(height: 80)
            HStack(spacing: innerSpacing) {
                BeautifulButton(title: "Friendly".localized, icon: "bubble.left.and.bubble.right") {
                    taskPrompt = .friendly
                    executeCurrentTask()
                }
                BeautifulButton(title: "Professional".localized, icon: "books.vertical") {
                    taskPrompt = .professional
                    executeCurrentTask()
                }
                BeautifulButton(title: "Concise".localized, icon: "textformat.abc.dottedunderline") {
                    taskPrompt = .concise
                    executeCurrentTask()
                }
            }
            .frame(height: 60)
            HStack(spacing: innerSpacing) {
                BeautifulButton(title: "Expand".localized, icon: "arrow.up.left.and.arrow.down.right") {
                    taskPrompt = .expand
                    executeCurrentTask()
                }
                BeautifulButton(title: "Summarize".localized, icon: "list.bullet.below.rectangle") {
                    taskPrompt = .summarize
                    executeCurrentTask()
                }
                customPromptButton
            }
            .frame(height: 60)
            if taskPrompt == .translate {
                translateLanguagePicker(rerunOnSelect: false)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
        .scaleEffect(initialAnimation * 0.25 + 0.75)
        .opacity(initialAnimation)
        .animation(.spring, value: initialAnimation)
        HStack {
            Text("Made with ♥ by OwnGoal Studio".localized)
            Spacer()
            Text(String(88))
                .hidden()
                .accessibilityHidden(true)
                .overlay(
                    Image(uiImage: sparklesImage.withRenderingMode(.alwaysTemplate))
                        .resizable()
                        .accessibilityHidden(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                )
        }
        .font(.footnote)
        .opacity(0.25)
        .transition(.opacity)
    }

    /// Horizontal language chip strip for the Translate task. Selecting a chip
    /// updates `translateTarget` and immediately re-runs the translate task so
    /// the user can switch the destination language without leaving the panel.
    @ViewBuilder
    func translateLanguagePicker(rerunOnSelect: Bool = true) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(kTranslateLanguages, id: \.self) { language in
                    let selected = language == translateTarget
                    Button {
                        translateTarget = language
                        if rerunOnSelect, taskPrompt == .translate {
                            executeCurrentTask()
                        }
                    } label: {
                        Text(language)
                            .font(.system(.caption2, weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .foregroundStyle(selected ? .white : .white.opacity(0.12))
                            )
                            .foregroundStyle(selected ? .black : .white)
                            .overlay(
                                Capsule()
                                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 34)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    /// Opens the AIGate companion app, where custom prompts are managed.
    func openCustomPromptsManager() {
        guard let spawnURL = WritingToolsView.spawnURL else { return }
        UIApplication.shared.open(spawnURL) { success in
            if !success {
                print("[*] failed to spawn AIGate via \(spawnURL.absoluteString)")
            }
        }
    }

    /// Built-in entry point while no custom prompt exists; a picker menu once
    /// the user has defined at least one.
    @ViewBuilder
    var customPromptButton: some View {
        if customPrompts.isEmpty {
            BeautifulButton(title: "Custom".localized, icon: "text.badge.plus") {
                openCustomPromptsManager()
            }
        } else {
            Menu {
                ForEach(customPrompts) { entry in
                    Button(entry.title) {
                        executeCustomPrompt(entry)
                    }
                }
                Divider()
                Button("Manage Custom Prompts".localized) {
                    openCustomPromptsManager()
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "text.badge.plus")
                    Text("Custom".localized)
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

let sparklesImage = UIImage(data: Data(base64Encoded:
    """
    iVBORw0KGgoAAAANSUhEUgAAAFUAAABSCAMAAAASLmjQAAAABGdBTUEAALGPC/xhBQAAAAFzUkdCAK7OHOkAAAA8UExURQAAAAAAAAAAAAAAAAAAAAAAAAAAAEdwTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHOw9YMAAAAUdFJOU9mmlzAMyYgABb4WSdIisnltPFdhwjDh1wAAA5JJREFUWMOtWe2igyAIxc/U1NLe/13vWlsrFXK78bPZGSIcjgQDYjIyM/xqgP0wAqT7UWeA5X5UDqDvR7UA8XbUAA9z5KtynDVnXM9J9qLOK2rGIU1m8DE2mh5Up9bFCnPWLArOZvMlqszqvVY2wxOhNhYI1DBOzH/WejaNoUxlDy3zI4YqW17AucoWwCwjqK7txTEOGXAbkQik0/6fR8YmcVggCFDwAj+tsOxxYLkIqrQUKlhDZdZSBGq3CWibySrg65KaCJy/QPWOQk3rEvG1qwAThWoeTqn6qbpEVYbirEeZ8/YOLixRqNM78t8FYHsLRc2fnD6kxjzPmtFh4BRqeB1n87eZyFpLoQ5CUJSdIppbR1QZhPuqi2QsEOaNKufnXystaCQZQjAkyz7s7euB2bVEe8qot2ha/RIKkjcTdkM1+vgwBqRPHQ8obulhWAM1bqi6OEPZ01O4wxhMP1HHVsKVJ16fjH3uKfhmQwBjmzV3Bm0xlQp7hz/ZugkY29VRt/Ha2zVUlVPsyVn8ok1tRNM03eqNz3OEVu2JUnMitq6TvsqAB6onWuVmkSSSIoVSJyrVVF25lVdPuo4Axam5kBDxVc6gkSZxeVa7a5/d2jc/tTLr3Fopjo6nuMed9FpVcAqAIUXFcTNcHtRbol2VZEP9oKp81q/FccSiBrp8VbMsVfEJlrn62oHaszyt1YWA31h73N/0k2lqI0qoSOwOYzJf8yPOARVypF7F7zDOte+t7kL9fHWL6wnBNPyOGlBX3T9QUSbIw39QDcN58HfU9n2JGkp0oQ6y9lab4b+oj4vrmd1V/m0+UKXt9KHEouoHJ35FffibJh4j43MqNi9VmblfoOJK90Ve96LmTbTejLqqonA7Kq+0GTYhGedpWkTf9G1l5+UaNbxpSi0duLIu3waqObKJFZeo494XCdSiOv3Yx7+JRuXIfIJ0tSAbuG5TSnYRBHc4qlTYfKKZKfqw3Ot9tAcdHdU3nJVp5g2lYPm8jr9K1NjXoJ0ilWKBajp7aaJ1EvT0U97IaVwoPS6OP6KukRVZl/GyOgvTO9HDR9HucLG2i8Myy+Ojr3a+7qV41H3QI3/I6nqlA6cqdsS075W0ESQPxH49ebyQWZqzUltQU1TgqwOFSxVsL4c8rKcXLI3pAmm6q2+lQ91oed1iluqDBVCfGC4nUXve+D6VIUVKofMDV6g+2dyhBwZti1HNH2pGheAKMEp1AAAAAElFTkSuQmCC
    """
)!)!
