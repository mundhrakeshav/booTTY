import AppKit

extension WorkspaceStore {
    // MARK: Gates

    /// Whether a requested command that would change the shown Workspace may run now. `tab`
    /// is the Tab of the command's target Split. Otherwise the command reports false:
    /// - aimed at a hidden Split, with nothing shown;
    /// - while the shown Tab has a sheet, bringing the Window and its sheet forward;
    /// - in non-native fullscreen, showing `alert` on `tab` when that's the windowed group's
    ///   selected Tab, else on the fullscreen Tab.
    ///
    /// The neighbor shown because the shown Workspace ended, and undo, aren't requests and
    /// don't come through here.
    func allowsRequest(from tab: TerminalController, orShow alert: WorkspaceAlert) -> Bool {
        reconcile()
        guard !isHidden(tab), !refusesUnderSheet() else { return false }
        return !refusesInFullscreen(tab, showing: alert)
    }

    /// Whether the shown Tab has a sheet up, which blocks switching.
    var shownTabHasSheet: Bool { shownTab?.window?.attachedSheet != nil }

    /// True while the shown Tab has a sheet, after bringing the Window and its
    /// sheet forward.
    func refusesUnderSheet() -> Bool {
        guard let window = shownTab?.window, window.attachedSheet != nil else { return false }
        Self.bringForward(window)
        return true
    }

    /// True in non-native fullscreen, after showing `alert` on `tab` when that's
    /// the windowed group's selected Tab, else on the fullscreen Tab. A nil `alert` refuses
    /// silently.
    func refusesInFullscreen(_ tab: TerminalController, showing alert: WorkspaceAlert?) -> Bool {
        guard let fullscreen = tabs(of: shownID).first(where: { $0.isInNonNativeFullscreen }) else { return false }
        let isWindowedSelection = tab.window != nil && tab.window === tabGroup?.selectedWindow
        alert?.show(on: isWindowedSelection ? tab.window : fullscreen.window)
        return true
    }

    /// Whether shown `tab` may leave for a new Window now, as AppKit's Move Tab to New Window
    /// would take it. Not while its sheet is up, and never in non-native
    /// fullscreen, which shows "Cannot Move Tab".
    func allowsMoveToNewWindow(_ tab: TerminalController) -> Bool {
        reconcile()
        return tab.window?.attachedSheet == nil && !refusesInFullscreen(tab, showing: .cannotMoveTab)
    }

    /// Leaves non-native fullscreen, for an undo or a close that changes the shown Workspace's
    /// Tabs: the fullscreen Tab exits and rejoins the windowed group behind
    /// it, or, with that group empty, forms the Window's group itself, and the store binds to
    /// it. Does nothing outside non-native fullscreen.
    func leaveNonNativeFullscreen() {
        let fullscreen = tabs(of: shownID).filter(\.isInNonNativeFullscreen)
        guard !fullscreen.isEmpty else { return }
        for tab in fullscreen { tab.fullscreenStyle?.exit() }
        reconcile()
    }

    /// A Jump into `tab`: shows its hidden Workspace with `tab` selected and the
    /// Window coming forward, so the caller's usual focus can run. A shown Tab needs nothing.
    /// Otherwise the jump reports false with nothing switched and never brings `tab` front:
    /// - while the shown Tab has a sheet, the Window and its sheet come forward;
    /// - in non-native fullscreen, the fullscreen Tab comes forward with "Cannot Switch
    ///   Workspace".
    func reveal(_ tab: TerminalController) -> Bool {
        reconcile()
        guard let target = hiddenIndex(of: tab) else { return true }

        guard !refusesUnderSheet() else { return false }

        if let fullscreen = tabs(of: shownID).first(where: { $0.isInNonNativeFullscreen })?.window {
            Self.bringForward(fullscreen)
            WorkspaceAlert.cannotSwitch.show(on: fullscreen)
            return false
        }

        workspaces[target].rememberedTab = tab
        return show(workspaces[target].id, comingForward: true)
    }

    static func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }
}
