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
                // Tap runs the mode; long-press opens the custom variant menu.
                // No `.contextMenu`: iOS retracts that menu for ~1s before it
                // delivers the selection, which is the stall this replaces.
                PanelModeButton(
                    modeID: modeID,
                    title: FaircopyPanelMode.title(modeID),
                    icon: FaircopyPanelMode.icon(modeID),
                    hasVariants: !(FaircopyPanelVariant.registry[modeID] ?? []).isEmpty,
                    confirmPulse: confirmVariantModeID == modeID,
                    onTap: {
                        if let prompt = FaircopyPanelMode.prompt(modeID) {
                            taskPrompt = prompt
                            segmentActionSubject = nil
                            activeVariant = nil
                            executeCurrentTask()
                        }
                    },
                    onLongPress: {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            variantMenuModeID = modeID
                        }
                    }
                )
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
        // The task takeover: the body swaps `selectiveButtonPanels` out for
        // `outputPanel` the moment `isRunning` flips.
        //
        // 3.0.66–3.0.70 all tried to fix "the grid lingers ~1s then snaps" by
        // editing the BODY's `.animation`/`.transition`, and every build looked
        // identical on device. The real culprit was on the grid itself:
        // `.opacity(initialAnimation)` and `.scaleEffect(initialAnimation…)` pin
        // the view at full size/opacity during the exit, and
        // `.animation(.spring, value: initialAnimation)` is the NEAREST animation
        // modifier to the removed view — so the exit was driven by that local
        // spring against a fixed opacity/scale: the grid froze, then dropped.
        // No body-level change could ever win against it. All three are gone
        // now; the exit is a plain `.transition` driven solely by the body's
        // single easeInOut. (Faircopy 3.0.71)
        //
        // 3.0.72: the ~1s stall turned out NOT to be this exit at all. It only
        // happened on the long-press-then-pick path, because the native
        // `.contextMenu` retracts before it delivers the selection — so the exit
        // animation simply had not started yet. The grid can stay 渐隐 (now a
        // 0.30s easeInOut); the delay is gone because the menu is hand-rolled.
        .transition(.opacity.combined(with: .scale(scale: 0.86)))
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

    /// Custom modal menu shown when a panel mode is long-pressed.
    ///
    /// This replaces `.contextMenu`, and the reason is purely timing: after a row
    /// is picked, iOS retracts the system menu first and only then calls back —
    /// about a second in which the panel is frozen and the mode grid is still on
    /// screen. Nothing that re-timed the grid's exit could fix that, because the
    /// exit had not begun. A hand-rolled menu runs the variant the moment a row is
    /// tapped, which is the instant behaviour a short tap always had. (3.0.72)
    ///
    /// A dimmed backdrop dismisses it. The card is kept visually close to the
    /// native one (dark, translucent, rounded, rows with icon + label) so the
    /// long-press still reads as "a menu", not as a panel takeover.
    @ViewBuilder
    func variantMenuOverlay(_ modeID: String) -> some View {
        let variants = FaircopyPanelVariant.registry[modeID] ?? []
        ZStack {
            // Scrim: 15% — even lighter per user request (3.0.74); the panel
            // gradient now reads through clearly while the frosted card still pops.
            // Still the tap-to-dismiss target. (Was 22% in 3.0.73, 45% in 3.0.72.)
            Color.black.opacity(0.15)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.16)) { variantMenuModeID = nil }
                }
            VStack(spacing: 0) {
                Text(FaircopyPanelMode.title(modeID))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                ForEach(Array(variants.enumerated()), id: \.element.id) { index, variant in
                    Button {
                        pickVariant(modeID: modeID, variant: variant)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: variant.icon)
                                .frame(width: 22, alignment: .center)
                            Text(variant.title)
                            Spacer(minLength: 0)
                        }
                        .font(.system(.subheadline))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < variants.count - 1 {
                        Divider().background(Color.white.opacity(0.08)).padding(.horizontal, 16)
                    }
                }
                Divider().background(Color.white.opacity(0.12))
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { variantMenuModeID = nil }
                } label: {
                    Text("取消")
                        .font(.system(.subheadline))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 264)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.5)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.45), radius: 28, y: 14)
        }
    }

    /// Runs the picked variant immediately — that is the entire point of 3.0.72.
    /// The menu closes at once, the pressed button plays a confirmation beat
    /// (0.96 -> 1.04 -> 1.0, ~0.23s) so the grid visibly acknowledges the choice,
    /// then the task starts and the grid fades out under the spinner. Dead time
    /// before streaming: ~0.22s, against ~1s with the native menu.
    func pickVariant(modeID: String, variant: FaircopyPanelVariant) {
        SegmentHaptics.light.impactOccurred()
        print("[Faircopy] variant picked: \(variant.title) -> confirm beat then run (3.0.73)")
        withAnimation(.easeOut(duration: 0.16)) { variantMenuModeID = nil }
        confirmVariantModeID = modeID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            confirmVariantModeID = nil
            applyVariant(modeID: modeID, variant: variant)
        }
    }

    /// Runs the chosen variant. Ask-presets (提问) defer presentation by a beat:
    /// the overlay is gone by then, and raising the ask alert while a dimmed
    /// scrim is still fading out looks broken.
    func applyVariant(modeID: String, variant: FaircopyPanelVariant) {
        guard let prompt = FaircopyPanelMode.prompt(modeID) else { return }
        if let prefill = variant.askPrefill {
            if variant.askWeb { askWebSearch = true }
            activeVariant = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                self.presentSegmentAsk(prefill: prefill, followUp: false)
            }
        } else {
            taskPrompt = prompt
            segmentActionSubject = nil
            if let target = variant.translateTarget {
                translateTarget = target
            }
            activeVariant = variant
            executeCurrentTask()
        }
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
