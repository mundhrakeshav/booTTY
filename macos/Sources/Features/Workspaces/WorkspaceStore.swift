import AppKit
import Combine
import System

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

    @Published var workspaces: [Workspace] {
        // One that ends or leaves the Window drops out of recency (SPEC §8.3).
        didSet { recentIDs.removeAll { id in !workspaces.contains { $0.id == id } } }
    }
    @Published var shownID: Workspace.ID

    /// Recency, newest first, the shown Workspace included once it has been shown by a
    /// switch (SPEC §8.3). Per Window and in memory only. See `markShown(_:)`.
    private var recentIDs: [Workspace.ID] = []

    var shownIndex: Int { workspaces.firstIndex { $0.id == shownID } ?? 0 }

    /// The Window's live native tab group, holding exactly the shown Workspace's Tabs.
    weak var tabGroup: NSWindowTabGroup?
    var tabGroupObservation: NSKeyValueObservation?
    var hasBound = false

    /// The shown Tabs as last seen, to tell which ones left the group. It keeps a Tab in
    /// non-native fullscreen, which has left the group but is still shown (SPEC §3).
    var knownShownTabs: [Weak<TerminalController>] = []

    /// The shown Tabs' frame as last seen. A re-formed group takes it, since by the time the
    /// store notices its group emptied, the Tab that left has taken another Window's frame.
    var shownFrame: NSRect?

    /// Set while the store changes the group itself, so the Window's own callbacks (the
    /// incoming Tab becoming key) don't reconcile a half-done switch.
    var isChanging = false

    /// The scroll gesture over this Window's bar, told apart by its first movement. The
    /// Window has one gesture at a time, and every Tab's monitor reads it.
    var swipeGesture = SwipeGesture.none

    /// Set when a claimed gesture ends, until its momentum ends or a new gesture begins, so
    /// whichever of the Window's Tabs gets that momentum drops it (SPEC §6.2).
    var dropsSwipeMomentum = false

    /// Bumped by each claimed swipe and each cancel. A swipe from before stops tracking.
    var swipeGeneration = 0

    /// Undo and Redo Organize's target, so both come off the undo stack together.
    let organizeUndoTarget = NSObject()

    /// The Window's Tabs when Undo or Redo Organize was last registered. Once they differ,
    /// both entries come off the stack (SPEC §10.6).
    var organizeUndoTabs: Set<ObjectIdentifier>?

    /// Set when the swipe switched at the lift: what its amount gains to count from the
    /// Workspace shown now, and the Workspace it came from, which the settle keeps beside it.
    var swipeSwitch: (rebase: CGFloat, from: Workspace.ID)?

    /// Where the swipe stands, so whichever of the Window's Tabs is shown draws it, the
    /// incoming Tab's bar included during the settle (SPEC §6.3).
    @Published var swipeProgress = SwipeProgress()

    /// Bumped by each cancel that moved the swipe back to rest, so the bar morphs the
    /// capsule back to the shown mark (SPEC §6.5).
    @Published var swipeCancels = 0

    init(id: UUID = UUID(), workspaces: [Workspace], shownID: Workspace.ID) {
        precondition(workspaces.contains { $0.id == shownID })
        self.id = id
        self.workspaces = workspaces
        self.shownID = shownID
    }

    /// The store of a new Window whose first Tab is `tab`: one Workspace, `name`, by default
    /// "Workspace 1". A restored Window keeps its saved `id`.
    convenience init(id: UUID = UUID(), tab: TerminalController, name: String? = nil) {
        let first = Workspace(name: name ?? Self.newName(in: []))
        self.init(id: id, workspaces: [first], shownID: first.id)
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
        hiddenIndex(of: tab).map { workspaces[$0] }
    }

    /// True if `tab` is in one of this Window's hidden Workspaces.
    func isHidden(_ tab: TerminalController) -> Bool {
        hiddenIndex(of: tab) != nil
    }

    /// The Workspace holding `tab`, one of this Window's Tabs: a hidden one, else the shown one.
    func workspace(holding tab: TerminalController) -> Workspace {
        workspaces[hiddenIndex(of: tab) ?? shownIndex]
    }

    func hiddenIndex(of tab: TerminalController) -> Int? {
        workspaces.firstIndex { $0.hiddenTabs.contains { $0 === tab } }
    }

    /// A Workspace's agent status and its date (SPEC §15.1), derived from its Tabs on every
    /// read and never stored. See `agentStatus(of tabs:)`.
    func agentStatus(of id: Workspace.ID) -> (status: Ghostty.AgentStatus?, since: Date) {
        Self.agentStatus(of: tabs(of: id).map { tab in
            let window = tab.window as? TerminalWindow
            return (window?.agentStatus, window?.agentStatusDate ?? .distantPast)
        })
    }

    /// The most urgent Tab's status: waiting, then done, then none. Its date is the newest
    /// among the Tabs holding that status, so a second finish pings again and a finish
    /// behind a waiting agent doesn't.
    static func agentStatus(
        of tabs: [(status: Ghostty.AgentStatus?, since: Date)]
    ) -> (status: Ghostty.AgentStatus?, since: Date) {
        guard let status = tabs.compactMap(\.status).max() else { return (nil, .distantPast) }
        let since = tabs.filter { $0.status == status }.map(\.since).max() ?? .distantPast
        return (status, since)
    }

    /// A Window is in non-native fullscreen while any of its Tabs is (SPEC §3).
    var isInNonNativeFullscreen: Bool {
        shownTabs.contains { $0.isInNonNativeFullscreen }
    }

    /// The Tab the Window shows: the Tab in non-native fullscreen, else the live group's
    /// selected Tab. Sheets about the Window's hidden Tabs go on it.
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
    static func neighbor<Element>(of index: Int, in elements: [Element]) -> Element? {
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

    /// A Workspace made from a folder is named after its basename, `~` for home, with no
    /// suffix (SPEC §1.2).
    nonisolated static func name(ofFolder path: String) -> String {
        let folder = FilePath(path).lexicallyNormalized()
        if folder == FilePath(NSHomeDirectory()).lexicallyNormalized() { return "~" }
        return folder.lastComponent?.string ?? folder.string
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

    /// The Window's Workspaces most recently shown first, as the switcher lists them.
    var recentWorkspaces: [Workspace] {
        Self.recencyOrder(workspaces, shownID: shownID, recent: recentIDs)
    }

    /// The shown Workspace first, then the ones in `recent` (newest first), then those not
    /// shown since they arrived in the Window, in bar order (SPEC §8.3). Ids of Workspaces
    /// that are gone are skipped.
    static func recencyOrder(_ workspaces: [Workspace], shownID: Workspace.ID, recent: [Workspace.ID]) -> [Workspace] {
        let ranks = Dictionary(([shownID] + recent).enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return workspaces.enumerated()
            .sorted { lhs, rhs in
                (ranks[lhs.element.id] ?? Int.max, lhs.offset) < (ranks[rhs.element.id] ?? Int.max, rhs.offset)
            }
            .map(\.element)
    }

    /// Makes Workspace `id` newest in recency, with the Workspace shown until now right
    /// after it. Every switch calls this right before it sets `shownID = id`, so showing a
    /// Workspace by any path counts (SPEC §2.3, §8.3).
    func markShown(_ id: Workspace.ID) {
        recentIDs = Self.recency(recentIDs, showing: id, from: shownID)
    }

    /// `recent` after Workspace `id` is shown in place of `shown`.
    static func recency(_ recent: [Workspace.ID], showing id: Workspace.ID, from shown: Workspace.ID) -> [Workspace.ID] {
        let front = id == shown ? [id] : [id, shown]
        return front + recent.filter { !front.contains($0) }
    }

    // MARK: Commands

    /// `goto_workspace`, `previous_workspace`, and `next_workspace`. Reports true even when
    /// the target is already shown, as the tab twins do.
    @discardableResult
    func show(_ target: Target) -> Bool {
        guard let index = index(of: target) else { return false }
        return show(workspaces[index].id)
    }

    /// New Workspace (SPEC §9.5): "Workspace N", or `name`, at the end, holding one new Tab
    /// made from `baseConfig`, and shown. `parent` is the Tab the request came from. A folder
    /// opened into the Window passes its name and `comingForward` (§9.1). Registers Undo
    /// New Workspace.
    @discardableResult
    func newWorkspace(
        from parent: TerminalController,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?,
        named name: String? = nil,
        comingForward: Bool = false
    ) -> Bool {
        reconcile()
        guard tabGroup != nil, !isInNonNativeFullscreen,
              let tab = newTab(from: parent, withBaseConfig: baseConfig)
        else { return false }

        let previous = shownID
        let id = addWorkspace(holding: [tab], named: name)
        if show(id, comingForward: comingForward) {
            registerUndoForNewWorkspace(tab, previous: previous, withBaseConfig: baseConfig)
            return true
        }

        workspaces.removeAll { $0.id == id }
        tab.surfaceTree = .init() // closes the never-shown Tab and ends its shell
        return false
    }

    /// A new Tab for this Window, made from `baseConfig`, or holding `tree`, with `parent`'s
    /// window style and opacity. Its window is loaded but not shown: it appears when a switch
    /// selects it and takes the group's frame then (SPEC §2.6).
    func newTab(
        from parent: TerminalController,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil
    ) -> TerminalController? {
        let tab = TerminalController(
            parent.ghostty, withBaseConfig: baseConfig, withSurfaceTree: tree, windowStyle: parent.windowStyle)
        tab.isBackgroundOpaque = parent.isBackgroundOpaque
        tab.workspaceStore = self
        return tab.window != nil ? tab : nil
    }

    /// Adds a hidden Workspace named `name`, by default "Workspace N", holding `tabs`, at the
    /// end of the bar, so existing Workspaces keep their places (SPEC §1.3).
    func addWorkspace(holding tabs: [TerminalController], named name: String? = nil) -> Workspace.ID {
        let workspace = Workspace(name: name ?? Self.newName(in: workspaces), hiddenTabs: tabs)
        workspaces.append(workspace)
        return workspace.id
    }

    /// Names Workspace `id` (SPEC §1.2). A blank name restores its original name; names
    /// needn't be unique, and a rename can't be undone.
    func rename(_ id: Workspace.ID, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let isBlank = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        workspaces[index].name = isBlank ? workspaces[index].originalName : name
        invalidateRestorableState()
    }

    /// Workspace Color ▸ (SPEC §5.4). Any Workspace, hidden ones included. No undo, just
    /// like a Tab's color.
    func setColor(_ color: TerminalTabColor, of id: Workspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].color != color
        else { return }
        workspaces[index].color = color
        invalidateRestorableState()
    }

    /// The rename prompt (SPEC §7.5), as a sheet on the shown Tab. Any Workspace can be
    /// its target, hidden ones included. False when there's no shown Tab to put it on.
    func promptName(for id: Workspace.ID) -> Bool {
        guard let window = shownTab?.window,
              let current = workspaces.first(where: { $0.id == id })?.name
        else { return false }

        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Leave blank to restore the original name."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = current
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(id, to: textField.stringValue)
        }
        return true
    }

    /// Moves Workspace `id` to `index` in bar order, so ⌘⌥N order follows (SPEC §1.3). It
    /// lands at `index` by the Tab rows' rule, so moving right lands after the Workspace that
    /// was there, and an `index` past either end stops there. The shown Workspace stays
    /// shown. Reports false only when the Window has one Workspace or doesn't hold `id`, and
    /// true when nothing moves (SPEC §7.1).
    @discardableResult
    func moveWorkspace(_ id: Workspace.ID, to index: Int) -> Bool {
        guard workspaces.count > 1, let from = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(index, 0), workspaces.count - 1)
        guard to != from else { return true }

        var reordered = workspaces
        reordered.insert(reordered.remove(at: from), at: to)
        workspaces = reordered
        invalidateRestorableState()
        return true
    }

    /// Close Workspace (SPEC §13.1) for Workspace `id`, shown or hidden, requested from `tab`,
    /// the target Split's Tab. On the Window's only Workspace it forwards to Close Window.
    /// Otherwise it asks once, on the shown Tab, if any of the Workspace's Tabs would, then
    /// closes it. Closing the shown Workspace is a request (`allowsRequest`); a hidden one
    /// closes out of sight, in non-native fullscreen too (§3, §14).
    func closeWorkspace(_ id: Workspace.ID, from tab: TerminalController) -> Bool {
        reconcile()
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return false }
        guard workspaces.count > 1 else {
            tab.closeWindow(nil)
            return true
        }
        if id == shownID {
            guard allowsRequest(from: tab, orShow: .cannotClose) else { return false }
        }

        guard tabs(of: id).contains(where: { $0.surfaceTree.contains { $0.needsConfirmQuit } }) else {
            return closeWorkspaceImmediately(id)
        }
        guard let sheetTab = shownTab else { return false }

        let subject = id == shownID ? "this Workspace" : "the hidden Workspace “\(workspace.name)”"
        sheetTab.confirmClose(
            messageText: "Close Workspace?",
            informativeText: "At least one tab in \(subject) still has a running process. If you close the Workspace the processes will be killed."
        ) { [weak self] in
            self?.closeWorkspaceImmediately(id)
        }
        return true
    }

    /// Closes Workspace `id` and its Tabs without asking, and registers Undo Close Workspace.
    /// The shown one shows its neighbor first, so the live group never empties (SPEC §13),
    /// leaving non-native fullscreen before that switch (§13.6); if the switch fails, nothing
    /// closes. The only Workspace closes the Window.
    @discardableResult
    func closeWorkspaceImmediately(_ id: Workspace.ID) -> Bool {
        reconcile()
        guard workspaces.contains(where: { $0.id == id }) else { return false }
        guard workspaces.count > 1 else {
            shownTab?.closeWindowImmediately()
            return true
        }
        if id == shownID {
            leaveNonNativeFullscreen()
            guard let neighborID, show(neighborID) else { return false }
        }

        // Hidden now, so its Tabs and remembered Tab are the store's.
        guard let saved = undoState(of: id),
              let workspace = workspaces.first(where: { $0.id == id })
        else { return false }
        registerUndoForCloseWorkspace(saved, tabs: workspace.hiddenTabs, remembered: workspace.rememberedTab)

        // An emptied tree closes its Tab with no Undo Close Tab, and the last Tab to close
        // ends the Workspace (`removeHiddenTab`).
        for tab in workspace.hiddenTabs { tab.surfaceTree = .init() }
        return true
    }

    // MARK: Closing the Window

    /// The names of the hidden Workspaces holding a Tab for which `asks` holds, in bar order.
    /// Close Window and Quit name them (SPEC §13.2, §13.3).
    func hiddenNames(where asks: (TerminalController) -> Bool) -> [String] {
        workspaces.filter { $0.id != shownID && $0.hiddenTabs.contains(where: asks) }.map(\.name)
    }

    /// How Close Window and Quit name hidden Workspaces (SPEC §13.8): "the hidden Workspace
    /// “api”", or "the hidden Workspaces" and at most three names in bar order, joined as a list
    /// that ends with "and N more" past three. Nil for none.
    static func hiddenWorkspacesPhrase(naming names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        var items = names.prefix(3).map { "“\($0)”" }
        if names.count > 3 { items.append("\(names.count - 3) more") }
        let list = switch items.count {
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
        return (names.count == 1 ? "the hidden Workspace " : "the hidden Workspaces ") + list
    }

    // MARK: Restoring

    /// Brings back a restored Window's Workspaces (SPEC §17.2). The shown Workspace's Tabs are
    /// the ones AppKit restored, which form the group. The others come back hidden, and their
    /// Tabs' shells start now. A hidden Workspace none of whose Tabs comes back is gone.
    func restore(_ saved: WorkspacesRestorableState.Window, ghostty: Ghostty.App) {
        guard saved.workspaces.indices.contains(saved.shownIndex) else { return }

        var restored: [Workspace] = []
        for (index, entry) in saved.workspaces.enumerated() {
            let isShown = index == saved.shownIndex
            let tabs: [TerminalController?] = isShown ? [] : entry.tabs.map { data in
                guard let state = TerminalRestorableState(archived: data) else { return nil }
                return TerminalWindowRestoration.makeTab(from: state, ghostty: ghostty)
            }
            var workspace = Workspace(id: entry.id, name: entry.name, hiddenTabs: tabs.compactMap { $0 })
            guard isShown || !workspace.hiddenTabs.isEmpty else { continue }

            workspace.originalName = entry.originalName
            workspace.color = entry.color
            if let i = entry.rememberedTabIndex, tabs.indices.contains(i), let tab = tabs[i] {
                workspace.rememberedTab = tab
            }
            restored.append(workspace)
        }

        bringBack(restored, shown: saved.workspaces[saved.shownIndex].id)
    }

    /// Brings back a Window's Workspaces in bar order, `id` shown, around the shown Tabs already
    /// in its group: on relaunch and by Undo Close Window (SPEC §16, §17.2). The hidden ones'
    /// Tabs are ordered out and adopt this store.
    func bringBack(_ restored: [Workspace], shown id: Workspace.ID) {
        for tab in restored.flatMap(\.hiddenTabs) { tab.workspaceStore = self }
        workspaces = restored
        shownID = id
        invalidateRestorableState()
    }

    // MARK: Hidden Tabs

    /// `new_tab` aimed at hidden `parent` (SPEC §14): a Tab made from `baseConfig` joins
    /// `parent`'s Workspace out of sight, right after its remembered Tab, or at the end under
    /// `window-new-tab-position = end`, and becomes remembered, as a new Tab is selected. Its
    /// shell starts now. Nil if `parent` isn't hidden.
    func newHiddenTab(beside parent: TerminalController, withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?) -> TerminalController? {
        guard let index = hiddenIndex(of: parent),
              let tab = newTab(from: parent, withBaseConfig: baseConfig)
        else { return nil }

        var workspace = workspaces[index]
        let atEnd = parent.ghostty.config.windowNewTabPosition == "end"
        workspace.hiddenTabs.insert(tab, at: Self.newTabIndex(after: workspace.rememberedTab, in: workspace.hiddenTabs, atEnd: atEnd))
        workspace.rememberedTab = tab
        workspaces[index] = workspace
        invalidateRestorableState()
        return tab
    }

    /// Where a new Tab goes among `tabs`: right after `remembered`, or at the end when `atEnd`
    /// or `remembered` isn't one of them.
    static func newTabIndex<Tab: AnyObject>(after remembered: Tab?, in tabs: [Tab], atEnd: Bool) -> Int {
        guard !atEnd, let index = tabs.firstIndex(where: { $0 === remembered }) else { return tabs.count }
        return index + 1
    }

    /// Makes hidden `tab` its Workspace's remembered Tab, so showing the Workspace selects it.
    func remember(_ tab: TerminalController) {
        guard let index = hiddenIndex(of: tab), workspaces[index].rememberedTab !== tab else { return }
        workspaces[index].rememberedTab = tab
        invalidateRestorableState()
    }

    /// Moves hidden `tab` to `position` among its Workspace's Tabs.
    func moveHiddenTab(_ tab: TerminalController, to position: Int) {
        guard let index = hiddenIndex(of: tab),
              let from = workspaces[index].hiddenTabs.firstIndex(where: { $0 === tab }),
              from != position
        else { return }

        var workspace = workspaces[index]
        workspace.hiddenTabs.remove(at: from)
        workspace.hiddenTabs.insert(tab, at: position)
        workspaces[index] = workspace
        invalidateRestorableState()
    }

    /// Drops `tab`, which closed or left, from its hidden Workspace; does nothing if it isn't
    /// in one. The remembered Tab passes on per `remembered(_:after:leaves:)`, and a Workspace
    /// left without Tabs ends quietly while the Window keeps showing what it shows (SPEC §1.4,
    /// §13.5).
    func removeHiddenTab(_ tab: TerminalController) {
        guard let index = hiddenIndex(of: tab) else { return }
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
}

@MainActor
extension BaseTerminalController {
    /// True for a Tab in one of its Window's hidden Workspaces: ordered out, yet still in
    /// `NSApp.windows` and `NSApp.orderedWindows` (SPEC §2.5).
    var isInHiddenWorkspace: Bool {
        guard let tab = self as? TerminalController else { return false }
        return tab.workspaceStore.isHidden(tab)
    }

    /// Runs before every Jump's usual focus (SPEC §2.4): shows this Tab's Workspace if it's
    /// hidden. False means the jump stops here and reports false; see `WorkspaceStore.reveal`.
    func revealForJump() -> Bool {
        guard let tab = self as? TerminalController else { return true }
        return tab.workspaceStore.reveal(tab)
    }

    /// Undo shows what it changes (SPEC §16): shows this Tab's Workspace if it's hidden,
    /// unless the Window can't switch now. Every undo and redo that changes a Tab or Split
    /// calls it first.
    func showForUndo() {
        guard let tab = self as? TerminalController else { return }
        tab.workspaceStore.showForUndo(tab)
    }
}

@MainActor
extension TerminalController {
    /// The Tab that stands for this one on screen: itself, or, while it's hidden, its
    /// Window's shown Tab (SPEC §2.5). Use it wherever a Tab is picked to order front or
    /// to parent new Tabs, so a hidden Tab never surfaces as a stray window.
    var onScreenTab: TerminalController? {
        isInHiddenWorkspace ? workspaceStore.shownTab : self
    }
}
