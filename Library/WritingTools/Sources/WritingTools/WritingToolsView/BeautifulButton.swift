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

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .foregroundStyle(.white)
            .opacity(isPressed ? 0.05 : 0.1)
            .overlay { label.opacity(isPressed ? 0.5 : 1) }
            ._onButtonGesture { isPressed = $0 } perform: { action() }
            .animation(.easeOut(duration: 0.15), value: isPressed)
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

/// Panel-mode button: a plain tap runs the mode, a long-press opens the variant
/// menu. Deliberately does NOT use `.contextMenu` — iOS draws a system source
/// highlight over the long-pressed view (the "rectangle" that flashes) that
/// SwiftUI cannot suppress — and does NOT use `_onButtonGesture`, because that
/// cannot also distinguish a long press. The visual is `BeautifulMenuLabel`, a
/// gesture-free clone of `BeautifulButton`, so the look is unchanged.
struct PanelModeButton: View {
    let title: String
    let icon: String
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// Mirrors `BeautifulButton`'s press state so the press animation is
    /// identical. Driven by `_onButtonGesture` — the same gesture `BeautifulButton`
    /// uses — which is what gives the smooth `.easeOut(0.15)` press-down feel.
    @State private var isPressed: Bool = false
    /// Set when the long press wins, so the button's `perform` (which fires on
    /// release regardless of hold length) does not also run the tap action.
    @State private var longPressFired: Bool = false
    @State private var longPressWork: DispatchWorkItem? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .foregroundStyle(.white)
            .opacity(isPressed ? 0.05 : 0.1)
            .overlay { label.opacity(isPressed ? 0.5 : 1) }
            ._onButtonGesture { pressed in
                isPressed = pressed
                handlePress(pressed)
            } perform: {
                if !longPressFired { onTap() }
            }
            .animation(.easeOut(duration: 0.15), value: isPressed)
    }

    private var label: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(.footnote))
    }

    /// Long press is detected with a cancellable timer rather than a second
    /// gesture: a `LongPressGesture` added alongside `_onButtonGesture` can fight
    /// it, while the press callback is already reliable (it drives the animation).
    /// A light haptic fires on press-down plus another when the menu opens, so the
    /// button keeps the tactile feel of `BeautifulButton`.
    private func handlePress(_ pressed: Bool) {
        if pressed {
            longPressFired = false
            SegmentHaptics.light.impactOccurred()
            longPressWork?.cancel()
            let work = DispatchWorkItem {
                longPressFired = true
                SegmentHaptics.light.impactOccurred()
                onLongPress()
            }
            longPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else {
            longPressWork?.cancel()
            longPressWork = nil
        }
    }
}
