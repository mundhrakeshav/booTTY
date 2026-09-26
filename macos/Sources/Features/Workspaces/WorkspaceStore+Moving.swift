import AppKit

extension WorkspaceStore {
    // MARK: Moving Tabs

    /// `move_tab_to_workspace:N`: moves `tab` to the Nth Workspace in bar order, or the last
    /// one when N is past the end. False for N < 1, and for the Tab's own Workspace, which a
    /// Window with one Workspace always is.
    func moveTab(_ tab: TerminalController, toWorkspaceAt n: Int) -> Bool {
        reconcile()
        guard let index = index(of: .number(n)) else { return false }
        return moveTab(tab, to: workspaces[index].id)
    }

    /// `move_tab_to_new_workspace`: moves `tab` into a new "Workspace N" at the end. A
    /// Workspace's only Tab is refused.
    func moveTabToNewWorkspace(_ tab: TerminalController) -> Bool {
        reconcile()
        guard tabs(of: workspace(holding: tab).id).count > 1 else { return false }

        let id = addWorkspace(holding: [])
        if moveTab(tab, to: id) { return true }
        workspaces.removeAll { $0.id == id }
        return false
    }

    /// Moves `tab` to the end of Workspace `id`'s Tabs, or to `index` among them. The Window
    /// keeps showing what it shows, and the target keeps its remembered Tab, except that
    /// moving the shown Workspace's only Tab ends that Workspace and shows `id` with `tab`
    /// selected. A Tab moved into the shown Workspace joins its tab bar unselected. Registers
    /// Undo Move Tab.
    ///
    /// Reports false with nothing moved when `id` is the Tab's own Workspace, the Tab has a
    /// sheet up, AppKit threw, or the move would touch the shown Workspace in non-native
    /// fullscreen, which shows "Cannot Move Tab" for a shown Tab and refuses a hidden one
    /// silently. Moves between two hidden Workspaces run there.
    func moveTab(_ tab: TerminalController, to id: Workspace.ID, at index: Int? = nil) -> Bool {
        reconcile()
        let source = workspace(holding: tab).id
        guard id != source,
              workspaces.contains(where: { $0.id == id }),
              let saved = undoState(of: source),
              let from = tabs(of: source).firstIndex(where: { $0 === tab }),
              let window = tab.window,
              window.attachedSheet == nil
        else { return false }

        if source == shownID || id == shownID,
           refusesInFullscreen(tab, showing: source == shownID ? .cannotMoveTab : nil) {
            return false
        }

        guard place(tab, window, from: source, to: id, at: index) else { return false }
        registerUndoMoveTab(tab, from: saved, at: from)
        return true
    }

    /// The AppKit and store steps of `moveTab(_:to:at:)`, once it has checked the move may run.
    private func place(
        _ tab: TerminalController,
        _ window: NSWindow,
        from source: Workspace.ID,
        to id: Workspace.ID,
        at index: Int?
    ) -> Bool {
        if source != shownID {
            if id == shownID {
                guard let group = tabGroup else { return false }
                isChanging = true
                let added = Self.withoutAnimation {
                    Self.performSafely(.add) {
                        if let index {
                            group.insertWindow(window, at: min(index, group.windows.count))
                        } else {
                            group.addWindow(window)
                        }
                    }
                }
                isChanging = false
                guard added else { return false }
            }

            removeHiddenTab(tab)
            if id == shownID {
                reconcile()
                shownTab?.relabelTabs()
            } else {
                insertHidden(tab, into: id, at: index)
            }
            return true
        }

        guard let group = tabGroup else { return false }

        // The shown Workspace's only Tab: the target's Tabs join the group around it (in
        // front of it by default), so the Window is never empty, and the source Workspace
        // ends. This is a switch not made by `show`, so it cancels a swipe in progress too.
        if tabs(of: shownID).count == 1 {
            guard let target = workspaces.firstIndex(where: { $0.id == id }) else { return false }
            isChanging = true
            let incoming = workspaces[target].hiddenTabs.compactMap(\.window)
            let inserted = Self.insert(incoming, around: window, leading: index, in: group)
            isChanging = false
            guard inserted else { return false }
            cancelSwipe()

            let outgoing = shownIndex
            promoteToShown(at: target)
            workspaces.remove(at: outgoing)

            reconcile()
            invalidateRestorableState()
            didShow(window)
            return true
        }

        let wasSelected = group.selectedWindow === window
        isChanging = true
        let detached = Self.detach(window, from: group, makeKey: window.isKeyWindow || window.isMainWindow)
        isChanging = false
        guard detached else { return false }

        insertHidden(tab, into: id, at: index)
        reconcile()
        if wasSelected, let surface = shownTab?.focusedSurface { Ghostty.moveFocus(to: surface) }
        shownTab?.relabelTabs()
        return true
    }

