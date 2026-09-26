import AppKit

extension WorkspaceStore {
    // MARK: Undo

    /// What undo keeps of a Workspace to find it again, or to recreate it once it has ended.
    struct UndoState {
        /// The Window id of the Window it was in when the entry was made.
        let windowID: UUID
        let id: Workspace.ID
        let name: String
        let originalName: String
        let color: TerminalTabColor
        /// Its index in the bar.
        let position: Int
    }

    func undoState(of id: Workspace.ID) -> UndoState? {
        guard let position = workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        let workspace = workspaces[position]
        return UndoState(
            windowID: self.id,
            id: id,
            name: workspace.name,
            originalName: workspace.originalName,
            color: workspace.color,
            position: position)
    }

    /// Where an undo entry acts on Workspace `saved`: the Window holding it now,
    /// wherever it has moved, else, once it has ended, its last Window while that still shows
    /// a Tab. Nil once that Window has closed.
    static func live(_ saved: UndoState) -> WorkspaceStore? {
        live(saved, among: TerminalController.all.lazy.map(\.workspaceStore).filter { $0.shownTab != nil })
    }

    // ponytail: the last Window is the one the entry was made in, so a Workspace that moved
    // and then ended with no entry of its own (a Tab dragged out) comes back there. Track the
    // Window each Workspace moves to if that matters.
    static func live(_ saved: UndoState, among stores: some Collection<WorkspaceStore>) -> WorkspaceStore? {
        stores.first { $0.workspaces.contains { $0.id == saved.id } } ?? stores.first { $0.id == saved.windowID }
    }

    /// Brings back an ended Workspace holding `tabs`, hidden, with its id, name, original
    /// name, color, and `remembered` Tab (else its first), at its old position, or at the
    /// end if the Window now has fewer Workspaces.
    func recreate(_ saved: UndoState, holding tabs: [TerminalController], remembering remembered: TerminalController? = nil) {
        workspaces.insert(Self.workspace(saved, holding: tabs, remembering: remembered), at: min(saved.position, workspaces.count))
        invalidateRestorableState()
    }

    /// Brings back an ended Workspace whose last Window has closed as a Window of its own,
    /// holding `tabs`, which are ordered out and in no Workspace, by Move Workspace to New
    /// Window's path. It keeps its id, name, original name, and color, and shows
    /// `remembered`, else its first Tab. The Tabs' window style is their old Window's. False,
    /// with nothing changed, if the Tab couldn't come on screen.
    static func reopen(_ saved: UndoState, holding tabs: [TerminalController], remembering remembered: TerminalController? = nil) -> Bool {
        openWindow(holding: workspace(saved, holding: tabs, remembering: remembered), sizedLike: nil)
    }

    private static func workspace(_ saved: UndoState, holding tabs: [TerminalController], remembering remembered: TerminalController?) -> Workspace {
        Workspace(
            id: saved.id,
            name: saved.name,
            originalName: saved.originalName,
            color: saved.color,
            hiddenTabs: tabs,
            rememberedTab: remembered)
    }

    /// Whether an undo or redo may switch Workspaces now. Not while the shown Tab
    /// has a sheet, and then the Window comes forward with its sheet; not in non-native
    /// fullscreen. Neither shows an alert: the undo applies without switching.
    func allowsUndoSwitch() -> Bool {
        !refusesUnderSheet() && !isInNonNativeFullscreen
    }

    /// Undo shows what it changes: before an undo or redo changes `tab`, shows the
    /// hidden Workspace holding it, with `tab` selected and the Window coming forward. When
    /// `allowsUndoSwitch()` refuses, nothing switches.
    func showForUndo(_ tab: TerminalController) {
        reconcile()
        guard hiddenIndex(of: tab) != nil, allowsUndoSwitch(), let index = hiddenIndex(of: tab) else { return }
        workspaces[index].rememberedTab = tab
        show(workspaces[index].id, comingForward: true)
    }

    /// Undo Close Tab: puts `tab`, ordered out and in no Workspace, back in its
    /// Workspace at `index`, recreating the Workspace if it ended, then shows that Workspace
    /// with `tab` selected, coming forward. When `allowsUndoSwitch()` refuses, or without
    /// `showing` (Redo Move Tab from another Window), nothing switches: a recreated Workspace
    /// stays hidden and a Tab going back into the shown Workspace joins it unselected. A Tab
    /// going back into the shown Workspace leaves non-native fullscreen first. False, with
    /// nothing changed, when there's no tab group for it to join.
    func returnTab(_ tab: TerminalController, to saved: UndoState, at index: Int?, showing: Bool = true) -> Bool {
        reconcile()
        guard let window = tab.window else { return false }

        let target = workspaces.firstIndex { $0.id == saved.id }
        if let target, workspaces[target].id == shownID {
            leaveNonNativeFullscreen()
            guard let group = tabGroup, !group.windows.isEmpty else { return false }
            tab.workspaceStore = self
            let select = showing && allowsUndoSwitch()
            if select, let selected = group.selectedWindow, selected.isMiniaturized {
                selected.deminiaturize(nil)
            }
            _ = Self.performSafely(.add) {
                group.insertWindow(window, at: min(index ?? group.windows.count, group.windows.count))
            }
            if select { _ = Self.performSafely(.select) { window.makeKeyAndOrderFront(nil) } }
            tab.relabelTabs()
            return true
        }

        tab.workspaceStore = self
        if let target {
            let tabs = workspaces[target].hiddenTabs
            workspaces[target].hiddenTabs.insert(tab, at: min(index ?? tabs.count, tabs.count))
            invalidateRestorableState()
        } else {
            recreate(saved, holding: [tab])
        }

        if showing { showForUndo(tab) }
        return true
    }

