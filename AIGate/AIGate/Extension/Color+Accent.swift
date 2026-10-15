//
//  Color+Accent.swift
//  AIGate
//
//  Created by Lessica on 2024/8/20.
//

import SwiftUI

extension UIColor {
    static let accent = UIColor(
        red: 248.0 / 255, green: 101.0 / 255, blue: 148.0 / 255, alpha: 1
    )
}

extension Color {
    static let accent = Color(uiColor: UIColor.accent)
}
