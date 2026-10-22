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
            base.contextMenu {
                ForEach(variants) { variant in
                    Button {
                        SegmentHaptics.light.impactOccurred()
                        onSelect(variant)
                    } label: {
                        Label(variant.title, systemImage: variant.icon)
                    }
                }
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
            .animation(.easeOut(duration: 0.15), value: isPressed)
    }

    private var label: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty { Image(systemName: icon) }
            Text(title)
        }
        .font(.system(.footnote))
    }
}
