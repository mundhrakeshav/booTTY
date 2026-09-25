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

    @Published private(set) var workspaces: [Workspace] {
        // One that ends or leaves the Window drops out of recency (SPEC §8.3).
        didSet { recentIDs.removeAll { id in !workspaces.contains { $0.id == id } } }
    }
    @Published private(set) var shownID: Workspace.ID

    /// Recency, newest first, the shown Workspace included once it has been shown by a
    /// switch (SPEC §8.3). Per Window and in memory only. See `markShown(_:)`.
    private var recentIDs: [Workspace.ID] = []

    var shownIndex: Int { workspaces.firstIndex { $0.id == shownID } ?? 0 }

    /// The Window's live native tab group, holding exactly the shown Workspace's Tabs.
    private(set) weak var tabGroup: NSWindowTabGroup?
    private var tabGroupObservation: NSKeyValueObservation?
    private var hasBound = false

    /// The shown Tabs as last seen, to tell which ones left the group. It keeps a Tab in
    /// non-native fullscreen, which has left the group but is still shown (SPEC §3).
    private var knownShownTabs: [Weak<TerminalController>] = []

    /// The shown Tabs' frame as last seen. A re-formed group takes it, since by the time the
    /// store notices its group emptied, the Tab that left has taken another Window's frame.
    private var shownFrame: NSRect?

    /// Set while the store changes the group itself, so the Window's own callbacks (the
    /// incoming Tab becoming key) don't reconcile a half-done switch.
    private var isChanging = false

    /// The scroll gesture over this Window's bar, told apart by its first movement. The
    /// Window has one gesture at a time, and every Tab's monitor reads it.
    private var swipeGesture = SwipeGesture.none

    /// Set when a claimed gesture ends, until its momentum ends or a new gesture begins, so
    /// whichever of the Window's Tabs gets that momentum drops it (SPEC §6.2).
    private var dropsSwipeMomentum = false

    /// Bumped by each claimed swipe and each cancel. A swipe from before stops tracking.
    private var swipeGeneration = 0

    /// Undo and Redo Organize's target, so both come off the undo stack together.
    private let organizeUndoTarget = NSObject()

    /// The Window's Tabs when Undo or Redo Organize was last registered. Once they differ,
    /// both entries come off the stack (SPEC §10.6).
    private var organizeUndoTabs: Set<ObjectIdentifier>?

    /// Set when the swipe switched at the lift: what its amount gains to count from the
    /// Workspace shown now, and the Workspace it came from, which the settle keeps beside it.
    private var swipeSwitch: (rebase: CGFloat, from: Workspace.ID)?

    /// Where the swipe stands, so whichever of the Window's Tabs is shown draws it, the
    /// incoming Tab's bar included during the settle (SPEC §6.3).
    @Published private(set) var swipeProgress = SwipeProgress()

    /// Bumped by each cancel that moved the swipe back to rest, so the bar morphs the
    /// capsule back to the shown mark (SPEC §6.5).
    @Published private(set) var swipeCancels = 0

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

    private func hiddenIndex(of tab: TerminalController) -> Int? {
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
    private func newTab(
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

    /// Organize (SPEC §10): regroups every Tab of the Window, hidden ones included, into new,
    /// uncolored Workspaces that replace the old ones, one per repo or folder of each Tab's
    /// focused Split. Splits whose key differs break out as Tabs of their own (§10.3). The
    /// Workspace holding the shown Tab is shown, and that Tab stays selected with its focused
    /// Split. Registers Undo Organize (§10.6). Returns false with nothing changed when there's
    /// no group or the Window is in non-native fullscreen; requests check `allowsRequest` first.
    @discardableResult
    func organize(by mode: OrganizeMode) -> Bool {
        reconcile()
        guard tabGroup != nil, !isInNonNativeFullscreen, let selected = shownTab else { return false }

        var before = arrangement
        let ordered = workspaces.flatMap { tabs(of: $0.id) }
        var keys: [ObjectIdentifier: String?] = [:]
        var kept: Trees = []
        var pieces: Trees = [] // with the Tab each breaks out of
        var pieceKeys: [String] = []
        for tab in ordered {
            let split = Self.organizeSplit(tab.surfaceTree, focused: tab.focusedSurface) {
                Self.organizeKey(of: $0.pwd, by: mode)
            }
            keys[ObjectIdentifier(tab)] = split.key
            guard !split.brokenOut.isEmpty else { continue }
            before.trees.append((tab, tab.surfaceTree))
            kept.append((tab, split.kept))
            pieces += split.brokenOut.map { (tab, $0.tree) }
            pieceKeys += split.brokenOut.map(\.key)
        }

        // The Tabs Organize makes don't take earlier Organize entries off the stack.
        let undoTabs = organizeUndoTabs
        organizeUndoTabs = nil
        defer { if organizeUndoTabs == nil { organizeUndoTabs = undoTabs } }

        guard let made = breakOut(keeping: kept, into: pieces) else { return false }
        var brokenOut: [ObjectIdentifier: [TerminalController]] = [:]
        for (index, tab) in made.enumerated() {
            keys[ObjectIdentifier(tab)] = pieceKeys[index]
            brokenOut[ObjectIdentifier(pieces[index].tab), default: []].append(tab)
        }

        let groups = Self.organizeGroups(
            ordered,
            key: { keys[ObjectIdentifier($0)] ?? nil },
            brokenOut: { brokenOut[ObjectIdentifier($0)] ?? [] },
            remembering: [selected] + workspaces.compactMap(\.rememberedTab))
        let organized = groups.map { group in
            var workspace = Workspace(name: group.name, hiddenTabs: group.tabs)
            workspace.rememberedTab = group.tabs.contains { $0 === selected } ? selected : group.rememberedTab
            return workspace
        }
        guard let shown = organized.first(where: { $0.rememberedTab === selected }),
              arrange(Arrangement(workspaces: organized, shownID: shown.id), comingForward: false)
        else {
            foldBack(made, into: before.trees)
            return false
        }

        registerUndoOrganize(restoring: before, from: selected)
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

    /// Whether a requested command that would change the shown Workspace may run now. `tab`
    /// is the Tab of the command's target Split. Otherwise the command reports false:
    /// - aimed at a hidden Split, with nothing shown (SPEC §14);
    /// - while the shown Tab has a sheet, bringing the Window and its sheet forward (§13.7);
    /// - in non-native fullscreen, showing `alert` on `tab` when that's the windowed group's
    ///   selected Tab, else on the fullscreen Tab (§3).
    ///
    /// The neighbor shown because the shown Workspace ended, and undo, aren't requests and
    /// don't come through here.
    func allowsRequest(from tab: TerminalController, orShow alert: WorkspaceAlert) -> Bool {
        reconcile()
        guard !isHidden(tab) else { return false }

        if let window = shownTab?.window, window.attachedSheet != nil {
            Self.bringForward(window)
            return false
        }

        return !refusesInFullscreen(tab, showing: alert)
    }

    /// True in non-native fullscreen (SPEC §3), after showing `alert` on `tab` when that's
    /// the windowed group's selected Tab, else on the fullscreen Tab. A nil `alert` refuses
    /// silently.
    private func refusesInFullscreen(_ tab: TerminalController, showing alert: WorkspaceAlert?) -> Bool {
        guard let fullscreen = tabs(of: shownID).first(where: { $0.isInNonNativeFullscreen }) else { return false }
        let isWindowedSelection = tab.window != nil && tab.window === tabGroup?.selectedWindow
        alert?.show(on: isWindowedSelection ? tab.window : fullscreen.window)
        return true
    }

    /// Leaves non-native fullscreen, for an undo or a close that changes the shown Workspace's
    /// Tabs (SPEC §13.6, §16): the fullscreen Tab exits and rejoins the windowed group behind
    /// it, or, with that group empty, forms the Window's group itself, and the store binds to
    /// it. Does nothing outside non-native fullscreen.
    func leaveNonNativeFullscreen() {
        let fullscreen = tabs(of: shownID).filter(\.isInNonNativeFullscreen)
        guard !fullscreen.isEmpty else { return }
        for tab in fullscreen { tab.fullscreenStyle?.exit() }
        reconcile()
    }

    /// A Jump into `tab` (SPEC §2.4): shows its hidden Workspace with `tab` selected and the
    /// Window coming forward, so the caller's usual focus can run. A shown Tab needs nothing.
    /// Otherwise the jump reports false with nothing switched and never brings `tab` front:
    /// - while the shown Tab has a sheet, the Window and its sheet come forward (§13.7);
    /// - in non-native fullscreen, the fullscreen Tab comes forward with "Cannot Switch
    ///   Workspace" (§3).
    func reveal(_ tab: TerminalController) -> Bool {
        reconcile()
        guard let target = hiddenIndex(of: tab) else { return true }

        if let window = shownTab?.window, window.attachedSheet != nil {
            Self.bringForward(window)
            return false
        }

        if let fullscreen = tabs(of: shownID).first(where: { $0.isInNonNativeFullscreen })?.window {
            Self.bringForward(fullscreen)
            WorkspaceAlert.cannotSwitch.show(on: fullscreen)
            return false
        }

        workspaces[target].rememberedTab = tab
        return show(workspaces[target].id, comingForward: true)
    }

    private static func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
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

    /// Remembers the shown Tabs' frame, which a re-formed group takes (SPEC §2.3). The Tabs
    /// call this whenever their frame changes.
    func recordShownFrame() {
        if let frame = tabGroup?.selectedWindow?.frame { shownFrame = frame }
    }

    // MARK: Arranging

    /// Tabs with the split tree each has or gets.
    private typealias Trees = [(tab: TerminalController, tree: SplitTree<Ghostty.SurfaceView>)]

    /// A Window's whole arrangement, as Organize makes it and Undo and Redo Organize bring it
    /// back (SPEC §10.6): its Workspaces in bar order, each listing all its Tabs in order in
    /// `hiddenTabs` and remembering the Tab it selects, the shown one included.
    private struct Arrangement {
        var workspaces: [Workspace]
        var shownID: Workspace.ID
        /// The split trees it gives the Tabs Organize broke Splits out of, and the broken-out
        /// Tabs (§10.3). Bringing it back folds a Window's Tab it doesn't hold, broken out
        /// since, back into these trees; a Tab listed here that has folded back since breaks
        /// out again as a new Tab.
        var trees: Trees = []
    }

    /// The Window's arrangement now. The shown Workspace remembers the shown Tab.
    private var arrangement: Arrangement {
        var workspaces = workspaces
        workspaces[shownIndex].hiddenTabs = tabs(of: shownID)
        workspaces[shownIndex].rememberedTab = shownTab
        return Arrangement(workspaces: workspaces, shownID: shownID)
    }

    /// Every Tab of the Window, shown or hidden, by identity.
    private var tabIDs: Set<ObjectIdentifier> {
        Set(workspaces.flatMap { tabs(of: $0.id) }.map(ObjectIdentifier.init))
    }

    /// Makes `arrangement` the Window's. It holds the Window's Tabs, but for broken-out Tabs
    /// about to fold back, which order out and leave the Workspaces. Its shown Workspace's
    /// Tabs become the live group, in order, around its remembered Tab, which is selected;
    /// the rest order out. This doesn't go through `show`, so it cancels a swipe itself (SPEC
    /// §6.3) and counts as no show toward recency: the shown Workspace is newest and the rest
    /// follow bar order (§8.3). `comingForward` is `show(_:comingForward:)`'s.
    /// Returns false with nothing changed when there's no group, the Window is in non-native
    /// fullscreen, or AppKit threw while adding or selecting the remembered Tab.
    private func arrange(_ arrangement: Arrangement, comingForward: Bool) -> Bool {
        reconcile()
        guard let group = tabGroup,
              let oldSelected = group.selectedWindow,
              !isInNonNativeFullscreen,
              let shown = arrangement.workspaces.first(where: { $0.id == arrangement.shownID }),
              let selected = (shown.rememberedTab ?? shown.hiddenTabs.first)?.window
        else { return false }

        // A minimized Window is never key or main.
        if comingForward, oldSelected.isMiniaturized { oldSelected.deminiaturize(nil) }

        let outgoing = Self.tabs(in: group)
        isChanging = true
        let regrouped = Self.regroup(
            group,
            holding: shown.hiddenTabs.compactMap(\.window),
            selecting: selected,
            makeKey: comingForward || oldSelected.isKeyWindow || oldSelected.isMainWindow)
        isChanging = false
        guard regrouped else { return false }
        cancelSwipe()

        let grouped = Self.tabs(in: group)

        // A switcher open in an outgoing Tab closes (SPEC §8.1).
        for tab in outgoing where !grouped.contains(where: { $0 === tab }) { tab.workspaceSwitcherIsShowing = false }

        // A Tab that failed to order out stayed in the group, so it's shown. One that failed
        // to join stays hidden, in a Workspace of its own beside the shown one.
        var arranged: [Workspace] = []
        for var workspace in arrangement.workspaces {
            let hidden = workspace.hiddenTabs.filter { tab in !grouped.contains { $0 === tab } }
            if workspace.id == arrangement.shownID {
                workspace.hiddenTabs = []
                workspace.rememberedTab = nil
                arranged.append(workspace)
                if !hidden.isEmpty { arranged.append(Workspace(name: workspace.name, hiddenTabs: hidden)) }
            } else if !hidden.isEmpty {
                if !hidden.contains(where: { $0 === workspace.rememberedTab }) { workspace.rememberedTab = hidden.first }
                workspace.hiddenTabs = hidden
                arranged.append(workspace)
            }
        }

        workspaces = arranged
        shownID = arrangement.shownID
        reconcile()
        invalidateRestorableState()
        didShow(selected)
        return true
    }

    /// Registers Undo Organize, which brings back `arrangement`, the one Organize replaced
    /// (SPEC §10.6). Undoing registers Redo Organize, which brings back the arrangement the
    /// undo replaced, and so on. Both come off the stack once a Tab enters or leaves the
    /// Window (`dropOrganizeUndoIfTabsChanged`).
    private func registerUndoOrganize(restoring arrangement: Arrangement, from tab: TerminalController) {
        guard let undoManager = tab.undoManager else { return }
        organizeUndoTabs = tabIDs
        undoManager.setActionName("Organize")
        undoManager.registerUndo(withTarget: organizeUndoTarget, expiresAfter: tab.undoExpiration) { [weak self] _ in
            self?.restoreArrangement(arrangement)
        }
    }

    /// Undo or Redo Organize: leaves non-native fullscreen, brings back `arrangement`, then
    /// registers the opposite entry. Tabs broken out since fold back, and Tabs folded back
    /// since break out again (SPEC §10.3). Refused, with nothing changed, unless every Split
    /// is where the entry left it, so none is lost. With a sheet on the shown Tab, the
    /// Workspace holding that Tab is shown instead, with the Tab still selected, and the
    /// Window comes forward with its sheet (§16); a shown Tab with a sheet doesn't fold back,
    /// so that refuses.
    private func restoreArrangement(_ arrangement: Arrangement) {
        reconcile()
        let windowTabs = tabIDs
        let held = Set(arrangement.workspaces.flatMap(\.hiddenTabs).map(ObjectIdentifier.init))
        let extras = workspaces.flatMap { tabs(of: $0.id) }.filter { !held.contains(ObjectIdentifier($0)) }
        let missing = arrangement.trees.filter { !windowTabs.contains(ObjectIdentifier($0.tab)) }
        let kept = arrangement.trees.filter { windowTabs.contains(ObjectIdentifier($0.tab)) }
        guard extras.isEmpty || missing.isEmpty,
              held.subtracting(windowTabs) == Set(missing.map { ObjectIdentifier($0.tab) }),
              Self.splits(of: (kept.map(\.tab) + extras).map(\.surfaceTree))
                == Self.splits(of: arrangement.trees.map(\.tree))
        else { return }
        leaveNonNativeFullscreen()
        guard let tab = shownTab else { return }

        var replaced = self.arrangement
        replaced.trees = (kept.map(\.tab) + extras).map { ($0, $0.surfaceTree) }
        var arrangement = arrangement
        if !allowsUndoSwitch() {
            guard let holding = arrangement.workspaces.firstIndex(where: { $0.hiddenTabs.contains { $0 === tab } })
            else { return }
            arrangement.shownID = arrangement.workspaces[holding].id
            arrangement.workspaces[holding].rememberedTab = tab
        }

        // The Tabs this makes and closes don't take the other Organize entries off the stack.
        let undoTabs = organizeUndoTabs
        organizeUndoTabs = nil
        defer { if organizeUndoTabs == nil { organizeUndoTabs = undoTabs } }

        if missing.isEmpty {
            guard arrange(arrangement, comingForward: true) else { return }
            foldBack(extras, into: kept)
        } else {
            // New Tabs stand in for the ones that folded back.
            guard let made = breakOut(keeping: kept, into: missing) else { return }
            let remade = Dictionary(uniqueKeysWithValues: zip(missing.map { ObjectIdentifier($0.tab) }, made))
            func live(_ tab: TerminalController) -> TerminalController { remade[ObjectIdentifier(tab)] ?? tab }
            for index in arrangement.workspaces.indices {
                arrangement.workspaces[index].hiddenTabs = arrangement.workspaces[index].hiddenTabs.map(live)
                arrangement.workspaces[index].rememberedTab = arrangement.workspaces[index].rememberedTab.map(live)
            }
            guard arrange(arrangement, comingForward: true) else {
                foldBack(made, into: replaced.trees)
                return
            }
        }
        registerUndoOrganize(restoring: replaced, from: tab)
    }

    /// Every Split of `trees`, by identity.
    private static func splits(of trees: [SplitTree<Ghostty.SurfaceView>]) -> Set<ObjectIdentifier> {
        Set(trees.flatMap { $0.map(ObjectIdentifier.init) })
    }

    /// Breaks Splits out into new Tabs (SPEC §10.3), as Move Split moves one into a new
    /// window: each of `kept`'s Tabs takes its tree, giving up the Splits it lacks, then each
    /// of `pieces` becomes a new Tab like its `tab`, holding `tree` and focused on its first
    /// Split. The new Tabs are in no Workspace yet. Nil, with nothing changed, if one couldn't
    /// be made.
    private func breakOut(keeping kept: Trees, into pieces: Trees) -> [TerminalController]? {
        let trees: Trees = kept.map { ($0.tab, $0.tab.surfaceTree) }
        for (tab, tree) in kept { tab.surfaceTree = tree }
        var made: [TerminalController] = []
        for (parent, tree) in pieces {
            guard let tab = newTab(from: parent, withSurfaceTree: tree) else {
                foldBack(made, into: trees)
                return nil
            }
            tab.focusedSurfaceDidChange(to: tree.first)
            made.append(tab)
        }
        return made
    }

    /// Folds broken-out Splits back (SPEC §10.6): `tabs`, in no Workspace, close, then each of
    /// `trees`' Tabs takes its tree, and with it their Splits.
    private func foldBack(_ tabs: [TerminalController], into trees: Trees) {
        // An emptied tree closes its Tab with no Undo Close Tab. `trees` keep its Splits.
        for tab in tabs { tab.surfaceTree = .init() }
        for (tab, tree) in trees { tab.surfaceTree = tree }
    }

    /// Takes Undo and Redo Organize off the stack once a Tab has entered or left the Window
    /// since they were registered (SPEC §10.6). Every change to the Window's Tabs ends in
    /// `reconcile()` or `invalidateRestorableState()`, and both call this.
    private func dropOrganizeUndoIfTabsChanged() {
        guard let tabs = organizeUndoTabs, tabs != tabIDs else { return }
        organizeUndoTabs = nil
        (NSApp.delegate as? AppDelegate)?.undoManager.removeAllActions(withTarget: organizeUndoTarget)
    }

    // MARK: Undo

    /// What undo keeps of a Workspace to find it again, or to recreate it once it has ended
    /// (SPEC §16).
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

    /// Where an undo entry acts on Workspace `saved` (SPEC §16): the Window holding it now,
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
    /// end if the Window now has fewer Workspaces (SPEC §16).
    func recreate(_ saved: UndoState, holding tabs: [TerminalController], remembering remembered: TerminalController? = nil) {
        workspaces.insert(Self.workspace(saved, holding: tabs, remembering: remembered), at: min(saved.position, workspaces.count))
        invalidateRestorableState()
    }

    /// Brings back an ended Workspace whose last Window has closed as a Window of its own,
    /// holding `tabs`, which are ordered out and in no Workspace, by Move Workspace to New
    /// Window's path (SPEC §16). It keeps its id, name, original name, and color, and shows
    /// `remembered`, else its first Tab. The Tabs' window style is their old Window's. False,
    /// with nothing changed, if the Tab couldn't come on screen.
    static func reopen(_ saved: UndoState, holding tabs: [TerminalController], remembering remembered: TerminalController? = nil) -> Bool {
        openWindow(holding: workspace(saved, holding: tabs, remembering: remembered), sizedLike: nil)
    }

    private static func workspace(_ saved: UndoState, holding tabs: [TerminalController], remembering remembered: TerminalController?) -> Workspace {
        var workspace = Workspace(id: saved.id, name: saved.name, hiddenTabs: tabs)
        workspace.rememberedTab = remembered ?? tabs.first
        workspace.originalName = saved.originalName
        workspace.color = saved.color
        return workspace
    }

    /// Whether an undo or redo may switch Workspaces now (SPEC §16). Not while the shown Tab
    /// has a sheet, and then the Window comes forward with its sheet; not in non-native
    /// fullscreen. Neither shows an alert: the undo applies without switching.
    private func allowsUndoSwitch() -> Bool {
        if let window = shownTab?.window, window.attachedSheet != nil {
            Self.bringForward(window)
            return false
        }
        return !isInNonNativeFullscreen
    }

    /// Undo shows what it changes (SPEC §16): before an undo or redo changes `tab`, shows the
    /// hidden Workspace holding it, with `tab` selected and the Window coming forward. When
    /// `allowsUndoSwitch()` refuses, nothing switches.
    func showForUndo(_ tab: TerminalController) {
        reconcile()
        guard hiddenIndex(of: tab) != nil, allowsUndoSwitch(), let index = hiddenIndex(of: tab) else { return }
        workspaces[index].rememberedTab = tab
        show(workspaces[index].id, comingForward: true)
    }

    /// Undo Close Tab (SPEC §16): puts `tab`, ordered out and in no Workspace, back in its
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

    /// Registers Undo New Workspace for `tab`, the Tab New Workspace made (SPEC §16). Undo
    /// closes it as Undo New Tab does, so the Workspace ends if that leaves it empty, and
    /// shows `previous`, the Workspace shown before. Redo brings the Workspace back with the
    /// same id, name, and position.
    private func registerUndoForNewWorkspace(
        _ tab: TerminalController,
        previous: Workspace.ID,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?
    ) {
        guard let undoManager = tab.undoManager else { return }
        // Its own step, so each folder of a multi-folder open undoes on its own (SPEC §9.1).
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
    /// where it was at `index` (SPEC §11.4). Undo moves it back there and shows it; the redo
    /// that move registers in turn moves it again under a move's view rules (§11.2, §11.3).
    /// Both come off the stack when the Tab alone leaves the Window (`dropUndoMoveTab(of:)`).
    private func registerUndoMoveTab(_ tab: TerminalController, from saved: UndoState, at index: Int) {
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
    /// first (SPEC §16). `showing` (undo) then shows the Workspace with `tab` selected and
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
    /// has ended there, or has ended and its last Window has closed (nil) (SPEC §11.4, §16):
    /// `tab` leaves this Window and goes back as Undo Close Tab puts a Tab back (`showing` as
    /// in `moveBack`), or with its Workspace as a Window of its own. Then registers the
    /// opposite entry. Nothing moves while the Tab has a sheet up. A Tab going into `target`'s
    /// shown Workspace makes that Window leave non-native fullscreen first, as `moveBack` did
    /// here for a Tab leaving this Window's shown Workspace (SPEC §16).
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
    /// Window alone: torn off, sent to a new Window, or dragged to another (SPEC §11.4).
    private static func dropUndoMoveTab(of tab: TerminalController) {
        tab.undoManager?.removeAllActions(withTarget: tab.moveTabUndoTarget)
    }

    // MARK: Moving Tabs

    /// `move_tab_to_workspace:N` (SPEC §11.1): moves `tab` to the Nth Workspace in bar order,
    /// or the last one when N is past the end. False for N < 1, and for the Tab's own
    /// Workspace, which a Window with one Workspace always is.
    func moveTab(_ tab: TerminalController, toWorkspaceAt n: Int) -> Bool {
        reconcile()
        guard let index = index(of: .number(n)) else { return false }
        return moveTab(tab, to: workspaces[index].id)
    }

    /// `move_tab_to_new_workspace` (SPEC §11.1): moves `tab` into a new "Workspace N" at the
    /// end. A Workspace's only Tab is refused.
    func moveTabToNewWorkspace(_ tab: TerminalController) -> Bool {
        reconcile()
        guard tabs(of: workspace(holding: tab).id).count > 1 else { return false }

        let id = addWorkspace(holding: [])
        if moveTab(tab, to: id) { return true }
        workspaces.removeAll { $0.id == id }
        return false
    }

    /// Moves `tab` to the end of Workspace `id`'s Tabs, or to `index` among them. The Window
    /// keeps showing what it shows, and the target keeps its remembered Tab (SPEC §11.2),
    /// except that moving the shown Workspace's only Tab ends that Workspace and shows `id`
    /// with `tab` selected (§11.3). A Tab moved into the shown Workspace joins its tab bar
    /// unselected (§14). Registers Undo Move Tab (§11.4).
    ///
    /// Reports false with nothing moved when `id` is the Tab's own Workspace, the Tab has a
    /// sheet up (§11.6), AppKit threw, or the move would touch the shown Workspace in
    /// non-native fullscreen, which shows "Cannot Move Tab" for a shown Tab and refuses a
    /// hidden one silently (§3). Moves between two hidden Workspaces run there.
    func moveTab(_ tab: TerminalController, to id: Workspace.ID, at index: Int? = nil) -> Bool {
        reconcile()
        let source = workspace(holding: tab).id
        guard id != source,
              workspaces.contains(where: { $0.id == id }),
              let saved = undoState(of: source),
              let from = tabs(of: source).firstIndex(where: { $0 === tab }),
              let window = tab.window,
              window.attachedSheet == nil
        else { return false }

        if source == shownID || id == shownID,
           refusesInFullscreen(tab, showing: source == shownID ? .cannotMoveTab : nil) {
            return false
        }

        guard place(tab, window, from: source, to: id, at: index) else { return false }
        registerUndoMoveTab(tab, from: saved, at: from)
        return true
    }

    /// The AppKit and store steps of `moveTab(_:to:at:)`, once it has checked the move may run.
    private func place(
        _ tab: TerminalController,
        _ window: NSWindow,
        from source: Workspace.ID,
        to id: Workspace.ID,
        at index: Int?
    ) -> Bool {
        if source != shownID {
            if id == shownID {
                guard let group = tabGroup else { return false }
                isChanging = true
                let added = Self.withoutAnimation {
                    Self.performSafely(.add) {
                        if let index {
                            group.insertWindow(window, at: min(index, group.windows.count))
                        } else {
                            group.addWindow(window)
                        }
                    }
                }
                isChanging = false
                guard added else { return false }
            }

            removeHiddenTab(tab)
            if id == shownID {
                reconcile()
                shownTab?.relabelTabs()
            } else {
                insertHidden(tab, into: id, at: index)
            }
            return true
        }

        guard let group = tabGroup else { return false }

        // The shown Workspace's only Tab: the target's Tabs join the group around it (in
        // front of it by default), so the Window is never empty, and the source Workspace
        // ends. This is a switch not made by `show`, so it cancels a swipe in progress too
        // (SPEC §6.3).
        if tabs(of: shownID).count == 1 {
            guard let target = workspaces.firstIndex(where: { $0.id == id }) else { return false }
            isChanging = true
            let incoming = workspaces[target].hiddenTabs.compactMap(\.window)
            let inserted = Self.insert(incoming, around: window, leading: index, in: group)
            isChanging = false
            guard inserted else { return false }
            cancelSwipe()

            let outgoing = shownIndex
            workspaces[target].hiddenTabs = []
            workspaces[target].rememberedTab = nil
            markShown(id)
            shownID = id
            workspaces.remove(at: outgoing)

            reconcile()
            invalidateRestorableState()
            didShow(window)
            return true
        }

        let wasSelected = group.selectedWindow === window
        isChanging = true
        let detached = Self.detach(window, from: group, makeKey: window.isKeyWindow || window.isMainWindow)
        isChanging = false
        guard detached else { return false }

        insertHidden(tab, into: id, at: index)
        reconcile()
        if wasSelected, let surface = shownTab?.focusedSurface { Ghostty.moveFocus(to: surface) }
        shownTab?.relabelTabs()
        return true
    }

    /// Adds `tab`, ordered out and in a group of its own, to hidden Workspace `id` at `index`,
    /// by default the end. A Workspace with no remembered Tab (a new one) remembers it.
    private func insertHidden(_ tab: TerminalController, into id: Workspace.ID, at index: Int?) {
        guard let target = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let count = workspaces[target].hiddenTabs.count
        workspaces[target].hiddenTabs.insert(tab, at: min(index ?? count, count))
        if workspaces[target].rememberedTab == nil { workspaces[target].rememberedTab = tab }
        invalidateRestorableState()
    }

    /// Registers Undo Close Workspace for the closing Workspace `saved`, holding `tabs` and
    /// remembering `remembered` (SPEC §16). Undo brings it back whole in its last Window and
    /// shows it unless `allowsUndoSwitch()` refuses, or, with that Window closed, as a Window
    /// of its own; redo closes it again, wherever it is.
    private func registerUndoForCloseWorkspace(
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

    // MARK: Switching

    /// The one switch path (SPEC §2.3): shows Workspace `id`. Returns false, with the old
    /// Workspace still shown, when AppKit throws while adding or selecting the incoming Tabs,
    /// or when the Window can't switch now. Showing the shown Workspace changes nothing.
    /// A switch by any other path than the swipe itself cancels a swipe in progress (§6.3).
    ///
    /// `comingForward` is for a switch after which the Window comes forward (a jump, an undo,
    /// a folder opened into it): a minimized Window is deminiaturized first, and the incoming
    /// Tab is made key. Otherwise a background or minimized Window stays as it is.
    @discardableResult
    func show(_ id: Workspace.ID, comingForward: Bool = false, bySwipe: Bool = false) -> Bool {
        reconcile()
        guard id != shownID else { return true }

        // Non-native fullscreen takes the fullscreen Tab out of the group, so there's no
        // group to swap. Requests show their alert in `allowsRequest` before this.
        guard let target = workspaces.firstIndex(where: { $0.id == id }),
              let group = tabGroup,
              let oldSelected = group.selectedWindow,
              !isInNonNativeFullscreen,
              let incoming = (workspaces[target].rememberedTab ?? workspaces[target].hiddenTabs.first)?.window
        else { return false }

        // A minimized Window is never key or main.
        if comingForward, oldSelected.isMiniaturized { oldSelected.deminiaturize(nil) }

        isChanging = true
        let orderedOut = Self.swap(
            in: group,
            adding: workspaces[target].hiddenTabs.compactMap(\.window),
            selecting: incoming,
            makeKey: comingForward || oldSelected.isKeyWindow || oldSelected.isMainWindow)
        isChanging = false
        guard let orderedOut else { return false }
        if !bySwipe { cancelSwipe() }

        // The outgoing Workspace keeps the Tabs that left the group and remembers the one
        // that was selected.
        let outgoing = shownIndex
        let outgoingTabs = orderedOut.compactMap { $0.windowController as? TerminalController }
        workspaces[outgoing].hiddenTabs = outgoingTabs
        workspaces[outgoing].rememberedTab = outgoingTabs.first { $0.window === oldSelected } ?? outgoingTabs.first
        workspaces[target].hiddenTabs = []
        workspaces[target].rememberedTab = nil
        markShown(id)
        shownID = id

        // A Tab that failed to order out stayed in the group, so it joined the shown
        // Workspace. If none ordered out, the outgoing Workspace has no Tabs and ends.
        if outgoingTabs.isEmpty { workspaces.remove(at: outgoing) }

        reconcile()
        invalidateRestorableState()

        // A switcher open in the outgoing Tab closes (SPEC §8.1).
        for tab in outgoingTabs { tab.workspaceSwitcherIsShowing = false }

        didShow(incoming)
        return true
    }

    /// After Workspace `shownID` was shown with `incoming` selected: focus goes to its
    /// focused Split, the Tabs are relabeled, and VoiceOver announces the name.
    private func didShow(_ incoming: NSWindow) {
        let tab = incoming.windowController as? TerminalController
        if let surface = tab?.focusedSurface { Ghostty.moveFocus(to: surface) }
        tab?.relabelTabs()
        if incoming.isKeyWindow, let name = workspaces.first(where: { $0.id == shownID })?.name {
            NSAccessibility.post(
                element: incoming,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: name,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    /// The AppKit steps of a switch, each run through `perform`.
    enum SwapStep { case add, select, orderOut }

    /// Adds `incoming`, still ordered out, to `group`, selects `target`, then orders the
    /// group's other old windows out, with animation off. Adding and selecting are all or
    /// nothing: if either fails, the added windows are ordered out again, the old selection
    /// comes back, and this returns nil. Otherwise it returns the old windows that ordered
    /// out; one that failed stays in the group.
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

        // Everything else old is unselected now, so ordering it out reveals nothing.
        return old.filter { window in window !== target && perform(.orderOut) { window.orderOut(nil) } }
    }

    /// Makes `group` hold `windows` in their order, with `target`, one of them, selected
    /// (SPEC §10.6). `target` joins if it's out and is selected, all or nothing, as in `swap`,
    /// which orders every other window out; then the rest of `windows` join around it, with
    /// animation off. False, with nothing changed, if `target` couldn't join or be selected.
    /// A window that fails to order out stays in the group, and one that fails to join stays
    /// out.
    static func regroup(
        _ group: NSWindowTabGroup,
        holding windows: [NSWindow],
        selecting target: NSWindow,
        makeKey: Bool,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> Bool {
        let adding = group.windows.contains(target) ? [] : [target]
        guard swap(in: group, adding: adding, selecting: target, makeKey: makeKey, perform: perform) != nil else {
            return false
        }

        withoutAnimation {
            var position = 0
            for window in windows {
                if let index = group.windows.firstIndex(of: window) {
                    position = index + 1
                } else if perform(.add, { group.insertWindow(window, at: position) }) {
                    position += 1
                }
            }
        }
        return true
    }

    /// The AppKit steps of re-forming an emptied group, or of opening a new Window, each run
    /// through `perform`, with animation off: `remembered` takes `frame` and comes on screen
    /// just below `joined` without taking key, or, with no `joined`, as the key window. Then
    /// the rest of `windows`, still ordered out, join its group in their order. Returns that
    /// group and the windows that failed to join, or nil if `remembered` couldn't come on
    /// screen.
    static func reform(
        _ windows: [NSWindow],
        around remembered: NSWindow,
        frame: NSRect?,
        below joined: NSWindow?,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> (group: NSWindowTabGroup, failed: [NSWindow])? {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }

        if let frame { remembered.setFrame(frame, display: false) }

        // Under "Prefer tabs: Always", AppKit would tab it into the key Window instead.
        let tabbingMode = remembered.tabbingMode
        remembered.tabbingMode = .disallowed
        let ordered = perform(.select) {
            if let joined {
                remembered.order(.below, relativeTo: joined.windowNumber)
            } else {
                remembered.makeKeyAndOrderFront(nil)
            }
        }
        remembered.tabbingMode = tabbingMode
        guard ordered, let group = remembered.tabGroup else { return nil }

        var placed = 0
        var failed: [NSWindow] = []
        for window in windows {
            if window === remembered || perform(.add, { group.insertWindow(window, at: placed) }) {
                placed += 1
            } else {
                failed.append(window)
            }
        }
        return (group, failed)
    }

    /// Shows Workspace `id` after the shown Workspace's last Tab left for another Window and
    /// emptied the group (SPEC §2.3). The shown Workspace ends, and a swipe in progress is
    /// cancelled (§6.3). `joined` is the Tab that left; its Window keeps key. Every Tab keeps
    /// this store, but the new group gives AppleScript a new `window id` (§18.2).
    private func reform(showing id: Workspace.ID, below joined: NSWindow) {
        guard let target = workspaces.firstIndex(where: { $0.id == id }),
              let remembered = (workspaces[target].rememberedTab ?? workspaces[target].hiddenTabs.first)?.window,
              let reformed = Self.reform(
                  workspaces[target].hiddenTabs.compactMap(\.window),
                  around: remembered,
                  frame: shownFrame,
                  below: joined.tabGroup?.selectedWindow ?? joined)
        else { return }
        cancelSwipe()

        let ended = shownID
        workspaces[target].hiddenTabs = []
        workspaces[target].rememberedTab = nil
        markShown(id)
        shownID = id
        workspaces.removeAll { $0.id == ended }

        // A Tab that failed to join stays hidden in a Workspace of its own, so it isn't lost.
        let failed = reformed.failed.compactMap { $0.windowController as? TerminalController }
        if !failed.isEmpty { _ = addWorkspace(holding: failed) }

        bind(reformed.group)
        knownShownTabs = Self.tabs(in: reformed.group).map { Weak($0) }

        let tab = remembered.windowController as? TerminalController
        if let surface = tab?.focusedSurface { Ghostty.moveFocus(to: surface) }
        tab?.relabelTabs()
    }

    /// Takes `window` out of `group`, detaching it and ordering it out in one step with
    /// animation off (SPEC §11.7). A selected `window` hands the selection to its right
    /// neighbor, else its left, first, so ordering it out reveals nothing; `makeKey` selects
    /// by making that neighbor key. False, with the old selection back, when AppKit throws.
    static func detach(
        _ window: NSWindow,
        from group: NSWindowTabGroup,
        makeKey: Bool,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> Bool {
        func select(_ selected: NSWindow) -> Bool {
            perform(.select) {
                if makeKey { selected.makeKeyAndOrderFront(nil) } else { group.selectedWindow = selected }
            }
        }

        return withoutAnimation {
            let windows = group.windows
            let neighbor = group.selectedWindow === window
                ? windows.firstIndex(of: window).flatMap { neighbor(of: $0, in: windows) }
                : nil
            if let neighbor, !select(neighbor) { return false }

            guard perform(.orderOut, { window.orderOut(nil) }) else {
                if neighbor != nil { _ = select(window) }
                return false
            }
            return true
        }
    }

    /// Inserts `incoming`, still ordered out, into `group` around `window`: the first `leading`
    /// of them (all by default) in front of it and the rest right after it, keeping the
    /// selection, with animation off. All or nothing: if one fails, the added ones are ordered
    /// out again and this returns false.
    static func insert(
        _ incoming: [NSWindow],
        around window: NSWindow,
        leading: Int? = nil,
        in group: NSWindowTabGroup,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> Bool {
        withoutAnimation {
            let start = group.windows.firstIndex(of: window) ?? 0
            let leading = leading ?? incoming.count
            let inserted = incoming.enumerated().allSatisfy { offset, added in
                perform(.add) { group.insertWindow(added, at: start + offset + (offset < leading ? 0 : 1)) }
            }
            guard inserted else {
                for added in incoming where group.windows.contains(added) {
                    _ = perform(.orderOut) { added.orderOut(nil) }
                }
                return false
            }
            return true
        }
    }

    private static func withoutAnimation<T>(_ body: () -> T) -> T {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        return body()
    }

    // MARK: Moving Workspaces

    /// Move Workspace to New Window (SPEC §12.2): Workspace `id` leaves for a new Window of
    /// its own, with its id, name, original name, color, Tabs and Splits, and remembered Tab.
    /// `tab` is the Tab of the request's target Split. Moving the shown Workspace first shows
    /// its neighbor; moving a hidden one leaves the view as it is. No undo.
    ///
    /// Reports false, with nothing moved, when it's the Window's only Workspace; in
    /// non-native fullscreen, with "Cannot Move Workspace" unless `tab` is hidden (§3, §14);
    /// and for the shown Workspace while the shown Tab has a sheet, which comes forward
    /// (§13.7).
    @discardableResult
    func moveToNewWindow(_ id: Workspace.ID, requestedBy tab: TerminalController) -> Bool {
        reconcile()
        guard workspaces.count > 1, workspaces.contains(where: { $0.id == id }),
              !refusesInFullscreen(tab, showing: isHidden(tab) ? nil : .cannotMoveWorkspace)
        else { return false }

        let source = shownTab?.window
        if id == shownID {
            if let source, source.attachedSheet != nil {
                Self.bringForward(source)
                return false
            }
            guard let neighbor = neighborID, show(neighbor) else { return false }
        }

        // A switch whose old Tabs all failed to order out keeps them shown.
        guard id != shownID,
              let index = workspaces.firstIndex(where: { $0.id == id }),
              Self.openWindow(holding: workspaces[index], sizedLike: source)
        else { return false }

        workspaces.remove(at: index)
        invalidateRestorableState()
        return true
    }

    /// `move_tab_to_new_window` aimed at a hidden Split (SPEC §11.5, §14): the Tab opens by
    /// Move Workspace to New Window's path, as a Window holding one Workspace, "Workspace 1".
    /// Its Workspace ends quietly if it was the last Tab, and its Undo Move Tab comes off the
    /// stack, since it left the Window alone (§11.4). Refused silently (false) for a shown
    /// Tab and in non-native fullscreen.
    func moveHiddenTabToNewWindow(_ tab: TerminalController) -> Bool {
        reconcile()
        guard isHidden(tab), !isInNonNativeFullscreen,
              Self.openWindow(
                  holding: Workspace(name: Self.newName(in: []), hiddenTabs: [tab]),
                  sizedLike: shownTab?.window)
        else { return false }

        Self.dropUndoMoveTab(of: tab)
        removeHiddenTab(tab)
        return true
    }

    /// Merge All Windows (SPEC §12.1), picked in `tab`'s Window: every other Window that can
    /// join hands over all its Workspaces, Window by Window from front to back, each Window's
    /// in their own order. They arrive hidden at the end, with their id, name, original name,
    /// color, Tabs and Splits, and remembered Tab, and their Tabs take this Window's store.
    /// This Window keeps showing what it shows, and the other Windows go away. No undo.
    ///
    /// Reports false, with nothing merged, in non-native fullscreen, with "Cannot Merge
    /// Windows" (§3), and when no Window can join.
    @discardableResult
    func mergeAllWindows(requestedBy tab: TerminalController) -> Bool {
        reconcile()
        guard !refusesInFullscreen(tab, showing: .cannotMergeWindows) else { return false }
        let joining = windowsJoiningMerge
        guard !joining.isEmpty else { return false }

        for store in joining {
            let arriving = store.handOver()
            for tab in arriving.flatMap(\.hiddenTabs) { tab.workspaceStore = self }
            workspaces += arriving
        }
        invalidateRestorableState()
        return true
    }

    /// The other Windows a merge into this one takes, front to back: each that can hold Tabs,
    /// unless it's in non-native fullscreen or its shown Tab has a sheet (§3, §13.7). The
    /// Quick Terminal is never one of them.
    var windowsJoiningMerge: [WorkspaceStore] {
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(self)]
        return NSApp.orderedWindows.compactMap { window in
            // A hidden Tab's place in the order says nothing about its Window's.
            guard let tab = window.windowController as? TerminalController,
                  !tab.isInHiddenWorkspace,
                  seen.insert(ObjectIdentifier(tab.workspaceStore)).inserted
            else { return nil }

            let store = tab.workspaceStore
            store.reconcile()
            guard let shown = store.shownTab,
                  shown.workspacesUnavailableAlert == nil,
                  !store.isInNonNativeFullscreen,
                  shown.window?.attachedSheet == nil
            else { return nil }
            return store
        }
    }

    /// Hands this Window's Workspaces to a merge into another Window (SPEC §12.1), in bar
    /// order and all hidden: the shown Workspace's Tabs order out, and it remembers the
    /// selected one. The store is left with one empty Workspace, so the Window goes away. A
    /// Tab that failed to order out stays in it and keeps the Window open.
    private func handOver() -> [Workspace] {
        guard let group = tabGroup else { return [] }
        invalidateRestorableState()

        let selected = group.selectedWindow
        isChanging = true
        let tabs = Self.orderOut(group).compactMap { $0.windowController as? TerminalController }
        isChanging = false

        // A switcher open in an outgoing Tab closes (SPEC §8.1).
        for tab in tabs { tab.workspaceSwitcherIsShowing = false }

        var handed = workspaces
        handed[shownIndex].hiddenTabs = tabs
        handed[shownIndex].rememberedTab = tabs.first { $0.window === selected } ?? tabs.first

        let left = Workspace(name: handed[shownIndex].name)
        workspaces = [left]
        shownID = left.id
        // Only the Tabs that stayed: AppKit sometimes still lists a lone ordered-out window in
        // its group, and this store would drop that Tab's Undo Move Tab, which follows it.
        knownShownTabs = Self.tabs(in: group).filter { tab in !tabs.contains { $0 === tab } }.map { Weak($0) }
        dropOrganizeUndoIfTabsChanged() // its Tabs left the Window
        return handed.filter { !$0.hiddenTabs.isEmpty }
    }

    /// Orders out every window of `group`, the selected one last so none is revealed, with
    /// animation off. Returns the ones that ordered out, in their tab order; one that failed
    /// stays in the group.
    static func orderOut(
        _ group: NSWindowTabGroup,
        perform: (SwapStep, () -> Void) -> Bool = performSafely
    ) -> [NSWindow] {
        let windows = group.windows
        let selected = group.selectedWindow
        let orderedOut = withoutAnimation {
            (windows.filter { $0 !== selected } + windows.filter { $0 === selected }).filter { window in
                perform(.orderOut) { window.orderOut(nil) }
            }
        }
        return windows.filter(orderedOut.contains)
    }

    /// Opens a new Window showing `workspace`, whose Tabs are ordered out, and gives it a
    /// store of its own. The Window takes `source`'s size and is placed as Cmd+N places one,
    /// or gets its own native fullscreen Space when `source` is in one. It becomes key, with
    /// the remembered Tab selected and focused. False, with nothing changed, if the
    /// remembered Tab couldn't come on screen.
    private static func openWindow(holding workspace: Workspace, sizedLike source: NSWindow?) -> Bool {
        guard let remembered = workspace.rememberedTab ?? workspace.hiddenTabs.first,
              let window = remembered.window
        else { return false }

        let isFullscreen = source?.styleMask.contains(.fullScreen) ?? false
        if !isFullscreen {
            if let size = source?.frame.size {
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            }
            remembered.placeAsNewWindow()
        }

        // Its becoming key mustn't make its store reconcile a half-done move.
        let owner = remembered.workspaceStore
        owner.isChanging = true
        let reformed = reform(workspace.hiddenTabs.compactMap(\.window), around: window, frame: nil, below: nil)
        owner.isChanging = false
        guard let reformed else { return false }

        var shown = workspace
        shown.hiddenTabs = []
        shown.rememberedTab = nil
        let store = WorkspaceStore(workspaces: [shown], shownID: shown.id)
        for tab in workspace.hiddenTabs { tab.workspaceStore = store }

        // A Tab that failed to join stays hidden in a Workspace of its own, so it isn't lost.
        let failed = reformed.failed.compactMap { $0.windowController as? TerminalController }
        if !failed.isEmpty { _ = store.addWorkspace(holding: failed) }

        store.bind(reformed.group)
        store.knownShownTabs = Self.tabs(in: reformed.group).map { Weak($0) }
        store.invalidateRestorableState()

        if isFullscreen, !window.styleMask.contains(.fullScreen) { remembered.toggleFullscreen(mode: .native) }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if let surface = remembered.focusedSurface { Ghostty.moveFocus(to: surface) }
        remembered.relabelTabs()
        return true
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

    // MARK: Swiping

    /// What a Tab's scroll-wheel monitor does with a scroll event in its window.
    enum SwipeEventAction: Equatable {
        case pass
        /// Keep it from the terminal and the Tab list.
        case drop
        /// Claim the gesture: `trackSwipe` this event, then let it through.
        case track
    }

    private enum SwipeGesture { case none, undecided, passed, tracking, dropping }

    /// A swipe's progress, measured from the shown Workspace. Negative `amount` is fingers
    /// moving left, toward the next Workspace; its size is the share of the bar's width the
    /// pages have moved. `neighbor` is the Workspace whose page comes in beside the shown
    /// one: nil at rest and past the first or last Workspace, where the page rubber-bands.
    struct SwipeProgress: Equatable {
        var amount: CGFloat = 0
        var neighbor: Workspace.ID?
    }

    /// A claimed swipe. Its targets are fixed by id when it starts: nil past the first or
    /// last Workspace, since a swipe never wraps (SPEC §6.3).
    struct Swipe: Equatable {
        let generation: Int
        let previous: Workspace.ID?
        let next: Workspace.ID?

        /// Negative `swipe` is fingers moving left, which brings in the next Workspace.
        func target(_ swipe: CGFloat) -> Workspace.ID? {
            swipe < 0 ? next : swipe > 0 ? previous : nil
        }
    }

    /// Decides a scroll event in one of the Window's Tabs (SPEC §6.1, §6.2). A gesture whose
    /// first movement is mostly horizontal, beginning where `startsSwipe` holds, is a swipe;
    /// anything else passes untouched. A claimed gesture's own events pass, because AppKit's
    /// tracker takes them and starves if they're swallowed. Its momentum is dropped.
    func swipeAction(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        deltaX: CGFloat,
        deltaY: CGFloat,
        startsSwipe: @autoclosure () -> Bool
    ) -> SwipeEventAction {
        // Momentum has no phase and belongs to the gesture that flicked it.
        if phase.isEmpty {
            guard dropsSwipeMomentum, !momentumPhase.isEmpty else { return .pass }
            if !momentumPhase.isDisjoint(with: [.ended, .cancelled]) { dropsSwipeMomentum = false }
            return .drop
        }

        if phase.contains(.mayBegin) { return .pass }
        if phase.contains(.began) {
            dropsSwipeMomentum = false
            swipeGesture = startsSwipe() ? .undecided : .passed
        }

        let gesture = swipeGesture
        let ends = !phase.isDisjoint(with: [.ended, .cancelled])
        if ends { swipeGesture = .none }

        switch gesture {
        case .none, .passed:
            return .pass
        case .tracking, .dropping:
            if ends { dropsSwipeMomentum = true }
            return gesture == .tracking ? .pass : .drop
        case .undecided:
            guard !ends, deltaX != 0 || deltaY != 0 else { return .pass }
            guard abs(deltaX) > abs(deltaY) else {
                swipeGesture = .passed
                return .pass
            }
            swipeGesture = .tracking
            return .track
        }
    }

    /// Tracks the swipe `swipeAction` claimed on `event` (SPEC §6.2). AppKit dampens it past
    /// a side with no neighbor, where it never completes.
    func trackSwipe(_ event: NSEvent) {
        let swipe = claimSwipe()
        // The amount has the sign of scrollingDeltaX, which Natural scrolling inverts. Flip it
        // so fingers moving left bring in the next Workspace either way.
        let flip: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let toPrevious: CGFloat = swipe.previous == nil ? 0 : 1
        let toNext: CGFloat = swipe.next == nil ? 0 : 1
        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: flip > 0 ? -toNext : -toPrevious,
            max: flip > 0 ? toPrevious : toNext
        ) { [weak self] amount, phase, isComplete, stop in
            MainActor.assumeIsolated {
                guard let self, self.stepSwipe(swipe, amount: amount * flip, phase: phase, isComplete: isComplete) else {
                    stop.pointee = true
                    return
                }
            }
        }
    }

    /// Starts a swipe from the shown Workspace. One still settling stops, so the new one
    /// counts from the Workspace shown now.
    func claimSwipe() -> Swipe {
        swipeGeneration += 1
        swipeSwitch = nil
        swipeProgress = SwipeProgress()
        let index = shownIndex
        return Swipe(
            generation: swipeGeneration,
            previous: index > 0 ? workspaces[index - 1].id : nil,
            next: index + 1 < workspaces.count ? workspaces[index + 1].id : nil)
    }

    /// One step of tracking `swipe`, with the amount flipped to follow the fingers. At the
    /// lift (the Ended phase), a swipe AppKit will finish switches through the one switch
    /// path, and the rest of the settle counts from the Workspace it switched to. Returns
    /// false to stop tracking: the swipe was cancelled, or is cancelled now because its
    /// target ended or a sheet appeared, which would refuse the switch.
    func stepSwipe(_ swipe: Swipe, amount: CGFloat, phase: NSEvent.Phase, isComplete: Bool = false) -> Bool {
        guard swipe.generation == swipeGeneration else { return false }

        // In case AppKit's tracker took the gesture's last event before the monitor saw it.
        if !phase.isDisjoint(with: [.ended, .cancelled]) { dropsSwipeMomentum = true }

        if let swipeSwitch {
            swipeProgress = isComplete
                ? SwipeProgress()
                : SwipeProgress(amount: amount + swipeSwitch.rebase, neighbor: swipeSwitch.from)
            return true
        }

        let target = swipe.target(amount)
        if let target, !workspaces.contains(where: { $0.id == target }) || shownTab?.window?.attachedSheet != nil {
            cancelSwipe()
            return false
        }

        if phase.contains(.ended), let target {
            let from = shownID
            guard show(target, bySwipe: true) else {
                cancelSwipe()
                return false
            }
            // -0.4 toward the next Workspace is +0.6 from it, so the settle slides on.
            let rebase: CGFloat = amount < 0 ? 1 : -1
            swipeSwitch = (rebase, from)
            swipeProgress = SwipeProgress(amount: amount + rebase, neighbor: from)
            return true
        }

        swipeProgress = isComplete ? SwipeProgress() : SwipeProgress(amount: amount, neighbor: target)
        return true
    }

    /// Cancels a swipe in progress (SPEC §6.3): nothing switches, the rest of its gesture
    /// and its momentum are dropped, and the bar shows the shown Workspace's page at once.
    private func cancelSwipe() {
        swipeGeneration += 1
        swipeSwitch = nil
        if swipeGesture == .tracking { swipeGesture = .dropping }
        guard swipeProgress != SwipeProgress() else { return }
        swipeProgress = SwipeProgress()
        swipeCancels += 1
    }

    // MARK: Membership

    /// Brings membership in line with the tab group (SPEC §2.2). Every Tab in the group
    /// belongs to this store, so one that Cmd+T, AppKit, or the bar added adopts it and joins
    /// the shown Workspace. A shown Tab that left for another Window's group adopts that
    /// Window's store. One that left alone (torn off, Move Tab to New Window) is a new Window
    /// and gets a new store. Entering or leaving non-native fullscreen is neither: the
    /// fullscreen Tab stays shown and keeps its store, whichever group it lands in.
    ///
    /// When the shown Workspace's last Tab left for another Window, the Workspace ends and
    /// the Window re-forms around its neighbor (SPEC §11.5); with no neighbor it's gone.
    ///
    /// Commands call this before touching the group, and so do KVO on the group and the
    /// Window becoming key.
    func reconcile() {
        guard !isChanging else { return }
        isChanging = true
        defer { isChanging = false }

        let group = currentGroup()
        if let group, group !== tabGroup { bind(group) }
        recordShownFrame()

        let grouped = group.map(Self.tabs(in:)) ?? []
        var changed = false
        for tab in grouped where tab.workspaceStore !== self {
            tab.workspaceStore = self
            changed = true
        }

        var shown = grouped
        var joined: NSWindow? // a Tab that left for another Window
        for tab in knownShownTabs.compactMap(\.value) where !grouped.contains(where: { $0 === tab }) {
            // Hidden by a switch.
            guard !isHidden(tab), let window = tab.window else { continue }

            // Adopted by another Window already.
            guard tab.workspaceStore === self else {
                Self.dropUndoMoveTab(of: tab)
                joined = window
                continue
            }

            if tab.isInNonNativeFullscreen {
                shown.append(tab)
                continue
            }
            guard window.isVisible else { continue } // closed

            changed = true
            Self.dropUndoMoveTab(of: tab)
            let others = (window.tabGroup.map(Self.tabs(in:)) ?? []).filter { $0 !== tab }
            let owner: WorkspaceStore
            if let other = others.first {
                owner = others.first { $0.workspaceStore.tabGroup === window.tabGroup }?.workspaceStore
                    ?? other.workspaceStore
                joined = window
            } else {
                owner = WorkspaceStore(tab: tab)
            }
            tab.workspaceStore = owner
            owner.reconcile()
            owner.invalidateRestorableState()
        }

        knownShownTabs = shown.map { Weak($0) }

        if shown.isEmpty, let joined, let neighbor = neighborID {
            reform(showing: neighbor, below: joined)
            changed = true
        }

        if changed { invalidateRestorableState() }
        dropOrganizeUndoIfTabsChanged() // a Tab Cmd+T added or one that closed changes nothing above
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
        dropOrganizeUndoIfTabsChanged()
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
