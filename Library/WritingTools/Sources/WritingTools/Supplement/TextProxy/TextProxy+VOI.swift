//
//  TextProxy+VOI.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/20.
//

import UIKit

extension TextProxy {
    static func lookupViewOfInterest(view: UIView) -> TextProxyObject? {
        if let view = view as? TextProxyObject, view._eligibleForWritingTool {
            return view
        }
        for view in view.subviews {
            if let view = lookupViewOfInterest(view: view) { return view }
        }
        return nil
    }
}