    /// Registers Undo New Workspace for `tab`, the Tab New Workspace made. Undo
    /// closes it as Undo New Tab does, so the Workspace ends if that leaves it empty, and
    /// shows `previous`, the Workspace shown before. Redo brings the Workspace back with the
    /// same id, name, and position.
    func registerUndoForNewWorkspace(
        _ tab: TerminalController,
        previous: Workspace.ID,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?
    ) {
        guard let undoManager = tab.undoManager else { return }
        // Its own step, so each folder of a multi-folder open undoes on its own.
        undoManager.registerAsOwnStep {
            undoManager.setActionName("New Workspace")
            undoManager.registerUndo(withTarget: tab, expiresAfter: tab.undoExpiration) { tab in
                let store = tab.workspaceStore
                let saved = store.undoState(of: store.workspace(holding: tab).id)
                tab.showForUndo()
                undoManager.disableUndoRegistration {
                    tab.closeTab(showing: previous)
                }

                guard let saved else { return }
                let windowStyle = tab.windowStyle
                undoManager.registerUndo(withTarget: tab.ghostty, expiresAfter: tab.undoExpiration) { ghostty in
                    if let store = Self.live(saved) {
                        store.redoNewWorkspace(saved, withBaseConfig: baseConfig)
                        return
                    }

                    // Its Window has closed, so it comes back as a Window of its own.
                    let reopened = TerminalController(ghostty, withBaseConfig: baseConfig, windowStyle: windowStyle)
                    guard Self.reopen(saved, holding: [reopened]) else {
                        reopened.surfaceTree = .init() // closes the never-shown Tab and ends its shell
                        return
                    }
                    reopened.workspaceStore.registerUndoForNewWorkspace(reopened, previous: saved.id, withBaseConfig: baseConfig)
                }
            }
        }
    }

    /// Redo New Workspace: the Workspace comes back with a new Tab, its id, name, and
    /// position, and is shown unless `allowsUndoSwitch()` refuses.
    private func redoNewWorkspace(_ saved: UndoState, withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?) {
        reconcile()
        guard !workspaces.contains(where: { $0.id == saved.id }),
              let parent = shownTab,
              let tab = newTab(from: parent, withBaseConfig: baseConfig)
        else { return }

        let previous = shownID
        recreate(saved, holding: [tab])
        if allowsUndoSwitch() { show(saved.id, comingForward: true) }
        registerUndoForNewWorkspace(tab, previous: previous, withBaseConfig: baseConfig)
    }

    /// Registers Undo Move Tab for `tab`, which just left the Workspace `saved` describes,
    /// where it was at `index`. Undo moves it back there and shows it; the redo that move
    /// registers in turn moves it again, with the view following the move as any move's does.
    /// Both come off the stack when the Tab alone leaves the Window (`dropUndoMoveTab(of:)`).
    func registerUndoMoveTab(_ tab: TerminalController, from saved: UndoState, at index: Int) {
        guard let undoManager = tab.undoManager else { return }
        undoManager.setActionName("Move Tab")
        undoManager.registerUndo(withTarget: tab.moveTabUndoTarget, expiresAfter: tab.undoExpiration) { [weak tab] _ in
            guard let tab else { return }
            tab.workspaceStore.moveBack(tab, to: saved, at: index, showing: !undoManager.isRedoing)
        }
    }

    /// Undo or Redo Move Tab: moves `tab` to Workspace `saved.id` at `index`, recreating that
    /// Workspace hidden if it has ended; a new Workspace the move made ends if this leaves it
    /// empty. A Tab going into or out of the shown Workspace leaves non-native fullscreen
    /// first. `showing` (undo) then shows the Workspace with `tab` selected and
    /// focused, unless `allowsUndoSwitch()` refuses. Otherwise (redo) the view follows the move.
    /// The Workspace may be in another Window now, or gone with its last Window (`moveAcross`).
    private func moveBack(_ tab: TerminalController, to saved: UndoState, at index: Int, showing: Bool) {
        reconcile()
        if saved.id == shownID || !isHidden(tab) { leaveNonNativeFullscreen() }

        let target = Self.live(saved)
        guard target === self else {
            moveAcross(tab, to: saved, in: target, at: index, showing: showing)
            return
        }

        let recreated = !workspaces.contains { $0.id == saved.id }
        if recreated { recreate(saved, holding: []) }
        guard moveTab(tab, to: saved.id, at: index) else {
            if recreated { workspaces.removeAll { $0.id == saved.id } }
            return
        }

        guard showing else { return }
        if isHidden(tab) {
            showForUndo(tab)
            return
        }

        guard allowsUndoSwitch(), let window = tab.window else { return }
        if let selected = tabGroup?.selectedWindow, selected.isMiniaturized { selected.deminiaturize(nil) }
        _ = Self.performSafely(.select) { window.makeKeyAndOrderFront(nil) }
        if let surface = tab.focusedSurface { Ghostty.moveFocus(to: surface) }
    }

