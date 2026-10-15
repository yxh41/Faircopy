//
//  Presenter+Popover.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/19.
//

import UIKit

extension Presenter.Context: UIPopoverPresentationControllerDelegate {
    public func adaptivePresentationStyle(
        for _: UIPresentationController,
        traitCollection _: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }

    public func popoverPresentationController(_ popoverPresentationController: UIPopoverPresentationController, willRepositionPopoverTo rectPtr: UnsafeMutablePointer<CGRect>, in viewPtr: AutoreleasingUnsafeMutablePointer<UIView>) {
        guard anchorRects.count > 1, let maskView = decorationViews.last else {
            return
        }
        let view = viewPtr.pointee
        if popoverPresentationController.arrowDirection == .down {
            // popover is on top
            if let firstRect = anchorRects.first {
                rectPtr.pointee = view.convert(firstRect, from: maskView)
            }
        } else {
            // popover is on bottom
            if let lastRect = anchorRects.last {
                rectPtr.pointee = view.convert(lastRect, from: maskView)
            }
        }
    }
}
