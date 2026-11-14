//
//  WritingToolsView+Background.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import ColorfulX
import Foundation
import SwiftUI

extension WritingToolsView {
    var color: [Color] {
        ColorfulPreset.appleIntelligence
            .colors
            .map { $0.withAlphaComponent(1.0) }
            .map { Color($0) }
    }

    /// 3.0.139: two skins, chosen by how the card was summoned.
    ///
    /// - In-app text selection keeps the animated Apple-Intelligence gradient
    ///   it has always had.
    /// - An external trigger (`faircopy://panel`, the Darwin notification, a
    ///   Shortcut) uses a frosted-glass surface with a directional rim, so the
    ///   user can tell at a glance that another app summoned the panel.
    var background: some View {
        Group {
            if context.isExternalInvocation {
                frostedGlassBackground
            } else {
                gradientBackground
            }
        }
    }

    private var gradientBackground: some View {
        ColorfulView(
            color: .constant(color),
            speed: .constant(0.25),
            bias: .constant(0.01),
            noise: .constant(0),
            transitionSpeed: .constant(1.3),
            frameLimit: .constant(30),
            renderScale: .constant(0.5)
        )
        .opacity(0.75)
        .ignoresSafeArea()
        .background(.black)
        .padding(-64)
    }

    /// 3.0.144: the frosted skin is no longer painted here.
    ///
    /// It used to be two SwiftUI `Rectangle`s (`.ultraThinMaterial` + an 8%
    /// white lift) in this ZStack, i.e. its bounds followed the content box.
    /// A `Material` samples the pixels behind its own bounds, so every frame of
    /// a height drag re-sampled and re-blurred the host — and a centred card
    /// moved those bounds as well as resizing them, which is what made the new
    /// glass panel distinctly heavier to stretch than the old gradient one.
    /// `FaircopySpringPresentationController.installGlass` now owns the blur at
    /// a fixed frame and cuts the card shape out of it with a mask, so a drag
    /// costs one path update. The SwiftUI side therefore paints nothing — but
    /// keeps the old material as a fallback until that install has actually
    /// happened, so a popover/scene-less fallback never shows a bare card.
    private var frostedGlassBackground: some View {
        Group {
            if context.glassIsManagedByUIKit {
                Color.clear
            } else {
                legacyFrostedGlass
            }
        }
    }

    /// The 3.0.139 skin, unchanged. Kept for presentation paths that do not
    /// build a `FaircopySpringPresentationController` (the glass then has to
    /// come from SwiftUI, and those paths cannot be stretched by the handle).
    private var legacyFrostedGlass: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .padding(-64)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .padding(-64)
        }
        .environment(\.colorScheme, .dark)
    }
}
