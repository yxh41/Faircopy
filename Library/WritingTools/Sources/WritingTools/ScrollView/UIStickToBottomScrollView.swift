//
//  UIStickToBottomScrollView.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/16.
//

import UIKit

class UIStickToBottomScrollView: UIScrollView {
    weak var arrangedView: UIView?

    init() {
        super.init(frame: .zero)

        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setArrangedSubview(_ view: UIView) {
        if let previousView = arrangedView {
            previousView.removeFromSuperview()
        }
        arrangedView = view

        addSubview(view)

        let fittingSize = view.sizeThatFits(.init(width: bounds.width, height: .greatestFiniteMagnitude))
        view.frame = .init(origin: .zero, size: fittingSize)

        contentSize = fittingSize

        let offsetY = max(0, contentSize.height - bounds.height)
        if offsetY > 0 {
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 1.0) {
                self.setContentOffset(.init(x: 0, y: offsetY), animated: false)
            }
        }
    }
}
