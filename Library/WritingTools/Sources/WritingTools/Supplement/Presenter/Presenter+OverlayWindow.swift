//
//  Presenter+OverlayWindow.swift
//  WritingTools
//
//  3.0.142: 外部清稿卡片改由自建透明窗口承载。
//
//  3.0.140 为了让 `.ultraThinMaterial` 能真正采样到背后内容，把卡片从 popover 的
//  独立窗口挪进了宿主窗口的 presentation container。代价立刻出现：触摸落进宿主
//  的视图层级，宿主挂在祖先视图上的长按手势 / context menu 交互照样会识别 ——
//  长按面板按钮会同时弹出宿主自己的动作菜单（WorkBuddy 的「赞 / 复制内容」、
//  其他 App 各自的长按菜单，全都会）。
//
//  同一窗口内没有干净的解法：祖先上的 gesture recognizer 一定会看到落在它子视图
//  链里的触摸，子视图再装手势只会让两边都识别。所以卡片放回自己的窗口 —— 但这次
//  不用 popover，而是一个普通的透明 `UIWindow`，把卡片呈现给它自己的 root
//  controller。窗口隔离后宿主收不到任何触摸，而 presentation controller / 入场
//  animator / 卡高拖拽这一整套都不用改（`containerView` 自然落在我们窗口里）。
//
//  玻璃仍是系统的 `.ultraThinMaterial`：材质在窗口服务端采样，透明窗口不会挡住
//  宿主画面（控制中心、音量 HUD 都靠这一点）。
//
//  ⚠️ 本仓库 CI 是 `-Werror`，且禁用 `UIApplication.windows` / `isKeyWindow`
//  （iOS 15 起废弃）。下面恢复 key window 用的是 `isHidden` + 场景窗口列表，
//  不要换回那两个 API。
//

import SwiftUI
import UIKit

/// Root of the overlay window. Its only job is to be the presenting controller of
/// the card, so the card's presentation container belongs to our window rather
/// than the host app's. It paints nothing and handles nothing: the card's own
/// presentation controller supplies the full-screen tap-catcher.
final class FaircopyOverlayHostController: UIViewController {
    /// UIKit only retains a window while its root controller is attached to it,
    /// and nothing else in the process holds the window — keep it here so the
    /// card cannot lose its window mid-presentation.
    var hostWindow: UIWindow?

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .clear
        container.isOpaque = false
        view = container
    }

    /// The host app keeps the status bar; this window exists for a card of a few
    /// hundred points and must never change how the bar looks.
    override var preferredStatusBarStyle: UIStatusBarStyle {
        .default
    }

    override var prefersStatusBarHidden: Bool {
        false
    }
}

/// Process-wide holder for the single overlay window. At most one Faircopy card
/// is on screen at a time (the presentation lock guarantees it), so one window is
/// enough and keeping it around would only risk a second, invisible card.
enum FaircopyOverlayWindowHost {
    private static var window: UIWindow?
    private static var host: FaircopyOverlayHostController?
    /// The host app's window, captured before we take key status, so input goes
    /// back the moment the card is dismissed.
    private static weak var previousWindow: UIWindow?
    /// The card currently on screen. The panel's own sheets (share, web-search
    /// alert) must be presented from this window — otherwise they land behind it,
    /// on the host's controller, where nobody can see or reach them.
    private static weak var presentedCard: UIViewController?

    /// 3.0.150: the collapsed state. While a pill is up the window is shrunk to
    /// the pill's own frame (so it cannot swallow the host app's touches) and
    /// the card is still presented, merely faded out.
    private static var floatingBall: UIView?
    private static var restoreHandler: (() -> Void)?

    /// True when `w` is the overlay window this host owns.
    static func isHosting(_ w: UIWindow?) -> Bool { w != nil && w === window }

    /// 3.0.150: shrink the window to a pill and hand the keyboard back to the
    /// host app. The card stays presented, so the panel's state is untouched.
    static func enterFloating(
        ballSize: CGFloat,
        restore: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        guard let window, let host, floatingBall == nil else { return }
        restoreHandler = restore
        let full = window.frame
        // Only a normal-level window of the same scene can take typing back.
        let keyTarget = previousWindow
            ?? window.windowScene?.windows.first {
                $0 !== window && !$0.isHidden && $0.windowLevel == .normal
            }
        keyTarget?.makeKey()
        let margin: CGFloat = 16
        let origin = CGPoint(
            x: full.maxX - ballSize - margin,
            y: full.midY - ballSize / 2
        )
        let pillFrame = CGRect(origin: origin, size: CGSize(width: ballSize, height: ballSize))
        window.frame = pillFrame
        host.view.frame = CGRect(origin: .zero, size: pillFrame.size)
        let ball = FaircopyFloatingBall(
            frame: CGRect(origin: .zero, size: pillFrame.size),
            onTap: { exitFloating() },
            onClose: close
        )
        // Added to the window, not to the host's view: the presentation
        // container sits above that view and would otherwise cover the pill.
        window.addSubview(ball)
        floatingBall = ball
        NSLog("[Faircopy] panel collapsed to a floating pill 3.0.150")
    }

    /// 3.0.150: restore the window to full screen, take the keyboard back and
    /// let the card fade in again.
    static func exitFloating() {
        guard let window, let ball = floatingBall else { return }
        ball.removeFromSuperview()
        floatingBall = nil
        let full = window.windowScene?.coordinateSpace.bounds ?? window.bounds
        window.frame = full
        host?.view.frame = CGRect(origin: .zero, size: full.size)
        window.makeKey()
        let handler = restoreHandler
        restoreHandler = nil
        handler?()
    }

