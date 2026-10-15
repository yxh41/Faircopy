//
//  StickToBottomScrollView.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/16.
//

import Foundation
import SwiftUI
import UIKit

struct StickToBottomScrollView<T: View>: UIViewRepresentable {
    typealias UIViewType = UIStickToBottomScrollView

    @ViewBuilder
    let buildView: () -> T

    func makeUIView(context _: Context) -> UIViewType {
        let view = UIStickToBottomScrollView()
        return view
    }

    func updateUIView(_ uiView: UIViewType, context _: Context) {
        let hostingView = UIHostingView(rootView: buildView())
        uiView.setArrangedSubview(hostingView)
    }
}
