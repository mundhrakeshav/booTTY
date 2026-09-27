import AppKit

/// The app-level half of the Workspaces' restorable state, saved beside the
/// Quick Terminal's under its own key. AppKit restores each Window's shown Tabs, and each
/// encodes its Window id. This entry holds the rest: every Window's Workspaces, with each
/// hidden Workspace's Tabs archived.
struct WorkspacesRestorableState: TerminalRestorable {
    static var selfKey: String { "workspaces" }
    static var versionKey: String { "workspacesVersion" }
    static var version: Int { 1 }

    struct Window: Codable, Equatable {
        let id: UUID
        let shownIndex: Int
        let workspaces: [Workspace]
    }

    struct Workspace: Codable, Equatable {
        let id: UUID
        let name: String
        let originalName: String
        let color: WorkspaceColor
        /// Nil in saves from before Workspace themes.
        let theme: String?
        /// The index in `tabs` of the remembered Tab.
        let rememberedTabIndex: Int?
        /// Each Tab's archived `TerminalRestorableState`. Empty for the shown Workspace,
        /// whose Tabs AppKit restores.
        let tabs: [Data]
    }

    let windows: [Window]

    init(windows: [Window]) {
        self.windows = windows
    }

    init(copy other: WorkspacesRestorableState) {
        self = other
    }
}

extension WorkspacesRestorableState {
    /// Every Window's Workspaces as they are now.
    @MainActor
    static var current: WorkspacesRestorableState {
        var seen = Set<UUID>()
        let stores = TerminalController.all.map(\.workspaceStore).filter { seen.insert($0.id).inserted }
        return .init(windows: stores.map(Window.init))
    }
}

extension WorkspacesRestorableState.Window {
    @MainActor
    init(_ store: WorkspaceStore) {
        id = store.id
        shownIndex = store.shownIndex
        workspaces = store.workspaces.map { workspace in
            // Tabs running a custom command aren't restorable, as windows aren't.
            let tabs = workspace.hiddenTabs.filter { $0.window?.isRestorable == true }
            return .init(
                id: workspace.id,
                name: workspace.name,
                originalName: workspace.originalName,
                color: workspace.color,
                theme: workspace.theme,
                rememberedTabIndex: tabs.firstIndex { $0 === workspace.rememberedTab },
                tabs: tabs.map { TerminalRestorableState(from: $0).archived() })
        }
    }
}

/// Matches the two halves of each restored Window by Window id, in whichever order they
/// arrive: the app-level entry, and the shown Tabs AppKit restores. Hidden Tabs
/// stay archived until their Window claims them, because decoding one starts its shells.
@MainActor
enum WorkspaceRestoration {
    /// App-level entries no restored Tab has claimed yet, by Window id.
    private static var unclaimed: [UUID: WorkspacesRestorableState.Window] = [:]

    /// The stores of the Windows restored so far, by Window id.
    private static var stores: [UUID: WorkspaceStore] = [:]

    /// Takes the app-level entry. A Window whose Tabs came first gets its Workspaces now.
    static func didDecode(_ state: WorkspacesRestorableState, ghostty: Ghostty.App) {
        for window in state.windows {
            if let store = stores[window.id] {
                store.restore(window, ghostty: ghostty)
            } else {
                unclaimed[window.id] = window
            }
        }
    }

    /// The store of the Window whose id a restored shown Tab encodes. The Window's first Tab
    /// makes it, and brings back its Workspaces if the app-level entry came first.
    static func store(for windowID: UUID, restoring tab: TerminalController) -> WorkspaceStore {
        if let store = stores[windowID] { return store }

        let store = WorkspaceStore(id: windowID, tab: tab)
        stores[windowID] = store
        if let window = unclaimed.removeValue(forKey: windowID) {
            store.restore(window, ghostty: tab.ghostty)
        }
        return store
    }

    /// AppKit has restored every window. What no Window claimed is dropped still archived,
    /// so no shell ever runs unseen.
    static func didFinishRestoringWindows() {
        unclaimed.removeAll()
        stores.removeAll()
    }
}
