//
//  Presenter.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/8.
//

import ColorfulX
import Foundation

@objc(WritingToolsPresenter)
public class Presenter: NSObject {
    @objc(sharedInstance)
    public static let shared = Presenter()

    override private init() {
        super.init()

        // let the shader compile
        _ = AnimatedMulticolorGradientView()
    }
}
