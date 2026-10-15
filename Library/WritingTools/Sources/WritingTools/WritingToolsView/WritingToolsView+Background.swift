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

    var background: some View {
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
}
