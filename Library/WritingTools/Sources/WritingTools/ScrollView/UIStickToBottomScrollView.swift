//
//  UIStickToBottomScrollView.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/16.
//

import UIKit

class UIStickToBottomScrollView: UIScrollView {
    weak var arrangedView: UIView?

    /// 3.0.137: `UIViewRepresentable.updateUIView` runs before SwiftUI has given
    /// this view its final frame, so measuring the hosted view against a zero
    /// width used to leave it at zero size for good. Re-measure in
    /// `layoutSubviews` whenever the width actually changed (and whenever the
    /// hosted content was replaced).
    private var laidOutWidth: CGFloat = -1
    private var didLogRelayout = false

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

        // The hosted content is rebuilt on every streamed frame, so a new
        // measurement is needed even when the width did not change.
        laidOutWidth = -1
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard let view = arrangedView, bounds.width > 0 else { return }
        guard abs(bounds.width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = bounds.width

        let fittingSize = view.sizeThatFits(.init(width: bounds.width, height: .greatestFiniteMagnitude))
        view.frame = .init(origin: .zero, size: fittingSize)
        contentSize = fittingSize

        if !didLogRelayout {
            didLogRelayout = true
            NSLog("[Faircopy] output scroll relayout 3.0.137 width=\(bounds.width) height=\(fittingSize.height)")
        }

        let offsetY = max(0, contentSize.height - bounds.height)
        if offsetY > 0 {
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 1.0) {
                self.setContentOffset(.init(x: 0, y: offsetY), animated: false)
            }
        }
    }
}
