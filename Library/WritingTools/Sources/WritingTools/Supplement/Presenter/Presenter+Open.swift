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

public extension Presenter {
    @objc(presentToolController:)
    func presentToolController(_ responder: UIResponder) {
        guard let respondingView = responder as? UIView else { return }

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
