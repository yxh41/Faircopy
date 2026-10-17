//
//  Presenter+Context.swift
//  WritingTools
//
//  Created by 秋星桥 on 2024/8/19.
//

import ColorfulX
import ColorVector
import SwiftUI

extension Presenter {
    class Context: NSObject, Identifiable, ObservableObject {
        let id: UUID = .init()

        let parentView: UIView
        let parentController: UIViewController
        let targetView: UIView

        let anchorView: UIView
        let anchorRects: [CGRect]

        let decorationViews: [UIView]

        let textProxy: TextProxy

        /// True when the target view was synthesized by the external-trigger
        /// path (no host text input was available). The controller removes
        /// such a view on dismiss instead of restoring first responder.
        let isStandalone: Bool

        @Published var scenePhase: ScenePhase = .active

        /// Set when the active stream must stop (panel dismissed, cancelled).
        /// Checked by the streaming callbacks so post-cancel events are ignored.
        var streamCancelled: Bool = false

        init(
            parentView: UIView,
            parentController: UIViewController,
            targetView: UIView,
            anchorView: UIView,
            anchorRects: [CGRect],
            decorationViews: [UIView],
            textProxy: TextProxy,
            isStandalone: Bool = false
        ) {
            self.parentView = parentView
            self.parentController = parentController
            self.targetView = targetView
            self.anchorView = anchorView
            self.anchorRects = anchorRects
            self.decorationViews = decorationViews
            self.textProxy = textProxy
            self.isStandalone = isStandalone

            super.init()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneWillResignActive),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification,
                object: nil
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
        }

        @objc func sceneWillResignActive() {
            scenePhase = .inactive
        }

        @objc func sceneDidBecomeActive() {
            scenePhase = .active
        }

        @objc func sceneWillEnterForeground() {
            scenePhase = .active
        }

        @objc func sceneDidEnterBackground() {
            scenePhase = .background
        }
    }
}

extension Presenter {
    /// Builds the presentation context.
    /// - Parameter decoratesSelection: when `false`, no magic-colour decoration is
    ///   attached to the target view. External triggers use this: their anchor may
    ///   be a synthesized full-screen text view, so the animated gradient would be
    ///   painted across the whole screen and read as "a moving background layer"
    ///   behind the panel. The menu path keeps the decoration (it highlights the
    ///   real, small selection).
    func buildContext(
        fromResponder responder: UIResponder,
        standalone: Bool = false,
        decoratesSelection: Bool = true
    ) -> Context? {
        guard let fatherView = responder as? UIView else { return nil }
        guard let parentView = fatherView.superview else { return nil }
        guard let parentController = fatherView.parentViewController else { return nil }
        guard let textProxy = TextProxy(delegatingView: fatherView) else { return nil }
        let appearance = textProxy.appearanceForWritingTool
        guard textProxy.isEligibleForWritingTool else { return nil }

        var selectedRects = textProxy.selectionRectsInView
        if selectedRects.isEmpty { selectedRects = [.zero] }
        let selectionUnionRect = selectedRects.reduce(selectedRects[0]) { $0.union($1) }

        let anchorView = UIView()
        anchorView.frame = selectionUnionRect

        var preparedRects = selectedRects
        var decorationViews: [UIView] = []

        if decoratesSelection {
            let textMaskView = UIView()
            fatherView.addSubview(textMaskView)
            textMaskView.frame = fatherView.bounds

            let maskShapeLayer = prepareUnionRectLayerMaskWithCornerRadius(
                withRects: &preparedRects,
                usingCoordinateFromView: fatherView,
                convertingToSubviewForMask: textMaskView,
                withCornerRadius: 4
            )
            textMaskView.layer.addSublayer(maskShapeLayer)

            let backgroundView = magicColorBackground()
            fatherView.addSubview(backgroundView)
            backgroundView.frame = fatherView.bounds
            backgroundView.layer.mask = maskShapeLayer

            switch appearance.magicColorBehavior {
            case .behindText:
                fatherView.sendSubviewToBack(backgroundView)
            case .overText:
                fatherView.bringSubviewToFront(backgroundView)
            }

            decorationViews = [backgroundView, textMaskView]
        }

        return .init(
            parentView: parentView,
            parentController: parentController,
            targetView: fatherView,
            anchorView: anchorView,
            anchorRects: preparedRects,
            decorationViews: decorationViews,
            textProxy: textProxy,
            isStandalone: standalone
        )
    }

