//
//  UIView.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import UIKit

extension UIView {
    var parentViewController: UIViewController? {
        var parentResponder: UIResponder? = next
        while parentResponder != nil {
            if let viewController = parentResponder as? UIViewController {
                return viewController
            }
            parentResponder = parentResponder?.next
        }
        return nil
    }
}
