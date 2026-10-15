//
//  WritingToolsView+Retry.swift
//  WritingTools
//
//  Created by Lessica on 2024/8/28.
//

import SwiftUI

extension WritingToolsView {
    func setNeedsRetryWhenActive() {
        shouldRetryWhenActive = true
    }

    func resetRetryFlags() {
        shouldRetryWhenActive = false
        isRetrying = false
    }
}
