import AppKit

extension WorkspaceStore {
    // MARK: Switching

    /// Shows Workspace `id`, the switch requests, swipes, jumps, and most undos make. Returns
    /// false, with the old Workspace still shown, when AppKit throws while adding or selecting
    /// the incoming Tabs, or when the Window can't switch now. Showing the shown Workspace
    /// changes nothing.
    /// A switch by any other path than the swipe itself cancels a swipe in progress.
    ///
    /// `comingForward` is for a switch after which the Window comes forward (a jump, an undo,
    /// a folder opened into it): a minimized Window is deminiaturized first, and the incoming
    /// Tab is made key. Otherwise a background or minimized Window stays as it is.
    @discardableResult
    func show(_ id: Workspace.ID, comingForward: Bool = false, bySwipe: Bool = false) -> Bool {
        reconcile()
        guard id != shownID else { return true }

        // Non-native fullscreen takes the fullscreen Tab out of the group, so there's no
        // group to swap. Requests show their alert in `allowsRequest` before this.
        guard let target = workspaces.firstIndex(where: { $0.id == id }),
              let group = tabGroup,
              let oldSelected = group.selectedWindow,
              !isInNonNativeFullscreen,
              let incoming = (workspaces[target].rememberedTab ?? workspaces[target].hiddenTabs.first)?.window
        else { return false }

        // A minimized Window is never key or main.
        if comingForward, oldSelected.isMiniaturized { oldSelected.deminiaturize(nil) }

        isChanging = true
        let orderedOut = Self.swap(
            in: group,
            adding: workspaces[target].hiddenTabs.compactMap(\.window),
            selecting: incoming,
            makeKey: comingForward || oldSelected.isKeyWindow || oldSelected.isMainWindow)
        isChanging = false
        guard let orderedOut else { return false }
        if !bySwipe { cancelSwipe() }

        // The outgoing Workspace keeps the Tabs that left the group and remembers the one
        // that was selected.
        let outgoing = shownIndex
        let outgoingTabs = orderedOut.compactMap { $0.windowController as? TerminalController }
        workspaces[outgoing].hiddenTabs = outgoingTabs
        workspaces[outgoing].rememberedTab = outgoingTabs.first { $0.window === oldSelected } ?? outgoingTabs.first
        promoteToShown(at: target)

        // A Tab that failed to order out stayed in the group, so it joined the shown
        // Workspace. If none ordered out, the outgoing Workspace has no Tabs and ends.
        if outgoingTabs.isEmpty { workspaces.remove(at: outgoing) }

        reconcile()
        invalidateRestorableState()

        // A switcher open in the outgoing Tab closes.
        for tab in outgoingTabs { tab.workspaceSwitcherIsShowing = false }

        didShow(incoming)
        return true
    }

