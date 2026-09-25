import AppKit
import Combine

/// The Window's store (SPEC §1.1, §2.2): the Window id, its Workspaces in bar order, and
/// which one is shown. Every Tab of the Window, shown or hidden, points at it through
/// `TerminalController.workspaceStore`, and every Tab's bar reads from it.
///
/// The shown Workspace is exactly the Window's live native tab group, so AppKit only ever
/// sees the shown Workspace's Tabs and the store doesn't list them. A hidden Workspace's
/// Tabs are detached, ordered out, and held here. Membership follows the tab group
/// (`reconcile()`), and every Workspace change goes through `show(_:)`, the one switch path.
@MainActor
final class WorkspaceStore: ObservableObject {
    struct Workspace: Identifiable, Equatable {
        /// Stable for the Workspace's whole life.
        let id: UUID
        var name: String
        /// The name a blank rename restores.
        var originalName: String
        var color: TerminalTabColor = .none
        /// A hidden Workspace's Tabs, in order. Empty while it's shown: the shown
        /// Workspace's Tabs are the Window's live tab group.
        var hiddenTabs: [TerminalController]
        /// The Tab a hidden Workspace selects when it's shown again, one of `hiddenTabs`.
        /// Nil while it's shown.
        var rememberedTab: TerminalController?

        init(id: UUID = UUID(), name: String, hiddenTabs: [TerminalController] = []) {
            self.id = id
            self.name = name
            self.originalName = name
            self.hiddenTabs = hiddenTabs
            self.rememberedTab = hiddenTabs.first
        }
    }

    /// Which Workspace `goto_workspace`, `previous_workspace`, and `next_workspace` show.
    enum Target: Equatable {
        /// 1-based. Past the end means the last Workspace.
        case number(Int)
        case previous
        case next
    }

    /// The Window id. It's minted with the store, so a new store means a new Window.
    let id: UUID

    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var shownID: Workspace.ID

    var shownIndex: Int { workspaces.firstIndex { $0.id == shownID } ?? 0 }

    /// The Window's live native tab group, holding exactly the shown Workspace's Tabs.
    private(set) weak var tabGroup: NSWindowTabGroup?
    private var tabGroupObservation: NSKeyValueObservation?
    private var hasBound = false

    /// The shown Tabs as last seen, to tell which ones left the group. It keeps a Tab in
    /// non-native fullscreen, which has left the group but is still shown (SPEC §3).
    private var knownShownTabs: [Weak<TerminalController>] = []

    /// Set while the store changes the group itself, so the Window's own callbacks (the
    /// incoming Tab becoming key) don't reconcile a half-done switch.
    private var isChanging = false

    init(id: UUID = UUID(), workspaces: [Workspace], shownID: Workspace.ID) {
        precondition(workspaces.contains { $0.id == shownID })
        self.id = id
        self.workspaces = workspaces
        self.shownID = shownID
    }

    /// The store of a new Window whose first Tab is `tab`: one Workspace, "Workspace 1".
    convenience init(tab: TerminalController) {
        let first = Workspace(name: Self.newName(in: []))
        self.init(workspaces: [first], shownID: first.id)
        knownShownTabs = [Weak(tab)]
    }

    // MARK: Reading

    /// The Tabs of a Workspace, in order. For the shown Workspace that's the live group's,
    /// plus, at the end, a Tab in non-native fullscreen.
    func tabs(of id: Workspace.ID) -> [TerminalController] {
        guard id == shownID else {
            return workspaces.first { $0.id == id }?.hiddenTabs ?? []
        }

        return shownTabs
    }

    /// The hidden Workspace holding `tab`, or nil if `tab` is shown or not this Window's.
    func hiddenWorkspace(holding tab: TerminalController) -> Workspace? {
        workspaces.first { $0.hiddenTabs.contains { $0 === tab } }
    }

    /// True if `tab` is in one of this Window's hidden Workspaces.
    func isHidden(_ tab: TerminalController) -> Bool {
        hiddenWorkspace(holding: tab) != nil
    }

    /// A Window is in non-native fullscreen while any of its Tabs is (SPEC §3).
    var isInNonNativeFullscreen: Bool {
        shownTabs.contains { $0.isInNonNativeFullscreen }
    }