    /// 3.0.150: drop the pill without restoring — used when the panel is being
    /// dismissed from the pill (long press).
    static func cancelFloating() {
        floatingBall?.removeFromSuperview()
        floatingBall = nil
        restoreHandler = nil
        guard let window else { return }
        let full = window.windowScene?.coordinateSpace.bounds ?? window.bounds
        window.frame = full
        host?.view.frame = CGRect(origin: .zero, size: full.size)
    }

    static func adopt(card controller: UIViewController) {
        presentedCard = controller
    }

    /// Top-most controller to present from: the card and whatever it already
    /// presented, falling back to the host's controller when no overlay card is
    /// up (the in-app selection path, or a card presented the old way).
    static func topMostPresenter(from base: UIViewController) -> UIViewController {
        var presenter: UIViewController = presentedCard ?? base
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }

    /// Returns the presenting controller for a card, creating the window on first
    /// use. `scene` is the host's scene: attaching to it keeps the overlay in the
    /// same orientation / size class and makes it part of the scene's window list,
    /// which is what `faircopyPanelOnScreen()` scans.
    ///
    /// Returns nil when the host has no window scene (the caller then presents
    /// exactly as before), so a scene-less environment can never regress.
    static func host(for scene: UIWindowScene?) -> FaircopyOverlayHostController? {
        if let existing = host {
            return existing
        }
        guard let scene = scene else { return nil }

        // Above the app but below system alerts: the card is modal over the host
        // app, and an alert raised while it is up must still be able to win.
        let created = UIWindow(windowScene: scene)
        created.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        created.backgroundColor = .clear
        created.isOpaque = false

        let controller = FaircopyOverlayHostController()
        controller.hostWindow = created
        created.rootViewController = controller

        // The app's own window, not the keyboard / status-bar / alert window that
        // also lives in the scene: only a normal-level window can take input back.
        previousWindow = scene.windows.first(where: { !$0.isHidden && $0.windowLevel == .normal })
            ?? scene.windows.first(where: { !$0.isHidden && $0 !== created })
        created.isHidden = false
        created.makeKey()

        window = created
        host = controller
        NSLog("[Faircopy] external card: hosted in its own window, host app cannot receive the touch (3.0.142)")
        return controller
    }

    /// Tears the window down and hands key status back to the host app. Called
    /// from `WritingToolController.viewDidDisappear` on a real dismissal, before
    /// first responder is restored — the host text view cannot take focus back
    /// while a window we own is still key.
    ///
    /// Key status is handed back synchronously (the caller re-focuses the host
    /// text view on the same tick), while hiding the window is deferred one
    /// runloop: this runs from inside UIKit's dismissal cleanup, and hiding the
    /// window that is still unwinding the transition can cut it short.
    static func release() {
        guard let dying = window else { return }
        // 3.0.150: a pill added straight to the window would outlive the window
        // cleanup below — clearing the root controller does not remove it.
        floatingBall?.removeFromSuperview()
        floatingBall = nil
        restoreHandler = nil
        // Key status goes back first: the caller re-focuses the host text view on
        // the same tick, and it cannot do that while our window is still key.
        previousWindow?.makeKey()
        previousWindow = nil
        window = nil
        presentedCard = nil
        DispatchQueue.main.async {
            // The host controller stays attached until here — UIKit is still
            // unwinding the dismissal on this tick, and dropping its presenting
            // controller mid-cleanup is how a card gets orphaned in a window that
            // no longer has a root.
            dying.isHidden = true
            dying.rootViewController = nil
            if FaircopyOverlayWindowHost.host?.hostWindow === dying {
                FaircopyOverlayWindowHost.host = nil
            }
        }
    }
}

/// 3.0.150: the collapsed panel — a draggable circular pill carrying the same
/// pen mark as the panel header.
///
/// It lives inside the (now pill-sized) overlay window, so moving it is moving
/// the window; that keeps the whole screen outside the pill transparent to the
/// host app without relying on hit-test trickery.
final class FaircopyFloatingBall: UIView {
    private let onTap: () -> Void
    private let onClose: () -> Void

    init(frame: CGRect, onTap: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onTap = onTap
        self.onClose = onClose
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        let disc = UIView(frame: bounds)
        disc.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        disc.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        disc.layer.cornerRadius = bounds.width / 2
        disc.layer.cornerCurve = .continuous
        disc.layer.borderWidth = 0.5
        disc.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        disc.isUserInteractionEnabled = false
        addSubview(disc)

        let iconSize = bounds.width * 0.52
        let iconRect = CGRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        let pen = CAShapeLayer()
        pen.frame = CGRect(origin: .zero, size: bounds.size)
        pen.path = BrandMark().path(in: iconRect).cgPath
        pen.fillColor = UIColor.clear.cgColor
        pen.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        pen.lineWidth = 1.4
        pen.lineCap = .round
        pen.lineJoin = .round
        layer.addSublayer(pen)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.55
        addGestureRecognizer(press)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Faircopy"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
        onTap()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { onClose() }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let window else { return }
        let translation = gesture.translation(in: superview)
        var frame = window.frame
        frame.origin.x += translation.x
        frame.origin.y += translation.y
        let bounds = window.windowScene?.coordinateSpace.bounds ?? frame
        frame.origin.x = min(max(bounds.minX, frame.origin.x), max(bounds.minX, bounds.maxX - frame.width))
        frame.origin.y = min(max(bounds.minY, frame.origin.y), max(bounds.minY, bounds.maxY - frame.height))
        window.frame = frame
        gesture.setTranslation(.zero, in: superview)
    }
}