    /// Adds `tab`, ordered out and in a group of its own, to hidden Workspace `id` at `index`,
    /// by default the end. A Workspace with no remembered Tab (a new one) remembers it.
    private func insertHidden(_ tab: TerminalController, into id: Workspace.ID, at index: Int?) {
        guard let target = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let count = workspaces[target].hiddenTabs.count
        workspaces[target].hiddenTabs.insert(tab, at: min(index ?? count, count))
        if workspaces[target].rememberedTab == nil { workspaces[target].rememberedTab = tab }
        invalidateRestorableState()
    }

    // MARK: Moving Workspaces

    /// Move Workspace to New Window: Workspace `id` leaves for a new Window of its own, with
    /// its id, name, original name, color, Tabs and Splits, and remembered Tab. `tab` is the
    /// Tab of the request's target Split. Moving the shown Workspace first shows its
    /// neighbor; moving a hidden one leaves the view as it is. No undo.
    ///
    /// Reports false, with nothing moved, when it's the Window's only Workspace; in
    /// non-native fullscreen, with "Cannot Move Workspace" unless `tab` is hidden; and for
    /// the shown Workspace while the shown Tab has a sheet, which comes forward.
    @discardableResult
    func moveToNewWindow(_ id: Workspace.ID, requestedBy tab: TerminalController) -> Bool {
        reconcile()
        guard workspaces.count > 1, workspaces.contains(where: { $0.id == id }),
              !refusesInFullscreen(tab, showing: isHidden(tab) ? nil : .cannotMoveWorkspace)
        else { return false }

        let source = shownTab?.window
        if id == shownID {
            guard !refusesUnderSheet(), showNeighbor() else { return false }
        }

        // A switch whose old Tabs all failed to order out keeps them shown.
        guard id != shownID,
              let index = workspaces.firstIndex(where: { $0.id == id }),
              Self.openWindow(holding: workspaces[index], sizedLike: source)
        else { return false }

        workspaces.remove(at: index)
        invalidateRestorableState()
        return true
    }

    /// `move_tab_to_new_window` aimed at a hidden Split: the Tab opens by Move Workspace to
    /// New Window's path, as a Window holding one Workspace, "Workspace 1". Its Workspace ends
    /// quietly if it was the last Tab, and its Undo Move Tab comes off the stack, since it
    /// left the Window alone. Refused silently (false) for a shown Tab and in non-native
    /// fullscreen.
    func moveHiddenTabToNewWindow(_ tab: TerminalController) -> Bool {
        reconcile()
        guard isHidden(tab), !isInNonNativeFullscreen,
              Self.openWindow(
                  holding: Workspace(name: Self.newName(in: []), hiddenTabs: [tab]),
                  sizedLike: shownTab?.window)
        else { return false }

        Self.dropUndoMoveTab(of: tab)
        removeHiddenTab(tab)
        return true
    }

    /// Merge All Windows, picked in `tab`'s Window: every other Window that can join hands
    /// over all its Workspaces, Window by Window from front to back, each Window's in their
    /// own order. They arrive hidden at the end, with their id, name, original name, color,
    /// Tabs and Splits, and remembered Tab, and their Tabs take this Window's store. This
    /// Window keeps showing what it shows, and the other Windows go away. No undo.
    ///
    /// Reports false, with nothing merged, in non-native fullscreen, with "Cannot Merge
    /// Windows", and when no Window can join.
    @discardableResult
    func mergeAllWindows(requestedBy tab: TerminalController) -> Bool {
        reconcile()
        guard !refusesInFullscreen(tab, showing: .cannotMergeWindows) else { return false }
        let joining = windowsJoiningMerge
        guard !joining.isEmpty else { return false }

        for store in joining {
            let arriving = store.handOver()
            for tab in arriving.flatMap(\.hiddenTabs) { tab.workspaceStore = self }
            workspaces += arriving
        }
        invalidateRestorableState()
        return true
    }

