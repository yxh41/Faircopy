//
//  Presenter+MenuItem.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/19.
//

import Foundation
import UIKit

import WritingToolsLocalizable

extension Presenter {
    @objc(writingToolMenuName)
    func writingToolMenuName() -> String {
        WritingToolsLocalizable.shared.localizedMenuItemTitle()
    }
}