    func magicColorBackground() -> AnimatedMulticolorGradientView {
        let colors: [ColorVector] = ColorfulPreset
            .appleIntelligence.colors
            .map { ColorVector.init($0) }
        let magicColorView = AnimatedMulticolorGradientView()
        magicColorView.speed = 1.0
        magicColorView.transitionSpeed = 5.0
        magicColorView.clipsToBounds = true
        magicColorView.setColors(colors, animated: false)
        return magicColorView
    }

    private func prepareRects(_ rects: [CGRect], radius: CGFloat) -> [CGRect] {
        var processRects = [CGRect]()
        var lastMinY: CGFloat?
        for rect in rects {
            if let lastMinY, abs(rect.minY - lastMinY) < radius {
                let lastRect = processRects.removeLast()
                let unionRect = lastRect.union(rect)
                processRects.append(unionRect)
                continue
            }
            processRects.append(rect)
            lastMinY = rect.minY
        }
        return processRects
    }

    func prepareUnionRectLayerMaskWithCornerRadius(
        withRects rects: inout [CGRect],
        usingCoordinateFromView targetView: UIView,
        convertingToSubviewForMask maskView: UIView,
        withCornerRadius cornerRadius: CGFloat
    ) -> CAShapeLayer {
        let convertedRects = rects
            .map { targetView.convert($0, to: maskView) }
            .filter { $0.size.width > 0 && $0.size.height > 0 }
            .sorted { $0.minY < $1.minY }

        rects = prepareRects(convertedRects, radius: cornerRadius)
        let cornerRadii = CGSize(width: cornerRadius, height: cornerRadius)

        var allCorners = [UIRectCorner]()
        var firstMinX: CGFloat = 0
        var allMaxX: CGFloat = 0
        for i in 0 ..< rects.count {
            let convertedRect = rects[i]

            if convertedRect.width <= 0 || convertedRect.height <= 0 {
                assertionFailure()
                continue
            }

            var corners: UIRectCorner = []
            if i == 0 {
                firstMinX = convertedRect.minX
                corners.formUnion([.topLeft, .topRight])
            }
            if i == rects.count - 1 {
                if i > 0, abs(convertedRect.maxX - allMaxX) > cornerRadii.width {
                    var lastCorners = allCorners.removeLast()
                    lastCorners.formUnion([.bottomRight])
                    allCorners.append(lastCorners)
                }
                corners.formUnion([.bottomLeft, .bottomRight])
            }
            if i == 1, abs(convertedRect.minX - firstMinX) > cornerRadii.width {
                corners.formUnion([.topLeft])
            }
            if i == 1, convertedRect.maxX < firstMinX, rects.count == 2 {
                var lastCorners = allCorners.removeLast()
                lastCorners.formUnion([.bottomLeft])
                allCorners.append(lastCorners)
                corners.formUnion([.topRight])
            }
            allCorners.append(corners)
            allMaxX = max(allMaxX, convertedRect.maxX)
        }

        let path = UIBezierPath()
        for zip in zip(rects, allCorners) {
            let convertedRect = zip.0
            let corners = zip.1
            path.append(UIBezierPath(
                roundedRect: convertedRect,
                byRoundingCorners: corners,
                cornerRadii: cornerRadii
            ))
        }

        let shapeLayer = CAShapeLayer()
        shapeLayer.path = path.cgPath
        shapeLayer.fillColor = UIColor.white.cgColor
        return shapeLayer
    }
}
