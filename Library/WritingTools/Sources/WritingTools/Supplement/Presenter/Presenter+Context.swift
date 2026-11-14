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

        /// 3.0.78 / 3.0.96: what the caller wants the panel to do the moment it
        /// appears — `"segment"` (tokenize on device), `"translate"` (run the
        /// translation task at once), or empty for the normal button grid.
        ///
        /// A string rather than a boolean because the two callers disagree:
        /// Kayoko's picture action sends `mode=segment` after OCR-ing a
        /// clipboard picture (the text is the subject and the only thing left
        /// is the tokenize step), while the Snapper3 entry is called
        /// 「Faircopy 翻译」 and must arrive translating, or the button lies.
        /// Both are decided before the first frame, so neither flashes the grid.
        let autoMode: String

        var autoSegment: Bool { autoMode == "segment" }
        var autoTranslate: Bool { autoMode == "translate" }

        /// 3.0.139: true when the card was opened by an external trigger
        /// (`faircopy://panel`, the Darwin notification, or a Shortcut) rather
        /// than an in-app text selection. The panel paints itself differently
        /// for this case — a frosted-glass card instead of the animated
        /// multicolour gradient — so the user can tell at a glance that another
        /// app summoned it.
        let isExternalInvocation: Bool

        /// 3.0.139: display name of the host app that summoned the card, shown
        /// as "来自 X" under the title on external invocations. `nil` on the
        /// in-app selection path, where the source is obvious.
        let sourceAppName: String?

        @Published var scenePhase: ScenePhase = .active

        /// Set when the active stream must stop (panel dismissed, cancelled).
        /// Checked by the streaming callbacks so post-cancel events are ignored.
        var streamCancelled: Bool = false

        /// 3.0.108: how the panel asks to become taller.
        ///
        /// The height of this card is not decided in SwiftUI — it is
        /// `preferredContentSize`, measured once by `WritingToolController` from
        /// the content's natural size. Growing it therefore has to travel back
        /// out to UIKit, and a closure on the context is the shortest honest
        /// path: the view knows the tier the user picked, the controller is the
        /// only thing that can apply it.
        ///
        /// Deliberately not `@Published`: the tier is owned by the view and
        /// re-publishing it would re-render the panel on every flick, which is
        /// exactly the kind of "content moves before the border does" stutter
        /// that made continuous dragging a bad idea in the first place.
        var heightTierHandler: ((Int) -> Void)?

        /// 3.0.110: how the panel asks to go back to whatever size its current
        /// content needs.
        ///
        /// The handle only exists on 分词 and 翻译, but the height it changes
        /// belongs to the card, not to the screen inside it — so leaving an
        /// expanded panel for the button grid left a 754pt card holding a 500pt
        /// grid. Resetting to the recorded base is not the fix either: the grid
        /// is taller than the 分词 panel it came from, and restoring that number
        /// would squeeze it. Only a fresh measurement is correct.
        var naturalHeightHandler: (() -> Void)?

        /// 3.0.112: the handle now follows the finger, and the card's height is
        /// submitted once per touch frame.
        ///
        /// Three separate closures rather than one "drag" callback because the
        /// controller needs to bracket the gesture: the begin/end pair starts and
        /// stops its frame probe, and only that bracket makes the numbers mean
        /// anything ("how expensive is a per-frame resize" is unanswerable
        /// without knowing exactly which frames belonged to the drag).
        var heightDragBegan: (() -> Void)?
        var heightDragMoved: ((CGFloat) -> Void)?
        var heightDragEnded: (() -> Void)?

        /// 3.0.112: the tier the controller settled on after a drag, reported
        /// back so the handle can render its lifted state. The view owns the
        /// tier it displays, the controller owns the height it snaps to.
        var heightTierCommitted: ((Int) -> Void)?

        func applyHeightTier(_ tier: Int) {
            heightTierHandler?(tier)
        }

        func requestNaturalHeight() {
            naturalHeightHandler?()
        }

        func beginHeightDrag() {
            heightDragBegan?()
        }

        func moveHeightDrag(growth: CGFloat) {
            heightDragMoved?(growth)
        }

        func endHeightDrag() {
            heightDragEnded?()
        }

        func commitHeightTier(_ tier: Int) {
            heightTierCommitted?(tier)
        }

        init(
            parentView: UIView,
            parentController: UIViewController,
            targetView: UIView,
            anchorView: UIView,
            anchorRects: [CGRect],
            decorationViews: [UIView],
            textProxy: TextProxy,
            isStandalone: Bool = false,
            autoMode: String = "",
            isExternalInvocation: Bool = false,
            sourceAppName: String? = nil
        ) {
            self.parentView = parentView
            self.parentController = parentController
            self.targetView = targetView
            self.anchorView = anchorView
            self.anchorRects = anchorRects
            self.decorationViews = decorationViews
            self.textProxy = textProxy
            self.isStandalone = isStandalone
            self.autoMode = autoMode
            self.isExternalInvocation = isExternalInvocation
            self.sourceAppName = sourceAppName

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
        decoratesSelection: Bool = true,
        autoMode: String = "",
        isExternalInvocation: Bool = false,
        sourceAppName: String? = nil
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
            isStandalone: standalone,
            autoMode: autoMode,
            isExternalInvocation: isExternalInvocation,
            sourceAppName: sourceAppName
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
