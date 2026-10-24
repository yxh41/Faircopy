//
//  Presenter+Spring.swift
//  WritingTools
//
//  3.0.76: 「Q 弹」面板入场。
//
//  外部唤起（Kayoko 的 faircopy://panel、Darwin 通知、快捷指令）走的是
//  presentCenteredCard，面板是一个无箭头的 popover。popover 的入场过渡由 UIKit
//  自己驱动（固定 fade + 0.96 → 1.0），既不能换成 spring，也够不到 SwiftUI 的
//  .spring —— 所以这一路改成自定义 presentation：卡片外观自己画（13pt 圆角 +
//  柔和阴影 + 点空白处关闭），入场由 FaircopySpringAnimator 从 0.72 弹到 1.0。
//
//  开关关掉时 presentCenteredCard 完全走原来那套 popover 代码，一个字符都没改，
//  所以「系统过渡」和「Q 弹」两种状态都能用，出问题只要关开关。
//

import UIKit

// MARK: - 设置

/// KEEP IN SYNC with `PanelAnimationSettings` / `PanelAnimationSettingsStore` in
/// AIGate's FaircopyRootView.swift — AIGate does not link the WritingTools
/// framework, so the type is duplicated on purpose. The property names must
/// match or the JSON will not decode on this side.
struct FaircopyPanelAnimationSettings: Codable {
    var springEntrance: Bool
}

enum FaircopyPanelAnimationStore {
    /// KEEP IN SYNC with the same path in FaircopyRootView.swift.
    static let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_panel_animation.json"

    /// Read on every presentation, not cached: the panel is injected into a
    /// dozen processes and the toggle is flipped in the settings app, which is a
    /// different process entirely. A cached read would ignore the toggle until
    /// the host app relaunched.
    static func load() -> FaircopyPanelAnimationSettings {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let settings = try? JSONDecoder().decode(FaircopyPanelAnimationSettings.self, from: data)
        else { return FaircopyPanelAnimationSettings(springEntrance: false) }
        return settings
    }
}

// MARK: - Presentation controller

/// Replaces the arrowless popover used by the external paths with a hand-built
/// card so the entrance is fully owned by `FaircopySpringAnimator`.
///
/// The card is a three-layer sandwich: `cardView` (shadow, no clipping) →
/// `clipView` (rounded, clipping) → presented controller's view. The animator
/// only ever touches `cardView`, so the presented view's frame stays stable and
/// no layout pass can fight the transform mid-animation.
final class FaircopySpringPresentationController: UIPresentationController {
    /// The view the animator scales. Exposed so the animator does not have to
    /// guess which view in the container is the card.
    private(set) var animatedCard: UIView?

    /// Set by the animator before it touches anything. Only guards one
    /// pathological ordering (a system that runs the animator before this
    /// setup): without it, the alpha-0 start state below would be applied after
    /// the animation finished and the panel would stay invisible forever.
    private var animatorDidStart = false

    func markAnimatorStarted() {
        animatorDidStart = true
    }

    private let backdropView = UIView()
    private let cardView = UIView()
    private let clipView = UIView()

