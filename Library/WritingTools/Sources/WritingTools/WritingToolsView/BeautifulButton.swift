//
//  BeautifulButton.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

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

    /// Set when the long press wins, so the release does not also fire onTap
    /// (SwiftUI may deliver the tap after a recognised long press). Reset to
    /// false at the start of every press via `pressing`.
    @State private var suppressTap: Bool = false

    var body: some View {
        BeautifulMenuLabel(title: title, icon: icon)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                if !suppressTap { onTap() }
            }
            .onLongPressGesture(
                minimumDuration: 0.45,
                pressing: { pressing in
                    if pressing { suppressTap = false }
                },
                perform: {
                    suppressTap = true
                    onLongPress()
                }
            )
    }
}
