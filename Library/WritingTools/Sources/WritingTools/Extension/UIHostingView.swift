//
//  UIHostingView.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/16.
//

import Foundation
import SwiftUI

open class UIHostingView<Content: View>: UIView {
    private let rootViewHostingController: UIHostingController<Content>

    public var rootView: Content {
        get { rootViewHostingController.rootView }
        set { rootViewHostingController.rootView = newValue }
    }

    public required init(rootView: Content) {
        rootViewHostingController = UIHostingController(rootView: rootView)
        super.init(frame: .zero)
        rootViewHostingController.view.backgroundColor = .clear
        addSubview(rootViewHostingController.view)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override open func sizeThatFits(_ size: CGSize) -> CGSize {
        rootViewHostingController.sizeThatFits(in: size)
    }

    override open func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        rootViewHostingController.sizeThatFits(in: targetSize)
    }

    override open func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority _: UILayoutPriority,
        verticalFittingPriority _: UILayoutPriority
    ) -> CGSize {
        rootViewHostingController.sizeThatFits(in: targetSize)
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        rootViewHostingController.view.frame = bounds
    }

    override open func sizeToFit() {
        if let superview {
            frame.size = rootViewHostingController.sizeThatFits(in: superview.frame.size)
        } else {
            super.sizeToFit()
        }
    }
}