    /// The Window's shown Tab, where sheets about its hidden Tabs go (SPEC §2.5): the Tab in
    /// non-native fullscreen, else the live group's selected Tab.
    var shownTab: TerminalController? {
        tabs(of: shownID).first { $0.isInNonNativeFullscreen }
            ?? tabGroup?.selectedWindow?.windowController as? TerminalController
    }

    /// The Workspace shown when the shown one ends: the one to its right, else the one to its
    /// left (SPEC §1.4). Nil when it's the Window's only Workspace.
    var neighborID: Workspace.ID? {
        Self.neighbor(of: shownIndex, in: workspaces)?.id
    }

    /// The Tab a hidden Workspace remembers once `tab` leaves `tabs`: `remembered` if that's
    /// another Tab, else the Tab to the right of `tab`, else the one to its left (SPEC §13.5).
    static func remembered<Tab: AnyObject>(_ remembered: Tab?, after tab: Tab, leaves tabs: [Tab]) -> Tab? {
        guard remembered === tab, let index = tabs.firstIndex(where: { $0 === tab }) else { return remembered }
        return neighbor(of: index, in: tabs)
    }

    /// The element to the right of `index`, else the one to its left.
    private static func neighbor<Element>(of index: Int, in elements: [Element]) -> Element? {
        if elements.indices.contains(index + 1) { return elements[index + 1] }
        return elements.indices.contains(index - 1) ? elements[index - 1] : nil
    }

    private var shownTabs: [TerminalController] {
        let grouped = tabGroup.map(Self.tabs(in:)) ?? []
        return grouped + knownShownTabs.compactMap(\.value).filter { tab in
            tab.isInNonNativeFullscreen && !grouped.contains { $0 === tab }
        }
    }

    /// "Workspace N", with the lowest N ≥ 1 that no Workspace shows as its name (SPEC §1.2).
    static func newName(in workspaces: [Workspace]) -> String {
        let names = Set(workspaces.map(\.name))
        var n = 1
        while names.contains("Workspace \(n)") { n += 1 }
        return "Workspace \(n)"
    }

    /// The index `target` shows, or nil when the command reports false: the Window has one
    /// Workspace, or the number is below 1 (SPEC §7.1). Previous and next wrap around.
    func index(of target: Target) -> Int? {
        let count = workspaces.count
        guard count > 1 else { return nil }
        switch target {
        case .number(let n): return n >= 1 ? min(n, count) - 1 : nil
        case .previous: return (shownIndex + count - 1) % count
        case .next: return (shownIndex + 1) % count
        }
    }

    // MARK: Commands

    /// `goto_workspace`, `previous_workspace`, and `next_workspace`. Reports true even when
    /// the target is already shown, as the tab twins do.
    @discardableResult
    func show(_ target: Target) -> Bool {
        guard let index = index(of: target) else { return false }
        return show(workspaces[index].id)
    }

    /// New Workspace (SPEC §9.5): "Workspace N" at the end, holding one new Tab made from
    /// `baseConfig`, and shown. `parent` is the Tab the request came from.
    @discardableResult
    func newWorkspace(from parent: TerminalController, withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?) -> Bool {
        reconcile()
        guard tabGroup != nil, !isInNonNativeFullscreen else { return false }

        let tab = TerminalController(parent.ghostty, withBaseConfig: baseConfig)
        tab.isBackgroundOpaque = parent.isBackgroundOpaque
        tab.workspaceStore = self

        // Loads the window without showing it. It appears when the switch selects it and
        // takes the group's frame then (SPEC §2.6).
        guard tab.window != nil else { return false }

        let id = addWorkspace(holding: [tab])
        if show(id) { return true }

        workspaces.removeAll { $0.id == id }
        tab.surfaceTree = .init() // closes the never-shown Tab and ends its shell
        return false
    }

    /// Adds a hidden Workspace named "Workspace N", holding `tabs`, at the end of the bar,
    /// so existing Workspaces keep their places (SPEC §1.3).
    func addWorkspace(holding tabs: [TerminalController]) -> Workspace.ID {
        let workspace = Workspace(name: Self.newName(in: workspaces), hiddenTabs: tabs)
        workspaces.append(workspace)
        return workspace.id
    }

