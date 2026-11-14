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
