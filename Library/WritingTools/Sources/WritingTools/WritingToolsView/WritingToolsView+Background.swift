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

    /// Frosted glass: a dark system material (so the white panel text stays
    /// readable in light mode too), a thin white wash to lift it, and a rim
    /// that is bright at the top-left and gone by the bottom-right — a lens,
    /// not a glow. The fill bleeds by -64 the same way the gradient does so it
    /// reaches under the popover chrome; the rim is drawn at the card's real
    /// bounds (UIKit's arrowless-popover radius is 13).
    private var frostedGlassBackground: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .padding(-64)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .padding(-64)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.85), location: 0.0),
                            .init(color: Color.white.opacity(0.28), location: 0.22),
                            .init(color: Color.white.opacity(0.06), location: 0.55),
                            .init(color: Color.clear, location: 0.85),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        // Force the material dark: the card's text is white, so a light
        // material would wash it out in light mode.
        .environment(\.colorScheme, .dark)
    }
}
