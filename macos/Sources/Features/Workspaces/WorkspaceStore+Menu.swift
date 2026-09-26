import AppKit

extension WorkspaceStore {
    /// The Workspace menu's list: one row per Workspace in bar order, ✓ on the shown one.
    /// Row N runs `goto_workspace:N`, and rows 1–9 show the shortcut bound to it, read the
    /// way `TerminalController.relabelTabs` reads `goto_tab:N`.
    func menuItems(config: Ghostty.Config) -> [NSMenuItem] {
        rows(action: #selector(BaseTerminalController.selectWorkspace(_:)), keybind: "goto_workspace", config: config)
    }

    /// The Workspace menu's Move Tab to Workspace ▸ for the focused Tab, which is in the shown
    /// Workspace: the list, with the shown row disabled, then New Workspace. Row N runs
    /// `move_tab_to_workspace:N` and shows the shortcut bound to it.
    func moveTabMenuItems(config: Ghostty.Config) -> [NSMenuItem] {
        let rows = rows(action: #selector(BaseTerminalController.moveTabToWorkspace(_:)), keybind: "move_tab_to_workspace", config: config)
        for row in rows where row.state == .on { row.action = nil }
        return rows + [.separator(), Self.moveTabToNewWorkspaceItem()]
    }

    /// Move Tab to Workspace ▸'s New Workspace, which runs `move_tab_to_new_workspace`. It's
    /// the whole submenu in a Window that can't hold Tabs, where it shows the alert.
    static func moveTabToNewWorkspaceItem() -> NSMenuItem {
        NSMenuItem(
            title: "New Workspace",
            action: #selector(BaseTerminalController.moveTabToNewWorkspace(_:)),
            keyEquivalent: "")
    }

    private func rows(action: Selector, keybind: String, config: Ghostty.Config) -> [NSMenuItem] {
        workspaces.enumerated().map { index, workspace in
            let number = index + 1
            let item = NSMenuItem(title: workspace.name, action: action, keyEquivalent: "")
            item.tag = number
            item.state = workspace.id == shownID ? .on : .off
            if number <= 9, let shortcut = config.keyboardShortcut(for: "\(keybind):\(number)") {
                item.keyEquivalent = shortcut.key.character.description
                item.keyEquivalentModifierMask = .init(swiftUIFlags: shortcut.modifiers)
            }
            return item
        }
    }
}
