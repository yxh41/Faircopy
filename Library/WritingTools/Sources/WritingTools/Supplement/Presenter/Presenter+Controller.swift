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

    /// 3.0.108: the height this card was presented at.
    ///
    /// Recorded once, because tiers are relative to it: tier 1 must always come
    /// back to exactly the size the panel chose for itself, no matter how many
    /// times the user has flicked the handle since. Measured in `viewDidAppear`
    /// rather than here, since `preferredContentSize` is set by the presenter
    /// after this object exists.
    private var baseHeight: CGFloat = 0

    /// 3.0.111: state for the defensive natural-height measurement.
    ///
    /// `generation` makes a newer request cancel the older one: the reset can be
    /// asked for twice in quick succession (leave the 分词 panel, come back,
    /// leave again), and two probe chains fighting over `preferredContentSize`
    /// is how you get a card that resizes twice.
    private var naturalProbeGeneration = 0
    private var naturalProbeAttempt = 0
    private var naturalProbeSamples: [CGFloat] = []

    /// 3.0.112: one live drag.
    ///
    /// `dragAnchor` is the height the card had when the finger went down; growth
    /// is measured from there rather than accumulated per frame, so a drag that
    /// reverses direction returns to exactly the height it started at instead of
    /// drifting by the rounding error of every step.
    private var dragAnchor: CGFloat = 0
    private var dragIsActive = false
    private var dragFromHeight: CGFloat = 0
    private var dragToHeight: CGFloat = 0

    /// 3.0.113: the tier the card was resting at when the finger went down. The
    /// settle rule is relative to it, so a drag that ends 40% of the way to the
    /// next tier commits instead of snapping back to where it started.
    private var dragStartTier = 1

    /// 3.0.112: the frame probe. Nothing is drawn from these numbers — they are
    /// written to `faircopy_panel.log` once per drag so "is a per-frame resize
    /// affordable on this device" is answered by a measurement instead of a
    /// guess. `dragLayoutSum` times only our own layout pass, which is what
    /// separates "UIKit cannot keep up" from "everything else in the frame".
    private var dragLink: CADisplayLink?
    private var dragFrames = 0

    /// 3.0.114: the finger's travel, parked until the next display-link beat.
    ///
    /// 3.0.113 resized the card inside `DragGesture.onChanged`, i.e. inside the
    /// SwiftUI update that is running the gesture. Setting the hosting view's
    /// frame there forces SwiftUI to lay out again from under itself; the main
    /// thread never came back, so `onEnded` never ran and the log showed two
    /// `drag begin` lines with no `drag perf` at all. The callback now records
    /// two fields and returns, and the resize happens on the display link's own
    /// beat, outside any SwiftUI transaction.
    private var pendingDragGrowth: CGFloat = 0
    private var hasPendingDragGrowth = false

    /// 3.0.114: how long one resize may take before following is abandoned.
    ///
    /// A per-frame SwiftUI relayout is the expensive part of this feature and
    /// the cost depends on what is on screen, so the feature throttles itself
    /// rather than trusting the estimate: the first frame over this budget
    /// stops the following for the rest of the drag, and the panel falls back
    /// to "tap and it snaps" — which is slower than the flick version but never
    /// jams the UI.
    private static let dragFollowBudget: TimeInterval = 0.040
    private var dragFollowDisabled = false

    /// 3.0.114: at most one resize per 30Hz.
    ///
    /// 60Hz commits double the layout work for a difference nobody can see on a
    /// large flat card, and they leave no headroom for the relayout that SwiftUI
    /// has to do behind it.
    private static let dragApplyInterval: CFTimeInterval = 1.0 / 30.0
    private var lastDragApplyStamp: CFTimeInterval = 0

    private var dragIntervalSum: TimeInterval = 0
    private var dragIntervalMax: TimeInterval = 0
    private var dragSlowFrames = 0
    private var dragLastStamp: CFTimeInterval = 0
    private var dragLayoutCount = 0
    private var dragLayoutSum: TimeInterval = 0
    private var dragLayoutMax: TimeInterval = 0

    init(context: Presenter.Context) {
        self.context = context
        super.init(rootView: .init(context: context))
        // The view owns the tier (it is the thing with the gesture), this
        // controller is the only thing that can resize the card.
        context.heightTierHandler = { [weak self] tier in
            self?.applyHeightTier(tier)
        }
        context.naturalHeightHandler = { [weak self] in
            self?.resetHeightToNatural()
        }
        context.heightDragBegan = { [weak self] in
            self?.beginHeightDrag()
        }
        context.heightDragMoved = { [weak self] growth in
            self?.moveHeightDrag(growth: growth)
        }
        context.heightDragEnded = { [weak self] in
            self?.endHeightDrag()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 3.0.108: 1 = as presented, 2 = ~1.55x, 3 = ~2.05x, clamped to the screen.
    ///
    /// Only the card's own height changes. Every region that can grow — the word
    /// chips (`GeometryReader` + `ScrollView`) and the answer
    /// (`StickToBottomScrollView`) — is already flexible, so they pick up the
    /// extra space without a single layout change in SwiftUI.
    ///
    /// Applied in one step per tier, never per drag frame: `preferredContentSize`
    /// is what UIKit measures the popover from, and a card that is told a new
    /// height 60 times a second is how you get content that has already grown
    /// while the border is still on its way.
    func applyHeightTier(_ tier: Int) {
        let base = baseHeight > 1 ? baseHeight : view.bounds.height
        guard base > 1 else {
            fcPanelLog("panel height ignored: no base height yet (tier=\(tier))")
            return
        }
        let container = presentationController?.containerView ?? view.window
        let available = (container?.bounds.height ?? UIScreen.main.bounds.height) - 2 * 40
        let limit = max(base, available)
        let factors: [CGFloat] = [1, 1, 1.55, 2.05]
        let index = min(max(tier, 1), factors.count - 1)
        let target = min(floor(base * factors[index]), floor(limit))
        let previous = preferredContentSize.height
        guard abs(target - previous) > 0.5 else { return }

        preferredContentSize = CGSize(width: preferredContentSize.width, height: target)
        // Two different presentations, two different owners of the layout: a
        // popover re-reads `preferredContentSize` when its container lays out,
        // while the Q-bounce card computes its frame from that value every pass.
        // Poking the container covers both, and costs nothing when the style
        // does not use it.
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.presentationController?.containerView?.setNeedsLayout()
            self.presentationController?.containerView?.layoutIfNeeded()
            self.view.superview?.setNeedsLayout()
        }
        fcPanelLog(
            "panel height tier=\(index) base=\(Int(base)) \(Int(previous))->\(Int(target)) "
                + "limit=\(Int(limit)) style=\(modalPresentationStyle.rawValue)")
        // 3.0.109: `preferredContentSize` is a request, not an outcome — and the
        // 3.0.108 log could only prove the request had been made. Record what the
        // card was actually laid out at once this pass is done, so "accepted but
        // not applied" is distinguishable from "never submitted" from a file.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let spring = self.presentationController as? FaircopySpringPresentationController
            let applied = spring?.laidOutCardHeight ?? self.view.bounds.height
            fcPanelLog("panel height applied card=\(Int(applied)) want=\(Int(target))")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if baseHeight <= 0 { baseHeight = view.bounds.height }
    }

    // MARK: - 3.0.112: continuous drag

    /// Frames up to this long are considered on time. 60Hz gives 16.7ms per
    /// frame, so 20ms already means one dropped frame.
    private static let dragSlowFrame: TimeInterval = 0.020

    /// 3.0.113: see `moveHeightDrag` — a centred card has to grow by twice the
    /// travel for its top edge, the one the handle sits on, to track the finger.
    private static let centeredGrowthFactor: CGFloat = 2

    func beginHeightDrag() {
        guard !dragIsActive else { return }
        dragIsActive = true
        dragAnchor = preferredContentSize.height > 1
            ? preferredContentSize.height
            : view.bounds.height
        dragFromHeight = dragAnchor
        dragToHeight = dragAnchor
        dragStartTier = geometricHeightTier()
        dragFrames = 0
        dragIntervalSum = 0
        dragIntervalMax = 0
        dragSlowFrames = 0
        dragLastStamp = 0
        dragLayoutCount = 0
        dragLayoutSum = 0
        dragLayoutMax = 0
        pendingDragGrowth = 0
        hasPendingDragGrowth = false
        dragFollowDisabled = false
        lastDragApplyStamp = 0
        let link = CADisplayLink(target: self, selector: #selector(handleDragFrame(_:)))
        link.add(to: .main, forMode: .common)
        dragLink = link
        // 3.0.115: the soft edge is the most expensive part of a resize frame and
        // nobody is looking at it while the card is moving. Hiding it keeps the
        // shadow path untouched, so Core Animation can reuse the rasterisation.
        (presentationController as? FaircopySpringPresentationController)?
            .shadowSuppressed = true
        fcPanelLog(
            "drag begin anchor=\(Int(dragAnchor)) base=\(Int(baseHeight)) "
                + "style=\(modalPresentationStyle.rawValue)")
    }

    /// Every callback that arrives late widens the gap to the previous one, and
    /// that gap is exactly the dropped-frame count in disguise.
    ///
    /// 3.0.114: this is also where the card is resized. The gesture callback only
    /// parks the travel; the resize runs here, on the display link's beat, so it
    /// is never nested inside a SwiftUI update.
    @objc private func handleDragFrame(_ link: CADisplayLink) {
        let previous = dragLastStamp
        dragLastStamp = link.timestamp
        if previous > 0 {
            let interval = link.timestamp - previous
            // A gesture that pauses (finger held still, no new layout) reports
            // one enormous gap when it resumes; the display link is not the
            // thing that stalled there, so ignore anything longer than a second.
            if interval > 0, interval < 1 {
                dragFrames += 1
                dragIntervalSum += interval
                dragIntervalMax = max(dragIntervalMax, interval)
                if interval > Self.dragSlowFrame { dragSlowFrames += 1 }
            }
        }
        if hasPendingDragGrowth,
           link.timestamp - lastDragApplyStamp >= Self.dragApplyInterval
        {
            hasPendingDragGrowth = false
            lastDragApplyStamp = link.timestamp
            applyDragGrowth(pendingDragGrowth)
        }
    }

    /// One call per touch frame. `growth` is how far the finger has travelled,
    /// in points, positive = dragged up.
    ///
    /// 3.0.114: records, does not resize. See `pendingDragGrowth`.
    func moveHeightDrag(growth: CGFloat) {
        guard dragIsActive else { return }
        pendingDragGrowth = growth
        hasPendingDragGrowth = true
    }

    /// The resize itself, one per display-link beat at most.
    ///
    /// The card is vertically centred (`frameOfPresentedViewInContainerView`
    /// puts it at `(container - height) / 2`), so growing it by N moves its top
    /// edge up by only N/2 — the handle would drift away from the finger at half
    /// speed and read as "not following". Doubling the travel makes the top edge
    /// land exactly under the finger while the card stays centred.
    private func applyDragGrowth(_ growth: CGFloat) {
        guard dragIsActive, !dragFollowDisabled else { return }
        let container = presentationController?.containerView ?? view.window
        let available = floor((container?.bounds.height ?? UIScreen.main.bounds.height) - 2 * 40)
        let lowest = min(baseHeight > 1 ? baseHeight : dragAnchor, available)
        let wanted = dragAnchor + growth * Self.centeredGrowthFactor
        let target = min(max(wanted, lowest), max(lowest, available))
        dragToHeight = target
        // 1.5pt rather than 0.5: a sub-2pt step is invisible and would only buy
        // another full SwiftUI relayout.
        guard abs(target - preferredContentSize.height) > 1.5 else { return }

        let started = CACurrentMediaTime()
        // Implicit animations would fight the finger: each frame would arrive
        // as the start of a new 0.25s curve.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preferredContentSize = CGSize(width: preferredContentSize.width, height: target)
        if let spring = presentationController as? FaircopySpringPresentationController {
            // 3.0.113: the card is placed directly instead of asking for a
            // layout pass. `preferredContentSize` does not mark the container
            // dirty, so `containerView.layoutIfNeeded()` returned without doing
            // anything and the card never moved.
            spring.applyCardFrameNow()
        } else {
            // The popover path owns its own layout; it only needs to be told.
            presentationController?.containerView?.setNeedsLayout()
            presentationController?.containerView?.layoutIfNeeded()
            view.superview?.setNeedsLayout()
            view.superview?.layoutIfNeeded()
        }
        CATransaction.commit()
        let spent = CACurrentMediaTime() - started
        dragLayoutCount += 1
        dragLayoutSum += spent
        dragLayoutMax = max(dragLayoutMax, spent)
        if spent > Self.dragFollowBudget {
            dragFollowDisabled = true
            hasPendingDragGrowth = false
            fcPanelLog(String(
                format: "drag follow off: one frame cost %.1fms at=%d budget=%.0fms",
                spent * 1000, Int(target), Self.dragFollowBudget * 1000))
        }
    }

    func endHeightDrag() {
        guard dragIsActive else { return }
        dragIsActive = false
        dragLink?.invalidate()
        dragLink = nil

        let frames = max(dragFrames, 1)
        let layoutCount = max(dragLayoutCount, 1)
        let card = (presentationController as? FaircopySpringPresentationController)?
            .laidOutCardHeight ?? view.bounds.height
        // ASCII only: the verify script proves these exact bytes are in the
        // dylib, and a non-ASCII character would land in `__ustring` instead.
        // `card` is the field that matters: if it never left `from`, the card
        // did not follow the finger no matter what the frame numbers say.
        fcPanelLog(String(
            format: "drag perf frames=%d avg_frame=%.1fms max_frame=%.1fms "
                + "slow=%d layout_avg=%.1fms layout_max=%.1fms from=%d to=%d card=%d follow=%d",
            dragFrames,
            dragIntervalSum / Double(frames) * 1000,
            dragIntervalMax * 1000,
            dragSlowFrames,
            dragLayoutSum / Double(layoutCount) * 1000,
            dragLayoutMax * 1000,
            Int(dragFromHeight),
            Int(dragToHeight),
            Int(card),
            dragFollowDisabled ? 0 : 1
        ))

        let tier = settlingHeightTier()
        // `dir` says which branch the settle rule took, which is the one thing
        // the log could not answer in 3.0.114: a drag that ends in the dead band
        // looks identical whether it was never promoted or promoted and pulled
        // back.
        let direction = tier > dragStartTier ? "up" : (tier < dragStartTier ? "down" : "same")
        fcPanelLog(String(
            format: "drag settle tier=%d at=%d start=%d dir=%@",
            tier, Int(preferredContentSize.height), dragStartTier, direction))
        // Restored before the snap so the layout pass it triggers redraws the
        // path at the tier's size instead of leaving the drag's corner radius
        // behind.
        (presentationController as? FaircopySpringPresentationController)?
            .shadowSuppressed = false
        // The card snaps to a tier, exactly as the flick version did, so the
        // three sizes stay the defined states. `applyHeightTier` animates it.
        context.commitHeightTier(tier)
        applyHeightTier(tier)
    }

    /// Which tier a drag that ended at the current height settles on.
    ///
    /// 3.0.113: hysteresis around the tier the drag started from, 40% of the gap
    /// in either direction. "Nearest tier" was the wrong rule: dragging from 368
    /// to 466 covers a quarter of the way to 570, so geometric distance kept
    /// calling it 1 and the card snapped all the way back — the drag looked
    /// like it had done nothing. Starting from the tier the user was on, 40% up
    /// means "halfway there, commit", and 40% down means "you have clearly
    /// shrunk it, go back a step".
    private func settlingHeightTier() -> Int {
        let base = baseHeight > 1 ? baseHeight : max(1, preferredContentSize.height)
        let factors: [CGFloat] = [1, 1, 1.55, 2.05]
        let height = preferredContentSize.height
        var tier = min(max(dragStartTier, 1), factors.count - 1)
        // 3.0.115: one direction only.
        //
        // Walking up and then walking down in the same call cancelled itself
        // out. Stepping up needs 40% of the gap (368 -> 448.96); stepping back
        // down needs the new tier to fall 40% below its own size (489.44). Every
        // height in between was raised one tier and lowered again, so the card
        // settled exactly where it started — the dead band is why a drag to 450
        // or to 481 snapped all the way back to 368 in the 3.0.114 log.
        if height > base * factors[tier] {
            while tier < factors.count - 1,
                  height >= base * (factors[tier] + (factors[tier + 1] - factors[tier]) * 0.4)
            {
                tier += 1
            }
        } else if height < base * factors[tier] {
            while tier > 1,
                  height <= base * (factors[tier] - (factors[tier] - factors[tier - 1]) * 0.4)
            {
                tier -= 1
            }
        }
        return tier
    }

    /// 3.0.110: back to the size the current content actually needs.
    ///
    /// Measured, not restored from `baseHeight`. The button grid is taller than
    /// the 分词 panel the user expanded from (368), so putting that number back
    /// would squeeze the grid rather than remove the empty space. Only a fresh
    /// fitting pass answers "how tall does this screen want to be".
    ///
    /// Deferred one runloop because it is called from `onChange`: at that moment
    /// SwiftUI has decided to show the grid but has not laid it out yet, and a
    /// fitting pass taken now would still measure the outgoing 分词 view.
    ///
    /// 3.0.111: one pass is not evidence. `systemLayoutSizeFitting` answers from
    /// whatever tree is attached *right now* — mid-swap it answers for an empty
    /// tree, and an empty tree still has a minimum height (the panel's chrome:
    /// measured at 219 on a card that really wanted 368). 3.0.110 took that at
    /// face value once and froze the card at 219, and because `showsHeightGrip`
    /// was already false there was no second call to correct it. So: only
    /// measure while the card is on a window, keep sampling until two passes
    /// agree, take the largest reading of the run, and refuse anything that has
    /// collapsed well below the height this card was presented at.
    func resetHeightToNatural() {
        // A drag owns the height while the finger is down; measuring "what the
        // content wants" then would fight it and, worse, could resize the card
        // out from under the gesture if the output cleared mid-drag.
        guard !dragIsActive else {
            fcPanelLog("panel height reset skipped: a drag owns the height")
            return
        }
        naturalProbeGeneration &+= 1
        let generation = naturalProbeGeneration
        naturalProbeAttempt = 0
        naturalProbeSamples = []
        probeNaturalHeight(generation: generation)
    }

    private func probeNaturalHeight(generation: Int) {
        // First pass on the next runloop, later passes spaced out so a slow
        // content swap has time to land.
        let delay: TimeInterval = naturalProbeAttempt == 0 ? 0 : 0.14
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.naturalProbeGeneration == generation else { return }
            // Off window there is no content to measure; the fitting pass would
            // answer with the empty tree again. There is nothing to resize here
            // either (the card is not on screen), so stop instead of guessing.
            guard self.view.window != nil else {
                fcPanelLog("panel height probe skipped: card is not on a window")
                return
            }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            let width = self.preferredContentSize.width > 1
                ? self.preferredContentSize.width
                : self.view.bounds.width
            let fitting = self.view.systemLayoutSizeFitting(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            let sample = floor(fitting.height)
            let last = self.naturalProbeSamples.last
            self.naturalProbeSamples.append(sample)
            self.naturalProbeAttempt += 1

            let settled = last.map { abs($0 - sample) <= 2 } ?? false
            if settled || self.naturalProbeAttempt >= 6 {
                let best = self.naturalProbeSamples.max() ?? sample
                self.applyNaturalHeight(best, settled: settled)
            } else {
                fcPanelLog(
                    "panel height probe #\(self.naturalProbeAttempt) "
                        + "natural=\(Int(sample)) waiting for a stable reading")
                self.probeNaturalHeight(generation: generation)
            }
        }
    }

    /// The tier whose height is closest to what the card is at right now. Only
    /// used to record where a drag started, never to decide where it ends.
    private func geometricHeightTier() -> Int {
        let base = baseHeight > 1 ? baseHeight : max(1, preferredContentSize.height)
        let ratio = preferredContentSize.height / base
        let factors: [CGFloat] = [1, 1, 1.55, 2.05]
        var best = 1
        var bestDiff = CGFloat.greatestFiniteMagnitude
        for index in 1 ..< factors.count {
            let diff = abs(ratio - factors[index])
            if diff < bestDiff {
                bestDiff = diff
                best = index
            }
        }
        return best
    }

    private func applyNaturalHeight(_ natural: CGFloat, settled: Bool) {
        let samples = naturalProbeSamples.map { String(Int($0)) }.joined(separator: "/")
        // A card never legitimately collapses to under 60% of the height it was
        // presented at: the title, the divider and the grid are always there.
        // Something that far below `baseHeight` is the empty tree answering, so
        // keep the current size — a card that is a little too tall is a cosmetic
        // nuisance, a card squeezed to 219 is a broken panel.
        if baseHeight > 1, natural < baseHeight * 0.6 {
            fcPanelLog(
                "panel height reset rejected: natural=\(Int(natural)) samples=\(samples) "
                    + "below base=\(Int(baseHeight))")
            return
        }
        let container = presentationController?.containerView ?? view.window
        let available = (container?.bounds.height ?? UIScreen.main.bounds.height) - 2 * 40
        let target = max(1, min(natural, floor(max(CGFloat(1), available))))
        let previous = preferredContentSize.height
        guard abs(target - previous) > 0.5 else {
            fcPanelLog(
                "panel height reset: natural=\(Int(natural)) samples=\(samples) already fits")
            return
        }

        preferredContentSize = CGSize(width: preferredContentSize.width, height: target)
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.presentationController?.containerView?.setNeedsLayout()
            self.presentationController?.containerView?.layoutIfNeeded()
            self.view.superview?.setNeedsLayout()
        }
        fcPanelLog(
            "panel height reset natural=\(Int(natural)) samples=\(samples) "
                + "settled=\(settled) \(Int(previous))->\(Int(target))")
        // One runloop later, record what the card actually ended up at.
        DispatchQueue.main.async {
            let spring = self.presentationController as? FaircopySpringPresentationController
            let applied = spring?.laidOutCardHeight ?? self.view.bounds.height
            fcPanelLog("panel height applied card=\(Int(applied)) want=\(Int(target))")
        }
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

        // 3.0.112: a display link retains its target. Dismissing the panel
        // mid-drag would otherwise leave the link ticking and the controller
        // alive for as long as the process lives.
        dragLink?.invalidate()
        dragLink = nil
        dragIsActive = false
        // 3.0.115: a panel dismissed mid-drag must not take the hidden shadow
        // with it — this controller can be presented again.
        (presentationController as? FaircopySpringPresentationController)?
            .shadowSuppressed = false

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

/// 3.0.108: one line per tier change, in the shared directory.
///
/// `print` from an injected process goes to a stdout nobody reads, and NSLog
/// needs a console attached to the device. Every other Faircopy diagnostic
/// already lands in this directory, so "did the card actually grow, and did
/// UIKit take the number" is answerable from a file listing instead of a
/// debugger — which matters because the popover and the Q-bounce card read
/// `preferredContentSize` through different paths.
private let fcPanelStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

private func fcPanelLog(_ line: String) {
    let path = "/var/mobile/Library/Preferences/wiki.qaq.ai.gate/faircopy_panel.log"
    let text = fcPanelStamp.string(from: Date()) + " " + line + "\n"
    guard let data = text.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        handle.write(data)
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