    /// Drops `tab`, which closed or left, from its hidden Workspace; does nothing if it isn't
    /// in one. The remembered Tab passes on per `remembered(_:after:leaves:)`, and a Workspace
    /// left without Tabs ends quietly while the Window keeps showing what it shows (SPEC §1.4,
    /// §13.5).
    func removeHiddenTab(_ tab: TerminalController) {
        guard let index = workspaces.firstIndex(where: { $0.hiddenTabs.contains { $0 === tab } }) else { return }
        var workspace = workspaces[index]
        workspace.rememberedTab = Self.remembered(workspace.rememberedTab, after: tab, leaves: workspace.hiddenTabs)
        workspace.hiddenTabs.removeAll { $0 === tab }
        if workspace.hiddenTabs.isEmpty {
            workspaces.remove(at: index)
        } else {
            workspaces[index] = workspace
        }
        invalidateRestorableState()
    }

    // MARK: Switching

    /// The one switch path (SPEC §2.3): shows Workspace `id`. Returns false, with the old
    /// Workspace still shown, when AppKit throws while adding or selecting the incoming Tabs,
    /// or when the Window can't switch now. Showing the shown Workspace changes nothing.
    @discardableResult
    func show(_ id: Workspace.ID) -> Bool {
        reconcile()
        guard id != shownID else { return true }

        // Non-native fullscreen takes the fullscreen Tab out of the group, so there's no
        // group to swap. Ticket 03's refusal alerts come before this.
        guard let target = workspaces.firstIndex(where: { $0.id == id }),
              let group = tabGroup,
              let oldSelected = group.selectedWindow,
              !isInNonNativeFullscreen,
              let incoming = (workspaces[target].rememberedTab ?? workspaces[target].hiddenTabs.first)?.window
        else { return false }

        isChanging = true
        let orderedOut = Self.swap(
            in: group,
            adding: workspaces[target].hiddenTabs.compactMap(\.window),
            selecting: incoming,
            makeKey: oldSelected.isKeyWindow || oldSelected.isMainWindow)
        isChanging = false
        guard let orderedOut else { return false }

        // The outgoing Workspace keeps the Tabs that left the group and remembers the one
        // that was selected.
        let outgoing = shownIndex
        let outgoingTabs = orderedOut.compactMap { $0.windowController as? TerminalController }
        workspaces[outgoing].hiddenTabs = outgoingTabs
        workspaces[outgoing].rememberedTab = outgoingTabs.first { $0.window === oldSelected } ?? outgoingTabs.first
        workspaces[target].hiddenTabs = []
        workspaces[target].rememberedTab = nil
        shownID = id

        // A Tab that failed to order out stayed in the group, so it joined the shown
        // Workspace. If none ordered out, the outgoing Workspace has no Tabs and ends.
        if outgoingTabs.isEmpty { workspaces.remove(at: outgoing) }

        reconcile()
        invalidateRestorableState()

        let tab = incoming.windowController as? TerminalController
        if let surface = tab?.focusedSurface { Ghostty.moveFocus(to: surface) }
        tab?.relabelTabs()
        if incoming.isKeyWindow, let name = workspaces.first(where: { $0.id == id })?.name {
            NSAccessibility.post(
                element: incoming,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: name,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }

        return true
    }

    /// The AppKit steps of a switch, each run through `perform`.
    enum SwapStep { case add, select, orderOut }

    /// Adds `incoming`, still ordered out, to `group`, selects `target`, then orders the
    /// group's old windows out, with animation off. Adding and selecting are all or nothing:
    /// if either fails, the added windows are ordered out again, the old selection comes
    /// back, and this returns nil. Otherwise it returns the old windows that ordered out; one
    /// that failed stays in the group.
    ///
    /// `makeKey` selects by making `target` key, for a key or main Window. Otherwise it
    /// selects within the group, so a background Window doesn't take key from the Window the
    /// user is in and a minimized one stays minimized.
    static func swap(
        in group: NSWindowTabGroup,
        adding incoming: [NSWindow],
        selecting target: NSWindow,
        makeKey: Bool,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> [NSWindow]? {
        let old = group.windows
        let oldSelected = group.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }

        func select(_ window: NSWindow) -> Bool {
            perform(.select) {
                if makeKey {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    group.selectedWindow = window
                }
            }
        }

        let added = incoming.allSatisfy { window in perform(.add) { group.addWindow(window) } }
        guard added, select(target) else {
            for window in incoming where group.windows.contains(window) {
                _ = perform(.orderOut) { window.orderOut(nil) }
            }
            if let oldSelected, group.selectedWindow !== oldSelected {
                _ = select(oldSelected)
            }
            return nil
        }

        // Everything old is unselected now, so ordering it out reveals nothing.
        return old.filter { window in perform(.orderOut) { window.orderOut(nil) } }
    }

    /// Runs one AppKit step under an Objective-C exception catcher and logs what threw.
    nonisolated static func performSafely(_ step: SwapStep, _ block: () -> Void) -> Bool {
        var error: NSError?
        guard GhosttyPerformSafely(block, &error) else {
            Ghostty.logger.error(
                "workspace switch failed at \(String(describing: step), privacy: .public): \(error?.localizedDescription ?? "", privacy: .public)")
            return false
        }

        return true
    }

    // MARK: Membership

    /// Brings membership in line with the tab group (SPEC §2.2). Every Tab in the group
    /// belongs to this store, so one that Cmd+T, AppKit, or the bar added adopts it and joins
    /// the shown Workspace. A shown Tab that left for another Window's group adopts that
    /// Window's store. One that left alone (torn off, Move Tab to New Window) is a new Window
    /// and gets a new store. Entering or leaving non-native fullscreen is neither: the
    /// fullscreen Tab stays shown and keeps its store, whichever group it lands in.
    ///
    /// Commands call this before touching the group, and so do KVO on the group and the
    /// Window becoming key.
    func reconcile() {
        guard !isChanging else { return }
        isChanging = true
        defer { isChanging = false }

        let group = currentGroup()
        if let group, group !== tabGroup { bind(group) }

        let grouped = group.map(Self.tabs(in:)) ?? []
        var changed = false
        for tab in grouped where tab.workspaceStore !== self {
            tab.workspaceStore = self
            changed = true
        }

        var shown = grouped
        for tab in knownShownTabs.compactMap(\.value) where !grouped.contains(where: { $0 === tab }) {
            // Hidden by a switch, adopted by another Window already, or closed.
            guard tab.workspaceStore === self, !isHidden(tab), let window = tab.window else { continue }
            if tab.isInNonNativeFullscreen {
                shown.append(tab)
                continue
            }
            guard window.isVisible else { continue }

            changed = true
            let others = (window.tabGroup.map(Self.tabs(in:)) ?? []).filter { $0 !== tab }
            let owner: WorkspaceStore
            if let other = others.first {
                owner = others.first { $0.workspaceStore.tabGroup === window.tabGroup }?.workspaceStore
                    ?? other.workspaceStore
            } else {
                owner = WorkspaceStore(tab: tab)
            }
            tab.workspaceStore = owner
            owner.reconcile()
            owner.invalidateRestorableState()
        }

        knownShownTabs = shown.map { Weak($0) }
        if changed { invalidateRestorableState() }
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

    private func bind(_ group: NSWindowTabGroup) {
        tabGroup = group
        hasBound = true

        // KVO fires in the middle of AppKit's tab changes, so reconcile on a later turn that
        // sees consistent state, as VerticalTabBarModel does.
        tabGroupObservation = group.observe(\.windows) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reconcile() }
        }
    }

    private static func tabs(in group: NSWindowTabGroup) -> [TerminalController] {
        group.windows.compactMap { $0.windowController as? TerminalController }
    }

    /// Every Workspace change invalidates the shown Tabs' and the app's restorable state
    /// (SPEC §17.4).
    private func invalidateRestorableState() {
        for window in tabGroup?.windows ?? [] {
            window.invalidateRestorableState()
        }
        NSApp.invalidateRestorableState()
    }
}
