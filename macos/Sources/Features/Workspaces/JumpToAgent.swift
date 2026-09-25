import AppKit

/// Jump to Agent (SPEC §15.2): `jump_to_agent`, the Workspace menu item, and the palette
/// entry focus the next Split whose agent needs the user, in any Workspace of any Window.
/// It isn't a Workspace command, so it runs from windows without Workspaces too.
@MainActor
enum JumpToAgent {
    /// Focuses the next Split to visit through the Jump's reveal (SPEC §2.4). False when
    /// there's nothing to visit or the reveal refuses.
    static func perform() -> Bool {
        guard let (tab, split) = target() else { return false }

        // A minimized Window comes back. The reveal does that for a hidden Tab.
        if !tab.isInHiddenWorkspace, let window = tab.window, window.isMiniaturized {
            window.deminiaturize(nil)
        }
        return tab.focusSurface(split)
    }

    /// The Tab and Split the next Jump visits, or nil with nothing to visit.
    static func target() -> (tab: TerminalController, split: Ghostty.SurfaceView)? {
        let splits = splitsInWalkOrder()
        // The walk starts from the most recently focused Split.
        let focused = splits.indices
            .compactMap { i in splits[i].split.focusInstant.map { (i, $0) } }
            .max { $0.1 < $1.1 }?.0
        return next(in: splits, from: focused) { $0.split.agentStatus }.map { splits[$0] }
    }

    /// The index of the next Split to visit, walking by position from `start`, wrapping
    /// around: the first waiting Split, else the first done one. `start` itself never counts;
    /// with no `start` the walk begins at the first Split.
    nonisolated static func next<Split>(
        in splits: [Split],
        from start: Int?,
        status: (Split) -> Ghostty.AgentStatus?
    ) -> Int? {
        let first = start.map { $0 + 1 } ?? 0
        let order = splits.indices.map { (first + $0) % splits.count }.filter { $0 != start }
        return order.first { status(splits[$0]) == .waiting } ?? order.first { status(splits[$0]) == .done }
    }

    /// Every Window's Splits by position: Windows in `goto_window`'s order (each by its shown
    /// Tab's place in `NSApp.windows`), then Workspaces in bar order, hidden ones included,
    /// then Tabs, then Splits in split-tree order. Minimized Windows count; the Quick Terminal
    /// isn't a `TerminalController`, so it never does.
    private static func splitsInWalkOrder() -> [(tab: TerminalController, split: Ghostty.SurfaceView)] {
        let tabs = NSApp.windows.compactMap { $0.windowController as? TerminalController }
        var stores: [WorkspaceStore] = []
        for tab in tabs where tab === (tab.workspaceStore.shownTab ?? tab) {
            if !stores.contains(where: { $0 === tab.workspaceStore }) { stores.append(tab.workspaceStore) }
        }

        return stores.flatMap { store in
            store.workspaces.flatMap { workspace in
                // A Window with no tab group (it can't hold Tabs) shows its one Tab.
                let shown = store.tabs(of: workspace.id)
                return workspace.id == store.shownID && shown.isEmpty
                    ? tabs.filter { $0.workspaceStore === store && !store.isHidden($0) }
                    : shown
            }
        }.flatMap { tab in
            (tab.surfaceTree.root?.leaves() ?? []).map { (tab: tab, split: $0) }
        }
    }
}
