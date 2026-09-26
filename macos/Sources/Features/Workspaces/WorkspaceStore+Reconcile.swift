import AppKit

extension WorkspaceStore {
    // MARK: Membership

    /// Brings membership in line with the tab group (SPEC §2.2). Every Tab in the group
    /// belongs to this store, so one that Cmd+T, AppKit, or the bar added adopts it and joins
    /// the shown Workspace. A shown Tab that left for another Window's group adopts that
    /// Window's store. One that left alone (torn off, Move Tab to New Window) is a new Window
    /// and gets a new store. Entering or leaving non-native fullscreen is neither: the
    /// fullscreen Tab stays shown and keeps its store, whichever group it lands in.
    ///
    /// When the shown Workspace's last Tab left for another Window, the Workspace ends and
    /// the Window re-forms around its neighbor (SPEC §11.5); with no neighbor it's gone.
    ///
    /// Commands call this before touching the group, and so do KVO on the group and the
    /// Window becoming key.
    func reconcile() {
        guard !isChanging else { return }
        isChanging = true
        defer { isChanging = false }

        let group = currentGroup()
        if let group, group !== tabGroup { bind(group) }
        recordShownFrame()

        let grouped = group.map(Self.tabs(in:)) ?? []
        var changed = false
        for tab in grouped where tab.workspaceStore !== self {
            tab.workspaceStore = self
            changed = true
        }

        var shown = grouped
        var joined: NSWindow? // a Tab that left for another Window
        for tab in knownShownTabs.compactMap(\.value) where !grouped.contains(where: { $0 === tab }) {
            // Hidden by a switch.
            guard !isHidden(tab), let window = tab.window else { continue }

            // Adopted by another Window already.
            guard tab.workspaceStore === self else {
                Self.dropUndoMoveTab(of: tab)
                joined = window
                continue
            }

            if tab.isInNonNativeFullscreen {
                shown.append(tab)
                continue
            }
            guard window.isVisible else { continue } // closed

            changed = true
            Self.dropUndoMoveTab(of: tab)
            let others = (window.tabGroup.map(Self.tabs(in:)) ?? []).filter { $0 !== tab }
            let owner: WorkspaceStore
            if let other = others.first {
                owner = others.first { $0.workspaceStore.tabGroup === window.tabGroup }?.workspaceStore
                    ?? other.workspaceStore
                joined = window
            } else {
                owner = WorkspaceStore(tab: tab)
            }
            tab.workspaceStore = owner
            owner.reconcile()
            owner.invalidateRestorableState()
        }

        knownShownTabs = shown.map { Weak($0) }

        if shown.isEmpty, let joined, let neighbor = neighborID {
            reform(showing: neighbor, below: joined)
            changed = true
        }

        if changed { invalidateRestorableState() }
        dropOrganizeUndoIfTabsChanged() // a Tab Cmd+T added or one that closed changes nothing above
    }

    /// The group holding the shown Workspace's Tabs: the bound one while it holds any of this
    /// store's Tabs, else the group a shown Tab sits in now, so the store rebinds when that
    /// group object changes. A group holding another store's Tabs is that Window's, unless
    /// this store is fresh and no store has claimed the group yet: restored Tabs arrive with
    /// a store each, and the first to look claims their group.
    private func currentGroup() -> NSWindowTabGroup? {
        if let tabGroup, Self.tabs(in: tabGroup).contains(where: { $0.workspaceStore === self }) {
            return tabGroup
        }

        let isFresh = !hasBound && workspaces.count == 1
        for tab in knownShownTabs.compactMap(\.value) where tab.workspaceStore === self && !isHidden(tab) {
            // In non-native fullscreen the Tab has no group.
            guard let window = tab.window,
                  window.isVisible || window.isMiniaturized,
                  let group = window.tabGroup
            else { continue }
            let stores = Self.tabs(in: group).map(\.workspaceStore)
            if stores.allSatisfy({ $0 === self }) { return group }
            if isFresh && !stores.contains(where: { $0.tabGroup === group }) { return group }
        }

        return nil
    }

    func bind(_ group: NSWindowTabGroup) {
        tabGroup = group
        hasBound = true

        // KVO fires in the middle of AppKit's tab changes, so reconcile on a later turn that
        // sees consistent state, as VerticalTabBarModel does.
        tabGroupObservation = group.observe(\.windows) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reconcile() }
        }
    }

    static func tabs(in group: NSWindowTabGroup) -> [TerminalController] {
        group.windows.compactMap { $0.windowController as? TerminalController }
    }

    /// Every Workspace change invalidates the shown Tabs' and the app's restorable state
    /// (SPEC §17.4).
    func invalidateRestorableState() {
        for window in tabGroup?.windows ?? [] {
            window.invalidateRestorableState()
        }
        NSApp.invalidateRestorableState()
        dropOrganizeUndoIfTabsChanged()
    }

    /// Remembers the shown Tabs' frame, which a re-formed group takes (SPEC §2.3). The Tabs
    /// call this whenever their frame changes.
    func recordShownFrame() {
        if let frame = tabGroup?.selectedWindow?.frame { shownFrame = frame }
    }
}
