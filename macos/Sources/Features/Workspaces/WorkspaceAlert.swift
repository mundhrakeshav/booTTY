import AppKit

/// The alerts Workspace commands show when they can't run. Each is a warning
/// with one OK button, and the command that shows one reports false.
enum WorkspaceAlert {
    // Non-native fullscreen.
    case cannotSwitch
    case cannotCreate
    case cannotClose
    case cannotOrganize
    case cannotMoveTab
    case cannotMoveWorkspace
    case cannotMergeWindows

    // Windows that can't hold Tabs.
    case unavailableInQuickTerminal
    case unavailableUndecorated
    case unavailableHiddenTitlebar

    var title: String {
        switch self {
        case .cannotSwitch: "Cannot Switch Workspace"
        case .cannotCreate: "Cannot Create New Workspace"
        case .cannotClose: "Cannot Close Workspace"
        case .cannotOrganize: "Cannot Organize Workspaces"
        case .cannotMoveTab: "Cannot Move Tab"
        case .cannotMoveWorkspace: "Cannot Move Workspace"
        case .cannotMergeWindows: "Cannot Merge Windows"
        case .unavailableInQuickTerminal, .unavailableUndecorated, .unavailableHiddenTitlebar:
            "Workspaces Unavailable"
        }
    }

    var text: String {
        let fullscreen = "unsupported while in non-native fullscreen. Exit fullscreen and try again."
        return switch self {
        case .cannotSwitch: "Switching Workspaces is \(fullscreen)"
        case .cannotCreate: "New Workspaces are \(fullscreen)"
        case .cannotClose: "Closing the shown Workspace is \(fullscreen)"
        case .cannotOrganize: "Organizing Workspaces is \(fullscreen)"
        case .cannotMoveTab: "Moving tabs between Workspaces is \(fullscreen)"
        case .cannotMoveWorkspace: "Moving Workspaces to a new window is \(fullscreen)"
        case .cannotMergeWindows: "Merging windows is \(fullscreen)"
        case .unavailableInQuickTerminal: "Workspaces aren't supported in the Quick Terminal."
        case .unavailableUndecorated: "Enable window decorations to use Workspaces."
        case .unavailableHiddenTitlebar: "Windows with a hidden titlebar can't have tabs, so they can't have Workspaces."
        }
    }

    /// App-modal, like "Tabs are disabled", instead of a sheet.
    var isAppModal: Bool { self == .unavailableUndecorated }

    /// Shows the alert as a sheet on `window`, or app-modal.
    @MainActor
    func show(on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        if !isAppModal, let window {
            alert.beginSheetModal(for: window)
        } else {
            _ = alert.runModal()
        }
    }
}

@MainActor
extension BaseTerminalController {
    /// The "Workspaces Unavailable" alert for a Window that can't hold Tabs, or nil when it
    /// holds Workspaces. Read from the Window, never the live config: the Quick
    /// Terminal, a hidden titlebar, or a Window created without decorations. With both of
    /// the latter the window counts as undecorated, since it loaded the plain nib.
    var workspacesUnavailableAlert: WorkspaceAlert? {
        switch self {
        case is QuickTerminalController: .unavailableInQuickTerminal
        case let tab as TerminalController where !tab.windowStyle.isDecorated: .unavailableUndecorated
        case let tab as TerminalController where tab.window is HiddenTitlebarTerminalWindow: .unavailableHiddenTitlebar
        default: nil
        }
    }

    /// Whether this Window holds Workspaces: it can hold Tabs.
    var holdsWorkspaces: Bool { workspacesUnavailableAlert == nil }

    /// The one check where Workspace apprt actions arrive, before anything touches a tab
    /// group: the Tab whose Window's store the command acts on, or nil when the command
    /// reports false. In a Window that can't hold Tabs, that's after showing "Workspaces
    /// Unavailable".
    func tabForWorkspaceCommand() -> TerminalController? {
        if let alert = workspacesUnavailableAlert {
            alert.show(on: window)
            return nil
        }

        return self as? TerminalController
    }
}
