import AppKit

extension WorkspaceStore {
    // MARK: Themes

    /// Any Workspace's theme, hidden ones included, by name; nil gives its Splits the config's
    /// colors back. Every Split of the Workspace takes it now. No undo, like its color.
    func setTheme(_ theme: String?, of id: Workspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].theme != theme
        else { return }
        workspaces[index].theme = theme
        applyThemes()
        invalidateRestorableState()
    }

    /// Gives every Split its Workspace's theme. Tabs change Workspace in many ways (moves,
    /// merges, Organize, joining or leaving the Window), so this runs after each, and only
    /// the Splits whose theme changes reload.
    func applyThemes() {
        for workspace in workspaces {
            for tab in tabs(of: workspace.id) {
                for surface in tab.surfaceTree { tab.ghostty.setTheme(workspace.theme, for: surface) }
            }
        }
    }

    /// Runs `applyThemes()` on a later turn, once the change that called this is done:
    /// halfway through a switch, the group doesn't hold the shown Workspace's Tabs yet.
    func setNeedsThemeSync() {
        guard !themeSyncScheduled else { return }
        themeSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            themeSyncScheduled = false
            applyThemes()
        }
    }
}
