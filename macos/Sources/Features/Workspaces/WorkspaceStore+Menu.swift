import AppKit

extension WorkspaceStore {
    /// The Workspace menu's list (SPEC §7.3): one row per Workspace in bar order, ✓ on the
    /// shown one. Row N runs `goto_workspace:N`, and rows 1–9 show the shortcut bound to it,
    /// read the way `TerminalController.relabelTabs` reads `goto_tab:N`.
    func menuItems(config: Ghostty.Config) -> [NSMenuItem] {
        workspaces.enumerated().map { index, workspace in
            let number = index + 1
            let item = NSMenuItem(
                title: workspace.name,
                action: #selector(BaseTerminalController.selectWorkspace(_:)),
                keyEquivalent: "")
            item.tag = number
            item.state = workspace.id == shownID ? .on : .off
            if number <= 9, let shortcut = config.keyboardShortcut(for: "goto_workspace:\(number)") {
                item.keyEquivalent = shortcut.key.character.description
                item.keyEquivalentModifierMask = .init(swiftUIFlags: shortcut.modifiers)
            }
            return item
        }
    }
}
