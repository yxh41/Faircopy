//
//  WritingToolsView+Error.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import Foundation
import SwiftUI

let kErrorCodeRetry = -101

extension WritingToolsView {
    var errorView: some View {
        VStack {
            Text(error?.localizedDescription ?? "")
                .font(.headline.bold())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            BeautifulButton(title: "Back".localized) {
                error = nil
                resetRetryFlags()
            }
            .frame(height: 32)
        }
    }
}
