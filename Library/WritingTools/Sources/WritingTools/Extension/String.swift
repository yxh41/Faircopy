//
//  String.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/16.
//

import Foundation
import WritingToolsLocalizable

extension String {
    var localized: String {
        WritingToolsLocalizable.shared.localizedString(forKey: self)
    }
}
