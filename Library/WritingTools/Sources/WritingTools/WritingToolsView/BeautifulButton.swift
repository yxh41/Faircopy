//
//  BeautifulButton.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Foundation
import SwiftUI

struct BeautifulButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(title: String, icon: String = "", action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    @State var isPressed: Bool = false

    /// Press feedback is three cues stacked: the translucent white backing dims
    /// 10% -> 5%, the label halves its opacity, and the whole button sinks to
    /// 96% scale on a spring. The opacity pair alone was too small a delta to
    /// read as "pressed" — the scale is what makes it feel physical. Shared by
    /// every button in the panel so the feel stays uniform.
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .foregroundStyle(.white)
            .opacity(isPressed ? 0.05 : 0.1)
            .overlay { label.opacity(isPressed ? 0.5 : 1) }
            .scaleEffect(isPressed ? 0.96 : 1.0)
            ._onButtonGesture { isPressed = $0 } perform: { action() }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
    }

    var label: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(.footnote))
    }
}

/// Visual clone of `BeautifulButton` for use as a `Menu` label. It deliberately
/// carries no gesture of its own — the enclosing `Menu` owns tap (primary
/// action) and long-press (menu), so it can't fight `_onButtonGesture`.
struct BeautifulMenuLabel: View {
    let title: String
    let icon: String

    init(title: String, icon: String = "") {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty { Image(systemName: icon) }
            Text(title)
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

/// Panel-mode button: a plain tap runs the mode, a long-press asks the parent to
/// open the variant menu (rendered by `WritingToolsView` as a custom overlay).
///
/// The native `.contextMenu` is deliberately NOT used here — and this time the
/// reason is timing, not looks. After a row is picked, iOS retracts the system
/// menu first and only then delivers the selection callback; that retraction is
/// roughly a second long, during which the panel is frozen with the mode grid
/// still on screen. That IS the "停约1秒，然后啪一下消失" reported for six
/// releases. 3.0.66–3.0.71 all tried to fix it by re-timing the grid's exit
/// animation, which could never work: those animations run *after* the stall,
/// so every one of them looked identical on device. A hand-rolled long press
/// removes the stall entirely — the variant runs the instant a row is tapped,
/// exactly like the short-tap path that was never affected. (Faircopy 3.0.72)
struct PanelModeButton: View {
    let modeID: String
    let title: String
    let icon: String
    /// Only a mode with variants has a menu to open; a plain tap is all the
    /// others do, so the long-press timer is never armed for them.
    let hasVariants: Bool
    /// One-shot confirmation beat. The parent flips this to `true` for ~0.22s
    /// after a variant on THIS button is picked, so the grid visibly
    /// acknowledges the choice (scale 0.96 -> 1.04 -> 1.0) before it fades out.
    let confirmPulse: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var isPressed: Bool = false
    @State private var pulseScale: CGFloat = 1.0
    /// Set when the long press wins, so the gesture's `perform` — which fires on
    /// release regardless of how long the touch lasted — does not also run the
    /// tap action.
    @State private var longPressFired: Bool = false
    @State private var longPressWork: DispatchWorkItem? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .foregroundStyle(.white)
            .opacity(isPressed ? 0.05 : 0.1)
            .overlay { label.opacity(isPressed ? 0.5 : 1) }
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .scaleEffect(pulseScale)
            ._onButtonGesture { pressed in
                isPressed = pressed
                handlePress(pressed)
            } perform: {
                // Defensive: a tap must never leave the button stuck in its
                // pressed visual state. (Faircopy 3.0.65)
                isPressed = false
                if longPressFired {
                    longPressFired = false
                } else {
                    onTap()
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
            .onChange(of: confirmPulse) { pulsed in
                guard pulsed else { return }
                withAnimation(.easeOut(duration: 0.10)) { pulseScale = 1.04 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    withAnimation(.easeInOut(duration: 0.13)) { pulseScale = 1.0 }
                }
            }
            .onDisappear {
                longPressWork?.cancel()
                longPressWork = nil
            }
    }

    /// Long press is detected with a cancellable timer rather than a second
    /// gesture: a `LongPressGesture` laid alongside `_onButtonGesture` fights it,
    /// while the press callback is already reliable — it is what drives the press
    /// animation. A light haptic fires on press-down plus one when the menu opens,
    /// so the button keeps the tactile feel of `BeautifulButton`.
    private func handlePress(_ pressed: Bool) {
        if pressed {
            longPressFired = false
            SegmentHaptics.light.impactOccurred()
            longPressWork?.cancel()
            guard hasVariants else {
                longPressWork = nil
                return
            }
            let work = DispatchWorkItem {
                longPressFired = true
                // The menu covers the button; drop the pressed look so it is not
                // left dimmed underneath the scrim.
                isPressed = false
                SegmentHaptics.light.impactOccurred()
                print("[Faircopy] panel long-press menu open: \(modeID) (custom overlay, no contextMenu)")
                onLongPress()
            }
            longPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else {
            longPressWork?.cancel()
            longPressWork = nil
        }
    }

    private var label: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(.footnote))
    }
}
