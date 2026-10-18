//
//  Presenter+Open.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/16.
//

import ColorfulX
import Foundation
import SwiftUI
import UIKit
import WritingToolsInjector

public extension Presenter {
    @objc(presentToolController:)
    func presentToolController(_ responder: UIResponder) {
        guard let respondingView = responder as? UIView else { return }

        // 3.0.34: the menu path used to bypass the injector's presentation
        // bookkeeping entirely, so a panel opened from the edit menu and one
        // summoned by an external trigger could stack — each hanging off its
        // own parent controller. One panel at a time, globally.
        if FC_PanelPresentationIsLocked() {
            NSLog("[Faircopy] menu trigger ignored: a panel is already on screen")
            return
        }

        guard let targetView = TextProxy.lookupViewOfInterest(view: respondingView),
              let context = obtainContextFor(targetView)
        else {
            presentUnavailable(respondingView)
            return
        }

        let anchorView = context.anchorView
        context.targetView.addSubview(anchorView)
        anchorView.frame = anchorView.frame.intersection(targetView.bounds)
        if anchorView.frame.width <= 0 || anchorView.frame.height <= 0 {
            assertionFailure()
            anchorView.frame = targetView.bounds
        }

        let toolController = WritingToolController(context: context)
        let contentSize = toolController.view.systemLayoutSizeFitting(.init(
            width: 400,
            height: CGFloat.greatestFiniteMagnitude
        ))
        toolController.view.backgroundColor = .black.withAlphaComponent(0.85)
        toolController.modalPresentationStyle = .popover
        toolController.preferredContentSize = contentSize
        toolController.popoverPresentationController?.delegate = context
        toolController.popoverPresentationController?.sourceView = context.anchorView
        toolController.popoverPresentationController?.sourceRect = context.anchorView.bounds.insetBy(dx: -2, dy: -2)
        toolController.popoverPresentationController?.canOverlapSourceViewRect = true
        toolController.popoverPresentationController?.permittedArrowDirections = [.up, .down]

        context.parentController.present(toolController, animated: true)

        // 3.0.34: lock only on a verified presentation — same rule as the
        // external paths. UIKit can silently drop the presentation when the
        // host controller left the window hierarchy; a lock taken then would
        // silence every later trigger.
        let didPresent = context.parentController.presentedViewController === toolController
            || toolController.presentingViewController != nil
        if didPresent { FC_LockPanelPresentation() }
    }

    /// External entry point (Darwin notification `wiki.qaq.faircopy.present`
    /// or the `faircopy://panel` URL forwarded by AIGate). Unlike the menu
    /// path there is no selection anchor, so the panel is presented as a
    /// centered rounded card (popover without arrow) with the standard pop
    /// animation instead of pointing at the selection.
    ///
    /// Returns `true` if the panel was presented. Returns `false` — never a
    /// shake — when the target cannot be used, so the caller can fall back to a
    /// standalone scratch anchor instead of signalling "unavailable".
    @objc(presentToolControllerFromExternalSource:)
    func presentToolControllerFromExternalSource(_ responder: UIResponder) -> Bool {
        presentCenteredCard(fromResponder: responder, standalone: false)
    }

    /// Standalone entry point: the target view was synthesized by the
    /// injector (prefilled with clipboard content) because the foreground
    /// app had no editable text. Same centered rounded card, but the
    /// controller removes the synthesized view on dismiss.
    ///
    /// Returns `true` if the panel was presented, `false` — never a shake —
    /// when even the standalone anchor could not be presented.
    @objc(presentToolControllerStandalone:)
    func presentToolControllerStandalone(_ responder: UIResponder) -> Bool {
        presentCenteredCard(fromResponder: responder, standalone: true)
    }

