//
//  Presenter+Controller.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/18.
//

import Foundation
import SwiftUI
import WritingToolsInjector

class WritingToolController: UIHostingController<WritingToolsView> {
    let context: Presenter.Context

    /// 3.0.76: set by the external presentation path when the Q-bounce entrance
    /// is enabled. Drives the transitioning delegate in Presenter+Spring.swift;
    /// when false this controller is a plain popover exactly as before.
    var usesSpringEntrance = false

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
        // The anchor view is only attached to the target by the menu path; external
        // triggers present from the parent controller's view and skip decorations.
        if !context.decorationViews.isEmpty {
            assert(context.anchorView.superview != nil)
        }
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
        // UIKit fires viewDidDisappear both when the panel is dismissed AND
        // when it is merely covered by another controller presented on top of
        // it. Everything below is destructive — the anchor is the panel's text
        // source — and releasing the lock while this panel is still in the
        // hierarchy is exactly what let panels stack (3.0.34). A covered panel
        // fires viewDidDisappear again once it is truly gone.
        guard isBeingDismissed || presentingViewController == nil else { return }
        // Release the external-trigger lock: the next trigger is free to present
        // again. Failing to do this would make the plugin stop responding after
        // the first dismiss.
        FC_UnlockPanelPresentation()
        context.anchorView.removeFromSuperview()
        context.decorationViews.forEach { $0.removeFromSuperview() }
        if context.isStandalone {
            // The target view was synthesized for this invocation only; drop it
            // instead of restoring first responder to the host app.
            context.targetView.resignFirstResponder()
            context.targetView.removeFromSuperview()
            return
        }
        if let textInput = context.targetView as? UITextInput {
            textInput.selectedTextRange = context.textProxy.replacedRange
        }
        context.targetView.becomeFirstResponder()
    }
}