    /// Undo or Redo Move Tab when Workspace `saved` is in `target`, another Window, now, or
    /// has ended there, or has ended and its last Window has closed (nil):
    /// `tab` leaves this Window and goes back as Undo Close Tab puts a Tab back (`showing` as
    /// in `moveBack`), or with its Workspace as a Window of its own. Then registers the
    /// opposite entry. Nothing moves while the Tab has a sheet up. A Tab going into `target`'s
    /// shown Workspace makes that Window leave non-native fullscreen first, as `moveBack` did
    /// here for a Tab leaving this Window's shown Workspace.
    private func moveAcross(_ tab: TerminalController, to saved: UndoState, in target: WorkspaceStore?, at index: Int, showing: Bool) {
        if let target, saved.id == target.shownID { target.leaveNonNativeFullscreen() }
        let source = workspace(holding: tab).id
        guard tab.window?.attachedSheet == nil,
              let from = undoState(of: source),
              let fromIndex = tabs(of: source).firstIndex(where: { $0 === tab }),
              release(tab)
        else { return }

        let placed = target.map { $0.returnTab(tab, to: saved, at: index, showing: showing) }
            ?? Self.reopen(saved, holding: [tab])
        guard placed else {
            // So it isn't lost.
            _ = Self.openWindow(holding: Workspace(name: Self.newName(in: []), hiddenTabs: [tab]), sizedLike: nil)
            return
        }
        registerUndoMoveTab(tab, from: from, at: fromIndex)
    }

    /// Takes `tab` out of this Window for a move to another one: afterwards it's ordered out
    /// and in none of the Window's Workspaces. The shown Workspace's last Tab shows its
    /// neighbor first, and a Workspace left empty ends. The Window's only Tab leaves nothing
    /// behind. False, with nothing changed, when AppKit throws.
    private func release(_ tab: TerminalController) -> Bool {
        if !isHidden(tab), tabs(of: shownID).count == 1, let neighborID, !show(neighborID) { return false }
        if isHidden(tab) {
            removeHiddenTab(tab)
            return true
        }

        guard let group = tabGroup, let window = tab.window else { return false }
        isChanging = true
        let detached = Self.detach(window, from: group, makeKey: window.isKeyWindow || window.isMainWindow)
        isChanging = false
        guard detached else { return false }

        // Not by `reconcile()`: AppKit sometimes still lists a lone ordered-out window in its
        // group, which would keep the Tab here.
        knownShownTabs.removeAll { $0.value === tab }
        invalidateRestorableState()
        shownTab?.relabelTabs()
        return true
    }

    /// Takes `tab`'s Undo and Redo Move Tab entries off the stack, once it has left the
    /// Window alone: torn off, sent to a new Window, or dragged to another.
    static func dropUndoMoveTab(of tab: TerminalController) {
        tab.undoManager?.removeAllActions(withTarget: tab.moveTabUndoTarget)
    }

    /// Registers Undo Close Workspace for the closing Workspace `saved`, holding `tabs` and
    /// remembering `remembered`. Undo brings it back whole in its last Window and
    /// shows it unless `allowsUndoSwitch()` refuses, or, with that Window closed, as a Window
    /// of its own; redo closes it again, wherever it is.
    func registerUndoForCloseWorkspace(
        _ saved: UndoState,
        tabs: [TerminalController],
        remembered: TerminalController?
    ) {
        let kept = tabs.compactMap { tab in tab.undoState.map { (tab: tab, state: $0) } }
        guard let first = kept.first?.tab, let undoManager = first.undoManager else { return }
        let states = kept.map(\.state)
        let rememberedIndex = kept.firstIndex { $0.tab === remembered } ?? 0
        let expiration = first.undoExpiration

        undoManager.setActionName("Close Workspace")
        undoManager.registerUndo(withTarget: first.ghostty, expiresAfter: expiration) { ghostty in
            let tabs = states.map { TerminalController(ghostty, rebuilding: $0) }
            if let store = Self.live(saved) {
                store.reconcile()
                for tab in tabs { tab.workspaceStore = store }
                store.recreate(saved, holding: tabs, remembering: tabs[rememberedIndex])
                if store.allowsUndoSwitch() { store.show(saved.id, comingForward: true) }
            } else {
                _ = Self.reopen(saved, holding: tabs, remembering: tabs[rememberedIndex])
            }

            undoManager.registerUndo(withTarget: ghostty, expiresAfter: expiration) { _ in
                Self.live(saved)?.closeWorkspaceImmediately(saved.id)
            }
        }
    }
}
