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

/// Panel-mode button: a plain tap runs the mode, a long-press opens the native
/// variant menu. Keeps `BeautifulButton`'s press animation (`_onButtonGesture`
/// driving `isPressed`) and a press-down haptic, but presents the variants via
/// the system `.contextMenu` — restoring the arrangement that was in place
/// before the custom dark overlay.
struct PanelModeButton: View {
    let title: String
    let icon: String
    let variants: [FaircopyPanelVariant]
    let onTap: () -> Void
    let onSelect: (FaircopyPanelVariant) -> Void

    @State private var isPressed: Bool = false

    var body: some View {
        if variants.isEmpty {
            base
        } else {
            menuButton
        }
    }

    /// `preview: { EmptyView() }` is not cosmetic — without it the system builds
    /// a scaled-up snapshot of the source view and lifts it as the menu appears,
    /// which reads as a far heavier animation than the plain press dimming.
    /// This is exactly what the panel did before the custom dark overlay
    /// (3.0.59); 3.0.62 dropped it and the long-press looked wrong again.
    ///
    /// The scale has to sit *inside* a container whose own transform stays
    /// identity: UIKit anchors the menu to the source view's frame, and a scaled
    /// host drags that anchor off the button — the same reason scaling the
    /// long-pressed view backfires. `.scaleEffect` does not change layout, so
    /// the ZStack still measures exactly like the bare button.
    @ViewBuilder
    private var menuButton: some View {
        if #available(iOS 16.0, *) {
            ZStack { scaled }
                .contextMenu { menuContent }
                preview: { EmptyView() }
        } else {
            ZStack { scaled }
                .contextMenu { menuContent }
        }
    }

    private var scaled: some View {
        base.scaleEffect(isPressed ? 0.96 : 1.0)
    }

    @ViewBuilder
    private var menuContent: some View {
        ForEach(variants) { variant in
            Button {
                SegmentHaptics.light.impactOccurred()
                print("[Faircopy] panel variant selected: \(variant.title) (native contextMenu)")
                onSelect(variant)
            } label: {
                Label(variant.title, systemImage: variant.icon)
            }
        }
    }

    private var base: some View {
        RoundedRectangle(cornerRadius: 12)
            .foregroundStyle(.white)
            .opacity(isPressed ? 0.05 : 0.1)
            .overlay { label.opacity(isPressed ? 0.5 : 1) }
            ._onButtonGesture { pressed in
                isPressed = pressed
                if pressed { SegmentHaptics.light.impactOccurred() }
            } perform: {
                onTap()
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
    }

    private var label: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(.footnote))
    }
}
