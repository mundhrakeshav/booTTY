import AppKit

extension WorkspaceStore {
    // MARK: Swiping

    /// What a Tab's scroll-wheel monitor does with a scroll event in its window.
    enum SwipeEventAction: Equatable {
        case pass
        /// Keep it from the terminal and the Tab list.
        case drop
        /// Claim the gesture: `trackSwipe` this event, then let it through.
        case track
    }

    enum SwipeGesture { case none, undecided, passed, tracking, dropping }

    /// A swipe's progress, measured from the shown Workspace. Negative `amount` is fingers
    /// moving left, toward the next Workspace; its size is the share of the bar's width the
    /// pages have moved. `neighbor` is the Workspace whose page comes in beside the shown
    /// one: nil at rest and past the first or last Workspace, where the page rubber-bands.
    struct SwipeProgress: Equatable {
        var amount: CGFloat = 0
        var neighbor: Workspace.ID?
    }

    /// A claimed swipe. Its targets are fixed by id when it starts: nil past the first or
    /// last Workspace, since a swipe never wraps (SPEC §6.3).
    struct Swipe: Equatable {
        let generation: Int
        let previous: Workspace.ID?
        let next: Workspace.ID?

        /// Negative `swipe` is fingers moving left, which brings in the next Workspace.
        func target(_ swipe: CGFloat) -> Workspace.ID? {
            swipe < 0 ? next : swipe > 0 ? previous : nil
        }
    }

    /// Decides a scroll event in one of the Window's Tabs (SPEC §6.1, §6.2). A gesture whose
    /// first movement is mostly horizontal, beginning where `startsSwipe` holds, is a swipe;
    /// anything else passes untouched. A claimed gesture's own events pass, because AppKit's
    /// tracker takes them and starves if they're swallowed. Its momentum is dropped.
    func swipeAction(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        deltaX: CGFloat,
        deltaY: CGFloat,
        startsSwipe: @autoclosure () -> Bool
    ) -> SwipeEventAction {
        // Momentum has no phase and belongs to the gesture that flicked it.
        if phase.isEmpty {
            guard dropsSwipeMomentum, !momentumPhase.isEmpty else { return .pass }
            if !momentumPhase.isDisjoint(with: [.ended, .cancelled]) { dropsSwipeMomentum = false }
            return .drop
        }

        if phase.contains(.mayBegin) { return .pass }
        if phase.contains(.began) {
            dropsSwipeMomentum = false
            swipeGesture = startsSwipe() ? .undecided : .passed
        }

        let gesture = swipeGesture
        let ends = !phase.isDisjoint(with: [.ended, .cancelled])
        if ends { swipeGesture = .none }

        switch gesture {
        case .none, .passed:
            return .pass
        case .tracking, .dropping:
            if ends { dropsSwipeMomentum = true }
            return gesture == .tracking ? .pass : .drop
        case .undecided:
            guard !ends, deltaX != 0 || deltaY != 0 else { return .pass }
            guard abs(deltaX) > abs(deltaY) else {
                swipeGesture = .passed
                return .pass
            }
            swipeGesture = .tracking
            return .track
        }
    }

    /// Tracks the swipe `swipeAction` claimed on `event` (SPEC §6.2). AppKit dampens it past
    /// a side with no neighbor, where it never completes.
    func trackSwipe(_ event: NSEvent) {
        let swipe = claimSwipe()
        // The amount has the sign of scrollingDeltaX, which Natural scrolling inverts. Flip it
        // so fingers moving left bring in the next Workspace either way.
        let flip: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let toPrevious: CGFloat = swipe.previous == nil ? 0 : 1
        let toNext: CGFloat = swipe.next == nil ? 0 : 1
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: flip > 0 ? -toNext : -toPrevious,
            max: flip > 0 ? toPrevious : toNext
        ) { [weak self] amount, phase, isComplete, stop in
            MainActor.assumeIsolated {
                guard let self, self.stepSwipe(swipe, amount: amount * flip, phase: phase, isComplete: isComplete) else {
                    stop.pointee = true
                    return
                }
            }
        }
    }

    /// Starts a swipe from the shown Workspace. One still settling stops, so the new one
    /// counts from the Workspace shown now.
    func claimSwipe() -> Swipe {
        swipeGeneration += 1
        swipeSwitch = nil
        swipeProgress = SwipeProgress()
        let index = shownIndex
        return Swipe(
            generation: swipeGeneration,
            previous: index > 0 ? workspaces[index - 1].id : nil,
            next: index + 1 < workspaces.count ? workspaces[index + 1].id : nil)
    }

    /// One step of tracking `swipe`, with the amount flipped to follow the fingers. At the
    /// lift (the Ended phase), a swipe AppKit will finish switches through the one switch
    /// path, and the rest of the settle counts from the Workspace it switched to. Returns
    /// false to stop tracking: the swipe was cancelled, or is cancelled now because its
    /// target ended or a sheet appeared, which would refuse the switch.
    func stepSwipe(_ swipe: Swipe, amount: CGFloat, phase: NSEvent.Phase, isComplete: Bool = false) -> Bool {
        guard swipe.generation == swipeGeneration else { return false }

        // In case AppKit's tracker took the gesture's last event before the monitor saw it.
        if !phase.isDisjoint(with: [.ended, .cancelled]) { dropsSwipeMomentum = true }

        if let swipeSwitch {
            swipeProgress = isComplete
                ? SwipeProgress()
                : SwipeProgress(amount: amount + swipeSwitch.rebase, neighbor: swipeSwitch.from)
            return true
        }

        let target = swipe.target(amount)
        if let target, !workspaces.contains(where: { $0.id == target }) || shownTab?.window?.attachedSheet != nil {
            cancelSwipe()
            return false
        }

        if phase.contains(.ended), let target {
            let from = shownID
            guard show(target, bySwipe: true) else {
                cancelSwipe()
                return false
            }
            // -0.4 toward the next Workspace is +0.6 from it, so the settle slides on.
            let rebase: CGFloat = amount < 0 ? 1 : -1
            swipeSwitch = (rebase, from)
            swipeProgress = SwipeProgress(amount: amount + rebase, neighbor: from)
            return true
        }

        swipeProgress = isComplete ? SwipeProgress() : SwipeProgress(amount: amount, neighbor: target)
        return true
    }

    /// Cancels a swipe in progress (SPEC §6.3): nothing switches, the rest of its gesture
    /// and its momentum are dropped, and the bar shows the shown Workspace's page at once.
    func cancelSwipe() {
        swipeGeneration += 1
        swipeSwitch = nil
        if swipeGesture == .tracking { swipeGesture = .dropping }
        guard swipeProgress != SwipeProgress() else { return }
        swipeProgress = SwipeProgress()
        swipeCancels += 1
    }
}