    private func presentCenteredCard(fromResponder responder: UIResponder, standalone: Bool) -> Bool {
        guard let parentController = (responder as? UIView)?.parentViewController else {
            // External / standalone triggers must never signal "unavailable"
            // (the shake animation). Signal failure so the caller can fall back
            // to a standalone scratch anchor (external source) or fail silently
            // (standalone).
            return false
        }
        // Do not stack panels: check this controller AND globally. The external
        // source path hangs the card off the text field's controller while the
        // standalone path hangs it off the window's root controller, so the
        // same-parent check alone misses cross-parent stacks (the 3.0.34 "two
        // panels" regression). Checked before buildContext: building the
        // context attaches decoration views to the text input, which must not
        // leak if we bail out here.
        guard parentController.presentedViewController == nil else { return false }
        if FC_PanelPresentationIsLocked() {
            NSLog("[Faircopy] panel suppressed: another panel is already on screen")
            return false
        }

        // Build the context, retrying once after a select-all. External triggers
        // often fire while a field is merely focused (collapsed selection) or, in
        // standalone mode, a synthesized anchor whose content may be empty — both
        // would otherwise be deemed ineligible and shake.
        //
        // `decoratesSelection: false` on purpose: external triggers must not paint
        // the animated magic-colour gradient onto the host app (in standalone mode
        // the anchor is a full-screen text view, so that gradient covered the whole
        // screen and looked like a moving background layer behind the panel).
        var context = buildContext(
            fromResponder: responder,
            standalone: standalone,
            decoratesSelection: false
        )
        if context == nil, let view = responder as? UIView, let proxy = TextProxy(delegatingView: view) {
            proxy.selectAll()
            context = buildContext(
                fromResponder: responder,
                standalone: standalone,
                decoratesSelection: false
            )
        }
        guard let context else {
            // Could not build a context (no parent controller reachable, or the
            // selection is still ineligible after select-all). For external /
            // standalone triggers this is a graceful no-shake failure — the
            // caller falls back to a standalone anchor or fails silently.
            return false
        }

        let toolController = WritingToolController(context: context)
        let contentSize = toolController.view.systemLayoutSizeFitting(.init(
            width: 400,
            height: CGFloat.greatestFiniteMagnitude
        ))
        toolController.view.backgroundColor = .black.withAlphaComponent(0.85)
        toolController.modalPresentationStyle = .popover
        toolController.preferredContentSize = contentSize
        toolController.popoverPresentationController?.delegate = context
        toolController.popoverPresentationController?.sourceView = context.parentController.view
        toolController.popoverPresentationController?.sourceRect = CGRect(
            x: context.parentController.view.bounds.midX,
            y: context.parentController.view.bounds.midY,
            width: 0,
            height: 0
        )
        toolController.popoverPresentationController?.canOverlapSourceViewRect = true
        toolController.popoverPresentationController?.permittedArrowDirections = []
        context.parentController.present(toolController, animated: true)

        // `present(_:animated:)` is synchronous in setting up the relationship but
        // silently gives up when the host controller is no longer in the window
        // hierarchy (a stale responder pointing at a popped screen, for example) —
        // UIKit only logs a warning. Reporting success in that case would make the
        // caller skip its standalone fallback, so the trigger would vanish with no
        // trace at all. Verify the relationship actually formed.
        let didPresent = context.parentController.presentedViewController === toolController
            || toolController.presentingViewController != nil
        guard didPresent else { return false }
        return true
    }

    private func obtainContextFor(_ view: UIView) -> Context? {
        if let context = buildContext(fromResponder: view) {
            return context
        }
        if let textProxy = TextProxy(delegatingView: view) {
            textProxy.selectAll()
        }
        if let context = buildContext(fromResponder: view) {
            return context
        }
        return nil
    }

    @objc(presentUnavailable:)
    func presentUnavailable(_ responder: UIResponder) {
        guard let responder = responder as? UIView else { return }

        let shake = CABasicAnimation(keyPath: "position")
        shake.timingFunction = CAMediaTimingFunction(
            name: CAMediaTimingFunctionName.easeInEaseOut
        )
        shake.duration = 0.05
        shake.repeatCount = 2
        shake.autoreverses = true
        shake.isRemovedOnCompletion = true
        shake.fromValue = NSValue(cgPoint: CGPoint(
            x: responder.center.x - 2,
            y: responder.center.y
        ))
        shake.toValue = NSValue(cgPoint: CGPoint(
            x: responder.center.x + 2,
            y: responder.center.y
        ))
        responder.layer.add(shake, forKey: "position")

        let background = UIView()
        background.backgroundColor = .gray.withAlphaComponent(0.1)
        background.layer.cornerRadius = responder.layer.cornerRadius
        background.clipsToBounds = true
        responder.addSubview(background)
        background.frame = responder.bounds

        UIView.animate(withDuration: 0.25, delay: 0.1) {
            background.alpha = 0
        } completion: { _ in
            background.removeFromSuperview()
        }
    }
}