    /// Matches the radius UIKit uses for an arrowless popover, so switching the
    /// toggle on does not visibly change the card.
    private static let cornerRadius: CGFloat = 13
    private static let screenMargin: CGFloat = 20

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let bounds = container.bounds
        let preferred = presentedViewController.preferredContentSize
        guard bounds.width > 1, bounds.height > 1 else {
            return CGRect(origin: .zero, size: preferred)
        }
        let limitWidth = max(1, bounds.width - Self.screenMargin * 2)
        let limitHeight = max(1, bounds.height - Self.screenMargin * 2)
        let width = min(floor(preferred.width > 0 ? preferred.width : limitWidth), floor(limitWidth))
        let height = min(floor(preferred.height > 0 ? preferred.height : limitHeight), floor(limitHeight))
        return CGRect(
            x: floor((bounds.width - width) / 2),
            y: floor((bounds.height - height) / 2),
            width: width,
            height: height
        )
    }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        guard let container = containerView else { return }

        // Full-screen clear catcher: reproduces the popover's tap-outside-to-
        // dismiss without dimming anything (the external path has never painted
        // a scrim, and adding one now would change the look more than the
        // animation does).
        backdropView.frame = container.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdropView.backgroundColor = .clear
        backdropView.addGestureRecognizer(UITapGestureRecognizer(
            target: self,
            action: #selector(handleBackdropTap)
        ))
        container.addSubview(backdropView)

        cardView.frame = frameOfPresentedViewInContainerView
        cardView.backgroundColor = .clear
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.3
        cardView.layer.shadowRadius = 26
        cardView.layer.shadowOffset = CGSize(width: 0, height: 12)
        // An explicit path keeps the shadow from being recomputed from the
        // alpha channel on every frame of the spring (that would composite the
        // whole card offscreen 60 times a second).
        cardView.layer.shadowPath = UIBezierPath(
            roundedRect: cardView.bounds,
            cornerRadius: Self.cornerRadius
        ).cgPath

        clipView.frame = cardView.bounds
        clipView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clipView.layer.cornerRadius = Self.cornerRadius
        clipView.layer.cornerCurve = .continuous
        clipView.clipsToBounds = true
        cardView.addSubview(clipView)
        container.addSubview(cardView)

        if let presented = presentedViewController.view {
            presented.frame = clipView.bounds
            presented.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            clipView.addSubview(presented)
        }

        // The animator springs back to identity; starting small and transparent
        // here (rather than inside animateTransition:) means the very first
        // frame the system renders is already the shrunken card.
        if !animatorDidStart {
            cardView.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
            cardView.alpha = 0
        }
        animatedCard = cardView
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard let card = animatedCard, containerView != nil else { return }
        let target = frameOfPresentedViewInContainerView
        if card.transform.isIdentity {
            card.frame = target
        } else {
            // Setting `frame` on a transformed view is undefined; adjust the
            // untransformed geometry instead and let the transform scale it.
            card.bounds = CGRect(origin: .zero, size: target.size)
            card.center = CGPoint(x: target.midX, y: target.midY)
        }
    }

    @objc private func handleBackdropTap() {
        presentedViewController.dismiss(animated: true)
    }
}

// MARK: - Animator

final class FaircopySpringAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) {
        self.presenting = presenting
        super.init()
    }

    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        presenting ? 0.62 : 0.18
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let controller = context.presentationController as? FaircopySpringPresentationController else {
            completeWithoutAnimation(context)
            return
        }
        controller.markAnimatorStarted()
        guard let card = controller.animatedCard, card.superview != nil else {
            completeWithoutAnimation(context)
            return
        }

        if presenting {
            // Opacity settles first so the "pop" is a scale beat on an already
            // solid card — a spring on alpha reads as a slow fade instead.
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                card.alpha = 1
            }
            // damping 0.36 on a 0.72 → 1.0 spring peaks around 1.09, i.e. a
            // touch bouncier than the 1.08 that was signed off on.
            UIView.animate(
                withDuration: 0.62,
                delay: 0,
                usingSpringWithDamping: 0.36,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                card.transform = .identity
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
        } else {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.curveEaseIn, .allowUserInteraction]
            ) {
                card.alpha = 0
                card.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }

    /// The presentation controller always sets the card up first, so in practice
    /// this is unreachable. It exists so a nil card can never leave the panel
    /// invisible and the transition stuck: show it plainly and finish.
    private func completeWithoutAnimation(_ context: UIViewControllerContextTransitioning) {
        if presenting,
           let view = context.view(forKey: .to),
           let controller = context.viewController(forKey: .to)
        {
            context.containerView.addSubview(view)
            view.frame = context.finalFrame(for: controller)
        }
        context.completeTransition(!context.transitionWasCancelled)
    }
}

// MARK: - Transitioning delegate

extension WritingToolController: UIViewControllerTransitioningDelegate {
    func animationController(
        forPresented _: UIViewController,
        presenting _: UIViewController,
        source _: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard usesSpringEntrance else { return nil }
        return FaircopySpringAnimator(presenting: true)
    }

    func animationController(
        forDismissed _: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard usesSpringEntrance else { return nil }
        return FaircopySpringAnimator(presenting: false)
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source _: UIViewController
    ) -> UIPresentationController? {
        guard usesSpringEntrance else { return nil }
        return FaircopySpringPresentationController(
            presentedViewController: presented,
            presenting: presenting
        )
    }
}