    /// The other Windows a merge into this one takes, front to back: each that can hold Tabs,
    /// unless it's in non-native fullscreen or its shown Tab has a sheet. The Quick Terminal
    /// is never one of them.
    var windowsJoiningMerge: [WorkspaceStore] {
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(self)]
        return NSApp.orderedWindows.compactMap { window in
            // A hidden Tab's place in the order says nothing about its Window's.
            guard let tab = window.windowController as? TerminalController,
                  !tab.isHidden,
                  seen.insert(ObjectIdentifier(tab.workspaceStore)).inserted
            else { return nil }

            let store = tab.workspaceStore
            store.reconcile()
            guard let shown = store.shownTab,
                  shown.holdsWorkspaces,
                  !store.isInNonNativeFullscreen,
                  !store.shownTabHasSheet
            else { return nil }
            return store
        }
    }

    /// Hands this Window's Workspaces to a merge into another Window, in bar order and all
    /// hidden: the shown Workspace's Tabs order out, and it remembers the selected one. The
    /// store is left with one empty Workspace, so the Window goes away. A Tab that failed to
    /// order out stays in it and keeps the Window open.
    private func handOver() -> [Workspace] {
        guard let group = tabGroup else { return [] }
        invalidateRestorableState()

        let selected = group.selectedWindow
        isChanging = true
        let tabs = Self.orderOut(group).compactMap { $0.windowController as? TerminalController }
        isChanging = false

        // A switcher open in an outgoing Tab closes.
        for tab in tabs { tab.workspaceSwitcherIsShowing = false }

        var handed = workspaces
        handed[shownIndex].hiddenTabs = tabs
        handed[shownIndex].rememberedTab = tabs.first { $0.window === selected } ?? tabs.first

        let left = Workspace(name: handed[shownIndex].name)
        workspaces = [left]
        shownID = left.id
        // Only the Tabs that stayed: AppKit sometimes still lists a lone ordered-out window in
        // its group, and this store would drop that Tab's Undo Move Tab, which follows it.
        knownShownTabs = Self.tabs(in: group).filter { tab in !tabs.contains { $0 === tab } }.map { Weak($0) }
        dropOrganizeUndoIfStale() // its Tabs left the Window
        return handed.filter { !$0.hiddenTabs.isEmpty }
    }

    /// Orders out every window of `group`, the selected one last so none is revealed, with
    /// animation off. Returns the ones that ordered out, in their tab order; one that failed
    /// stays in the group.
    static func orderOut(
        _ group: NSWindowTabGroup,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> [NSWindow] {
        let windows = group.windows
        let selected = group.selectedWindow
        let orderedOut = withoutAnimation {
            (windows.filter { $0 !== selected } + windows.filter { $0 === selected }).filter { window in
                perform(.orderOut) { window.orderOut(nil) }
            }
        }
        return windows.filter(orderedOut.contains)
    }

    /// Opens a new Window showing `workspace`, whose Tabs are ordered out, and gives it a
    /// store of its own. The Window takes `source`'s size and is placed as Cmd+N places one,
    /// or gets its own native fullscreen Space when `source` is in one. It becomes key, with
    /// the remembered Tab selected and focused. False, with nothing changed, if the
    /// remembered Tab couldn't come on screen.
    static func openWindow(holding workspace: Workspace, sizedLike source: NSWindow?) -> Bool {
        guard let remembered = workspace.rememberedTab ?? workspace.hiddenTabs.first,
              let window = remembered.window
        else { return false }

        let isFullscreen = source?.styleMask.contains(.fullScreen) ?? false
        if !isFullscreen {
            if let size = source?.frame.size {
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            }
            remembered.placeAsNewWindow()
        }

        // Its becoming key mustn't make its store reconcile a half-done move.
        let owner = remembered.workspaceStore
        owner.isChanging = true
        let reformed = reform(workspace.hiddenTabs.compactMap(\.window), around: window, frame: nil, below: nil)
        owner.isChanging = false
        guard let reformed else { return false }

        var shown = workspace
        shown.hiddenTabs = []
        shown.rememberedTab = nil
        let store = WorkspaceStore(workspaces: [shown], shownID: shown.id)
        for tab in workspace.hiddenTabs { tab.workspaceStore = store }

        // A Tab that failed to join stays hidden in a Workspace of its own, so it isn't lost.
        let failed = reformed.failed.compactMap { $0.windowController as? TerminalController }
        if !failed.isEmpty { _ = store.addWorkspace(holding: failed) }

        store.bind(reformed.group)
        store.knownShownTabs = Self.tabs(in: reformed.group).map { Weak($0) }
        store.invalidateRestorableState()

        if isFullscreen, !window.styleMask.contains(.fullScreen) { remembered.toggleFullscreen(mode: .native) }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if let surface = remembered.focusedSurface { Ghostty.moveFocus(to: surface) }
        remembered.relabelTabs()
        return true
    }
}
