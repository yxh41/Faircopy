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
    /// readable in light mode too) and a thin white wash to lift it.
    ///
    /// The fill bleeds by -64 the same way the gradient does so it reaches under
    /// the card's chrome.
    ///
    /// 3.0.143: the rim is no longer drawn here. It used to be a
    /// `strokeBorder` on a `RoundedRectangle` in this ZStack, i.e. it followed
    /// *the SwiftUI content box*. That box is a few points smaller than the card
    /// the presentation controller actually lays out (the hosting view is asked
    /// to size itself, then gets that size back and centres its root inside it),
    /// so the stroke sat 3pt in from the left and 7pt down from the top while
    /// the material — bleeding -64 and clipped by the card — filled right up to
    /// the edge. The result was a double edge: a bright line 7pt inside the top
    /// with a slab of plain glass above it, worst when the card is pulled to its
    /// tallest tier and that edge lands next to the status bar. The rim is now
    /// stroked onto the card's own clip view in UIKit
    /// (`FaircopySpringPresentationController.redrawRim`), where it cannot drift
    /// from the edge it is supposed to describe.
    private var frostedGlassBackground: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .padding(-64)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .padding(-64)
        }
        // Force the material dark: the card's text is white, so a light
        // material would wash it out in light mode.
        .environment(\.colorScheme, .dark)
    }
}
