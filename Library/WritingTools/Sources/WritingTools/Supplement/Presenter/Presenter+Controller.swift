//
//  Presenter+Controller.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/18.
//

import Foundation
import SwiftUI

class WritingToolController: UIHostingController<WritingToolsView> {
    let context: Presenter.Context

    init(context: Presenter.Context) {
        self.context = context
        super.init(rootView: .init(context: context))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        assert(context.anchorView.superview != nil)
        context.targetView.resignFirstResponder()
        for decorationView in context.decorationViews {
            decorationView.alpha = 0
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        for view in context.decorationViews {
            assert(view.superview != nil)
            view.alpha = 0
        }
        UIView.animate(withDuration: 0.25) { [self] in
            for view in context.decorationViews {
                view.alpha = 0.5
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Abort any in-flight stream so a dismissed panel stops burning tokens.
        context.streamCancelled = true
        Configurator.shared.openAI.cancelStreamingRequests()

        UIView.animate(withDuration: 0.25) { [self] in
            for view in context.decorationViews {
                view.alpha = 0
            }
        } completion: { [self] _ in
            for view in context.decorationViews {
                view.removeFromSuperview()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        context.anchorView.removeFromSuperview()
        context.decorationViews.forEach { $0.removeFromSuperview() }
        if let textInput = context.targetView as? UITextInput {
            textInput.selectedTextRange = context.textProxy.replacedRange
        }
        context.targetView.becomeFirstResponder()
    }
}