    /// After Workspace `shownID` was shown with `incoming` selected: focus goes to its
    /// focused Split, the Tabs are relabeled, and VoiceOver announces the name.
    func didShow(_ incoming: NSWindow) {
        let tab = incoming.windowController as? TerminalController
        if let surface = tab?.focusedSurface { Ghostty.moveFocus(to: surface) }
        tab?.relabelTabs()
        if incoming.isKeyWindow, let name = workspaces.first(where: { $0.id == shownID })?.name {
            NSAccessibility.post(
                element: incoming,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: name,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    /// Makes the Workspace at `index` the shown one and newest in recency. Its Tabs are the
    /// live group's by now, so it holds none itself. Every switch but Organize's ends here.
    func promoteToShown(at index: Int) {
        let id = workspaces[index].id
        workspaces[index].hiddenTabs = []
        workspaces[index].rememberedTab = nil
        markShown(id)
        shownID = id
    }

    /// The AppKit steps of a switch, each run through `perform`.
    enum SwapStep { case add, select, orderOut }

    /// Adds `incoming`, still ordered out, to `group`, selects `target`, then orders the
    /// group's other old windows out, with animation off. Adding and selecting are all or
    /// nothing: if either fails, the added windows are ordered out again, the old selection
    /// comes back, and this returns nil. Otherwise it returns the old windows that ordered
    /// out; one that failed stays in the group.
    ///
    /// `makeKey` selects by making `target` key, for a key or main Window. Otherwise it
    /// selects within the group, so a background Window doesn't take key from the Window the
    /// user is in and a minimized one stays minimized.
    static func swap(
        in group: NSWindowTabGroup,
        adding incoming: [NSWindow],
        selecting target: NSWindow,
        makeKey: Bool,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> [NSWindow]? {
        let old = group.windows
        let oldSelected = group.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }

        func select(_ window: NSWindow) -> Bool {
            perform(.select) {
                if makeKey {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    group.selectedWindow = window
                }
            }
        }

        let added = incoming.allSatisfy { window in perform(.add) { group.addWindow(window) } }
        guard added, select(target) else {
            for window in incoming where group.windows.contains(window) {
                _ = perform(.orderOut) { window.orderOut(nil) }
            }
            if let oldSelected, group.selectedWindow !== oldSelected {
                _ = select(oldSelected)
            }
            return nil
        }

        // Everything else old is unselected now, so ordering it out reveals nothing.
        return old.filter { window in window !== target && perform(.orderOut) { window.orderOut(nil) } }
    }

    /// Makes `group` hold `windows` in their order, with `target`, one of them, selected.
    /// `target` joins if it's out and is selected, all or nothing, as in `swap`,
    /// which orders every other window out; then the rest of `windows` join around it, with
    /// animation off. False, with nothing changed, if `target` couldn't join or be selected.
    /// A window that fails to order out stays in the group, and one that fails to join stays
    /// out.
    static func regroup(
        _ group: NSWindowTabGroup,
        holding windows: [NSWindow],
        selecting target: NSWindow,
        makeKey: Bool,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> Bool {
        let adding = group.windows.contains(target) ? [] : [target]
        guard swap(in: group, adding: adding, selecting: target, makeKey: makeKey, perform: perform) != nil else {
            return false
        }

        withoutAnimation {
            var position = 0
            for window in windows {
                if let index = group.windows.firstIndex(of: window) {
                    position = index + 1
                } else if perform(.add, { group.insertWindow(window, at: position) }) {
                    position += 1
                }
            }
        }
        return true
    }

    /// The AppKit steps of re-forming an emptied group, or of opening a new Window, each run
    /// through `perform`, with animation off: `remembered` takes `frame` and comes on screen
    /// just below `joined` without taking key, or, with no `joined`, as the key window. Then
    /// the rest of `windows`, still ordered out, join its group in their order. Returns that
    /// group and the windows that failed to join, or nil if `remembered` couldn't come on
    /// screen.
    static func reform(
        _ windows: [NSWindow],
        around remembered: NSWindow,
        frame: NSRect?,
        below joined: NSWindow?,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> (group: NSWindowTabGroup, failed: [NSWindow])? {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }

        if let frame { remembered.setFrame(frame, display: false) }

        // Under "Prefer tabs: Always", AppKit would tab it into the key Window instead.
        let tabbingMode = remembered.tabbingMode
        remembered.tabbingMode = .disallowed
        let ordered = perform(.select) {
            if let joined {
                remembered.order(.below, relativeTo: joined.windowNumber)
            } else {
                remembered.makeKeyAndOrderFront(nil)
            }
        }
        remembered.tabbingMode = tabbingMode
        guard ordered, let group = remembered.tabGroup else { return nil }

        var placed = 0
        var failed: [NSWindow] = []
        for window in windows {
            if window === remembered || perform(.add, { group.insertWindow(window, at: placed) }) {
                placed += 1
            } else {
                failed.append(window)
            }
        }
        return (group, failed)
    }

    /// Shows Workspace `id` after the shown Workspace's last Tab left for another Window and
    /// emptied the group. The shown Workspace ends, and a swipe in progress is
    /// cancelled. `joined` is the Tab that left; its Window keeps key. Every Tab keeps
    /// this store, but the new group gives AppleScript a new `window id`.
    func reform(showing id: Workspace.ID, below joined: NSWindow) {
        guard let target = workspaces.firstIndex(where: { $0.id == id }),
              let remembered = (workspaces[target].rememberedTab ?? workspaces[target].hiddenTabs.first)?.window,
              let reformed = Self.reform(
                  workspaces[target].hiddenTabs.compactMap(\.window),
                  around: remembered,
                  frame: shownFrame,
                  below: joined.tabGroup?.selectedWindow ?? joined)
        else { return }
        cancelSwipe()

        let ended = shownID
        promoteToShown(at: target)
        workspaces.removeAll { $0.id == ended }

        // A Tab that failed to join stays hidden in a Workspace of its own, so it isn't lost.
        let failed = reformed.failed.compactMap { $0.windowController as? TerminalController }
        if !failed.isEmpty { _ = addWorkspace(holding: failed) }

        bind(reformed.group)
        knownShownTabs = Self.tabs(in: reformed.group).map { Weak($0) }

        let tab = remembered.windowController as? TerminalController
        if let surface = tab?.focusedSurface { Ghostty.moveFocus(to: surface) }
        tab?.relabelTabs()
    }

    /// Takes `window` out of `group`, detaching it and ordering it out in one step with
    /// animation off. A selected `window` hands the selection to its right
    /// neighbor, else its left, first, so ordering it out reveals nothing; `makeKey` selects
    /// by making that neighbor key. False, with the old selection back, when AppKit throws.
    static func detach(
        _ window: NSWindow,
        from group: NSWindowTabGroup,
        makeKey: Bool,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> Bool {
        func select(_ selected: NSWindow) -> Bool {
            perform(.select) {
                if makeKey { selected.makeKeyAndOrderFront(nil) } else { group.selectedWindow = selected }
            }
        }

        return withoutAnimation {
            let windows = group.windows
            let neighbor = group.selectedWindow === window
                ? windows.firstIndex(of: window).flatMap { neighbor(of: $0, in: windows) }
                : nil
            if let neighbor, !select(neighbor) { return false }

            guard perform(.orderOut, { window.orderOut(nil) }) else {
                if neighbor != nil { _ = select(window) }
                return false
            }
            return true
        }
    }

    /// Inserts `incoming`, still ordered out, into `group` around `window`: the first `leading`
    /// of them (all by default) in front of it and the rest right after it, keeping the
    /// selection, with animation off. All or nothing: if one fails, the added ones are ordered
    /// out again and this returns false.
    static func insert(
        _ incoming: [NSWindow],
        around window: NSWindow,
        leading: Int? = nil,
        in group: NSWindowTabGroup,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> Bool {
        withoutAnimation {
            let start = group.windows.firstIndex(of: window) ?? 0
            let leading = leading ?? incoming.count
            let inserted = incoming.enumerated().allSatisfy { offset, added in
                perform(.add) { group.insertWindow(added, at: start + offset + (offset < leading ? 0 : 1)) }
            }
            guard inserted else {
                for added in incoming where group.windows.contains(added) {
                    _ = perform(.orderOut) { added.orderOut(nil) }
                }
                return false
            }
            return true
        }
    }

    static func withoutAnimation<T>(_ body: () -> T) -> T {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        return body()
    }

    /// Runs one AppKit step under an Objective-C exception catcher and logs what threw.
    nonisolated static func performSafely(_ step: SwapStep, _ block: () -> Void) -> Bool {
        var error: NSError?
        guard GhosttyPerformSafely(block, &error) else {
            Ghostty.logger.error(
                "workspace switch failed at \(String(describing: step), privacy: .public): \(error?.localizedDescription ?? "", privacy: .public)")
            return false
        }

        return true
    }
}
