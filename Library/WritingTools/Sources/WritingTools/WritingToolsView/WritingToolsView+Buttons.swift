//
//  WritingToolsView+Buttons.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Foundation
import SwiftUI

private struct TranslateLanguage: Hashable {
    let key: String     // English name sent to the model, e.g. "Chinese"
    let display: String // Chinese label shown on the chip, e.g. "中文"
}

private let kTranslateLanguages: [TranslateLanguage] = [
    .init(key: "Chinese", display: "中文"),
    .init(key: "English", display: "英语"),
    .init(key: "Japanese", display: "日语"),
    .init(key: "Korean", display: "韩语"),
    .init(key: "French", display: "法语"),
    .init(key: "German", display: "德语"),
    .init(key: "Spanish", display: "西班牙语"),
    .init(key: "Russian", display: "俄语"),
    .init(key: "Italian", display: "意大利语"),
    .init(key: "Portuguese", display: "葡萄牙语"),
]

extension WritingToolsView {
    @ViewBuilder
    var selectiveButtonPanels: some View {
        VStack(spacing: innerSpacing) {
            // Modes come from the shared file written by the settings pane
            // (FaircopyPanelModesStore); a missing/unreadable file falls back to
            // every mode in its built-in order. Every row is 60pt tall now that
            // the order is user-defined — there is no longer a "featured" row.
            let modeIDs = FaircopyPanelModesStore.load()
            ForEach(0 ..< (modeIDs.count + 2) / 3, id: \.self) { row in
                HStack(spacing: innerSpacing) {
                    ForEach(0 ..< min(3, modeIDs.count - row * 3), id: \.self) { column in
                        let modeID = modeIDs[row * 3 + column]
                        BeautifulButton(title: FaircopyPanelMode.title(modeID),
                                        icon: FaircopyPanelMode.icon(modeID)) {
                            if let prompt = FaircopyPanelMode.prompt(modeID) {
                                taskPrompt = prompt
                                segmentActionSubject = nil
                                executeCurrentTask()
                            }
                        }
                    }
                }
                .frame(height: 60)
            }
            if modeIDs.isEmpty {
                Text("All panel modes are hidden. Turn some back on in Settings.".localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 4)
            }
            HStack(spacing: innerSpacing) {
                customPromptButton
            }
            .frame(height: 60)
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
    /// Laid out as a fixed 2-row grid (NOT a ScrollView): a horizontal scroll
    /// view competes with taps via its pan gesture and was reported as hard to
    /// hit; a grid makes every language visible with a large tap target.
    /// `target` is passed as a plain `String` (the current `translateTarget`);
    /// do NOT read the `@State` property directly inside this `@ViewBuilder`
    /// method, otherwise SwiftUI projects it as a `Binding` and the `ForEach`
    /// overload resolution breaks.
    /// A single language chip. Extracted into its own @ViewBuilder helper so the
    /// ForEach closure in `translateLanguagePicker` stays trivial and the Swift
    /// type checker does not time out on the combined expression.
    @ViewBuilder
    private func languageChip(_ item: TranslateLanguage, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Capsule()
            .fill(isSelected ? Color.white : Color.white.opacity(0.12))
            .frame(height: 40)
            .overlay(
                Text(item.display)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.black : Color.white)
            )
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }

    @ViewBuilder
    func translateLanguagePicker(target: String, rerunOnSelect: Bool = true) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(kTranslateLanguages, id: \.key) { (item: TranslateLanguage) in
                languageChip(item, isSelected: item.key == target) {
                    self.translateTarget = item.key
                    if rerunOnSelect, self.taskPrompt == .translate {
                        self.executeCurrentTask()
                    }
                }
            }
        }
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
