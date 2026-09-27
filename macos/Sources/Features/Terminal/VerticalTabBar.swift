import AppKit
import Combine
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Position

/// Where terminal windows draw their tab bar. `top` is the native AppKit tab bar;
/// `left` and `right` hide it and draw a vertical tab bar beside the terminal.
enum TabBarPosition: String, CaseIterable {
    case top
    case left
    case right

    var isVertical: Bool { self != .top }

    var title: String {
        switch self {
        case .top: "Top"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// App-wide tab bar layout. Like float on top, this is window chrome changed at
/// runtime from menus, so it persists in user defaults instead of the Ghostty
/// config. Every terminal window follows it so the tabs of a group never disagree.
final class TabBarSettings: ObservableObject {
    static let shared = TabBarSettings()

    @Published var position: TabBarPosition {
        didSet { UserDefaults.ghostty.set(position.rawValue, forKey: Self.positionKey) }
    }

    /// A collapsed vertical tab bar only shows tab numbers.
    @Published var isCollapsed: Bool {
        didSet { UserDefaults.ghostty.set(isCollapsed, forKey: Self.collapsedKey) }
    }

    /// The width of an expanded vertical tab bar, set by dragging its inner edge.
    @Published var expandedWidth: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(expandedWidth), forKey: Self.expandedWidthKey) }
    }

    /// The widths dragging can give an expanded vertical tab bar.
    static let expandedWidthRange: ClosedRange<CGFloat> = 120...400

    /// The width a vertical tab bar takes from the window.
    var verticalWidth: CGFloat { isCollapsed ? 44 : expandedWidth }

    private static let positionKey = "TerminalTabBarPosition"
    private static let collapsedKey = "TerminalTabBarCollapsed"
    private static let expandedWidthKey = "TerminalTabBarWidth"

    private init() {
        let defaults = UserDefaults.ghostty
        // Left by default so the Workspace dots show; a stored position wins.
        position = defaults.string(forKey: Self.positionKey)
            .flatMap(TabBarPosition.init(rawValue:)) ?? .left
        isCollapsed = defaults.bool(forKey: Self.collapsedKey)
        let width = CGFloat(defaults.double(forKey: Self.expandedWidthKey))
        let range = Self.expandedWidthRange
        expandedWidth = width > 0 ? min(max(width, range.lowerBound), range.upperBound) : 200
    }
}

// MARK: - Model

/// The tabs of the native tab group a terminal window belongs to.
///
/// Tabs stay native AppKit tabs (one window per tab); this only draws them
/// vertically. Every window in a group owns a model and a bar, and since only the
/// selected window is visible they read as one tab bar. A model observes nothing
/// until its bar appears, so the native top tab bar costs nothing extra.
@MainActor
final class VerticalTabBarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let color: TerminalTabColor
        /// The most urgent agent status in the tab, and when it last changed.
        let status: Ghostty.AgentStatus?
        let statusDate: Date
        /// The `goto_tab` keybind for this position, if any.
        let shortcut: String?
        /// The Tab group the Tab is in.
        let group: TabGroup?
        let isSelected: Bool
    }

    /// A Workspace of the Window, drawn as a dot at the foot of the bar.
    struct Workspace: Identifiable, Equatable {
        let id: WorkspaceStore.Workspace.ID
        let name: String
        let color: WorkspaceColor
        let isShown: Bool
        /// The Workspace's agent status roll-up, and its date. The shown Workspace's capsule
        /// hides it, and its ring fades in as the mark gives up its share of the capsule, so
        /// a swipe or switch shows no pop.
        let status: Ghostty.AgentStatus?
        let statusDate: Date
    }

    /// The bar as it looks with a Workspace shown: its name header, its Tabs, and the
    /// terminal background the bar takes on behind them.
    struct Page: Equatable {
        let workspace: Workspace
        let tabs: [Tab]
        let backgroundColor: NSColor?
    }

    /// One of the bar's Tab rows, with its index among its Workspace's Tabs.
    struct Row: Identifiable, Equatable {
        let index: Int
        let tab: Tab
        var id: Tab.ID { tab.id }
    }

    /// A run of the bar's rows: one ungrouped Tab, or a Tab group's header and the Tabs it lists.
    struct Section: Identifiable {
        enum ID: Hashable {
            case tab(Tab.ID)
            /// A group split in two runs, which the next refresh mends, has a section for each.
            case group(TabGroup.ID, run: Int)
        }

        let id: ID
        /// The run's group, as its first Tab carries it. Nil for an ungrouped Tab.
        let group: TabGroup?
        /// The Tabs it lists. A collapsed group lists only the Shown Tab, when it's one of its own.
        let rows: [Row]
        /// How many Tabs the run holds, listed or not.
        let count: Int
        /// The agent status of the Tabs it doesn't list, and its date, for a collapsed header.
        let status: Ghostty.AgentStatus?
        let statusDate: Date
    }

    @Published private(set) var tabs: [Tab] = []

    /// The Window's Workspaces in bar order. Empty when the Window can't hold them (it's
    /// undecorated, has a hidden titlebar, or is the Quick Terminal), so the bar draws no dots.
    @Published private(set) var workspaces: [Workspace] = []

    /// The tab being renamed inline.
    @Published private(set) var renamingTab: Tab.ID?

    /// The Workspace whose name the header is editing.
    @Published private(set) var renamingWorkspace: Workspace.ID?

    /// The shown Workspace while the customizer is open on it. A switch closes it.
    @Published private(set) var customizing: Workspace.ID?

    /// The Tab group the editor is open on.
    @Published private(set) var editingGroup: TabGroup.ID?

    /// The swipe's progress from the shown Workspace (`WorkspaceStore.SwipeProgress`), and
    /// the page it brings in beside the shown one: nil at rest and past an end.
    @Published private(set) var swipeAmount: CGFloat = 0
    @Published private(set) var neighborPage: Page?

    /// Follows `WorkspaceStore.swipeCancels`, so the dots morph back on a cancel.
    @Published private(set) var swipeCancels = 0

    /// The bar takes the terminal's background and title font so it blends into
    /// the window. The owning window sets these when its appearance changes.
    @Published var backgroundColor: NSColor?
    @Published var titleFont: NSFont?

    private weak var window: NSWindow?
    private var tabWindows: [Tab.ID: Weak<NSWindow>] = [:]
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservations: [NSKeyValueObservation] = []
    private weak var observedStore: WorkspaceStore?
    private var storeObservation: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false

    /// Bars currently showing this model. Moving the bar to the other side shows the
    /// new bar before the old one disappears, so appearances are counted.
    private var visibleBars = 0

    init(window: NSWindow) {
        self.window = window
    }

    /// The font for tab titles: the window title font at bar size.
    var tabTitleFont: Font {
        guard let titleFont, let font = NSFont(descriptor: titleFont.fontDescriptor, size: 12.5) else {
            return .system(size: 12.5)
        }
        return Font(font as CTFont)
    }

    // MARK: Observation

    func activate() {
        visibleBars += 1
        guard visibleBars == 1 else { return }

        // Titles, colors, selection, and keybinds all show up in the bar.
        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: TerminalWindow.tabDidChangeNotification),
            center.publisher(for: NSWindow.didBecomeKeyNotification),
            center.publisher(for: .ghosttyConfigDidChange)
        )
        .sink { [weak self] _ in self?.setNeedsRefresh() }
        .store(in: &cancellables)

        refresh()
    }

    func deactivate() {
        visibleBars -= 1
        guard visibleBars == 0 else { return }
        cancellables.removeAll()
        observe(nil)
        observe(store: nil)
    }

    /// Coalesces bursts of changes (e.g. many titles changing) into one rebuild.
    private func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshScheduled = false

            // The bar may have disappeared while this was queued.
            guard !cancellables.isEmpty else { return }
            refresh()
        }
    }

    private func refresh() {
        guard let window else { return }

        // Windows move between tab groups (merging, moving tabs) so follow ours.
        let tabGroup = window.tabGroup
        if tabGroup !== observedTabGroup { observe(tabGroup) }

        var windows = tabGroup?.windows ?? []
        if !windows.contains(window) { windows = [window] }

        // Tabs AppKit or a script moved away from their Tab group leave it, so every group's
        // Tabs sit together.
        let terminalWindows = windows.compactMap { $0 as? TerminalWindow }
        for (tabWindow, group) in zip(terminalWindows, TabGroup.whole(terminalWindows.map(\.group))) {
            tabWindow.group = group
        }
        let selected = tabGroup?.selectedWindow ?? window
        let config = (window.windowController as? BaseTerminalController)?.ghostty.config

        // Keep the first of any duplicate: AppKit's tab state can go wrong, and a
        // duplicate key would crash.
        tabWindows = Dictionary(
            windows.map { (ObjectIdentifier($0), Weak($0)) },
            uniquingKeysWith: { first, _ in first })
        let tabs = Self.tabs(windows, selected: selected, config: config)
        if tabs != self.tabs { self.tabs = tabs }
        if let editingGroup, !tabs.contains(where: { $0.group?.id == editingGroup }) { self.editingGroup = nil }

        // Every Tab's bar follows the Window's store, so a switch also redraws the bar of
        // a Tab that comes in without becoming key.
        let store = workspaceTab?.workspaceStore
        if store !== observedStore { observe(store: store) }
        let workspaces = store.map { store in
            store.workspaces.map { workspace -> Workspace in
                let rollUp = store.agentStatus(of: workspace.id)
                return Workspace(
                    id: workspace.id, name: workspace.name, color: workspace.color,
                    isShown: workspace.id == store.shownID,
                    status: rollUp.status, statusDate: rollUp.since)
            }
        } ?? []
        if workspaces != self.workspaces { self.workspaces = workspaces }
        if let customizing, customizing != store?.shownID { self.customizing = nil }

        // The neighbor is hidden, so its page draws its held Tabs, with the one it
        // remembers selected.
        let progress = store?.swipeProgress ?? WorkspaceStore.SwipeProgress()
        var neighborPage: Page?
        if let neighbor = store?.workspaces.first(where: { $0.id == progress.neighbor }),
           let workspace = workspaces.first(where: { $0.id == neighbor.id }) {
            neighborPage = Page(
                workspace: workspace,
                tabs: Self.tabs(
                    neighbor.hiddenTabs.compactMap(\.window),
                    selected: neighbor.rememberedTab?.window,
                    config: config),
                backgroundColor: (neighbor.rememberedTab?.window as? TerminalWindow)?.preferredBackgroundColor)
        }
        if progress.amount != swipeAmount { swipeAmount = progress.amount }
        if neighborPage != self.neighborPage { self.neighborPage = neighborPage }
        let cancels = store?.swipeCancels ?? 0
        if cancels != swipeCancels { swipeCancels = cancels }
    }

    /// The bar's rows for `windows`, the Tabs of one Workspace in order.
    private static func tabs(_ windows: [NSWindow], selected: NSWindow?, config: Ghostty.Config?) -> [Tab] {
        windows.enumerated().map { index, tabWindow in
            let terminalWindow = tabWindow as? TerminalWindow
            return Tab(
                id: ObjectIdentifier(tabWindow),
                title: tabWindow.title,
                color: terminalWindow?.tabColor ?? .none,
                status: terminalWindow?.agentStatus,
                statusDate: terminalWindow?.agentStatusDate ?? .distantPast,
                shortcut: index < 9
                    ? config?.keyboardShortcut(for: "goto_tab:\(index + 1)")?.description
                    : nil,
                group: terminalWindow?.group,
                isSelected: tabWindow === selected)
        }
    }

    /// The bar's sections for `tabs`, the Tabs of one Workspace in order.
    static func sections(_ tabs: [Tab]) -> [Section] {
        var sections: [Section] = []
        var runs: [TabGroup.ID: Int] = [:]
        var start = 0
        while start < tabs.count {
            let group = tabs[start].group
            var end = start + 1
            if let group {
                while end < tabs.count, tabs[end].group?.id == group.id { end += 1 }
            }
            let rows = (start..<end).map { Row(index: $0, tab: tabs[$0]) }

            if let group {
                let run = runs[group.id, default: 0]
                runs[group.id] = run + 1
                let unlisted = group.isCollapsed ? rows.filter { !$0.tab.isSelected } : []
                let rollUp = WorkspaceStore.agentStatus(of: unlisted.map { ($0.tab.status, $0.tab.statusDate) })
                sections.append(Section(
                    id: .group(group.id, run: run), group: group,
                    rows: group.isCollapsed ? rows.filter(\.tab.isSelected) : rows,
                    count: rows.count, status: rollUp.status, statusDate: rollUp.since))
            } else {
                sections.append(Section(
                    id: .tab(tabs[start].id), group: nil, rows: rows,
                    count: 1, status: nil, statusDate: .distantPast))
            }
            start = end
        }
        return sections
    }

    private func observe(_ tabGroup: NSWindowTabGroup?) {
        observedTabGroup = tabGroup
        tabGroupObservations = []
        guard let tabGroup else { return }

        // KVO fires in the middle of AppKit tab changes, so refresh on a later turn
        // that sees consistent state and never rebinds from inside a callback.
        tabGroupObservations = [
            tabGroup.observe(\.windows) { [weak self] _, _ in
                DispatchQueue.main.async { self?.setNeedsRefresh() }
            },
            tabGroup.observe(\.selectedWindow) { [weak self] _, _ in
                DispatchQueue.main.async { self?.setNeedsRefresh() }
            },
        ]
    }

    private func observe(store: WorkspaceStore?) {
        observedStore = store
        // Fires before the change, and the refresh runs on a later turn that sees it.
        storeObservation = store?.objectWillChange.sink { [weak self] _ in self?.setNeedsRefresh() }
    }

    // MARK: Actions

    private func tabWindow(_ id: Tab.ID) -> NSWindow? {
        tabWindows[id]?.value
    }

    private func controller(_ id: Tab.ID) -> TerminalController? {
        tabWindow(id)?.windowController as? TerminalController
    }

    func select(_ id: Tab.ID) {
        guard let target = tabWindow(id) else { return }
        if target === window {
            focusTerminal()
        } else {
            target.makeKeyAndOrderFront(nil)
        }
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func close(_ id: Tab.ID) {
        guard let controller = controller(id) else { return }

        // Show the tab first if closing it asks for confirmation.
        if controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            controller.window?.makeKeyAndOrderFront(nil)
        }
        controller.closeTab(nil)
    }

    /// Closes every other tab, showing the one that is kept.
    func closeOthers(_ id: Tab.ID) {
        tabWindow(id)?.makeKeyAndOrderFront(nil)
        controller(id)?.closeOtherTabs(nil)
    }

    /// Closes the tabs below this one, showing the one that is kept.
    func closeBelow(_ id: Tab.ID) {
        tabWindow(id)?.makeKeyAndOrderFront(nil)
        controller(id)?.closeTabsOnTheRight(nil)
    }

    /// Move Tab to Workspace ▸: runs `move_tab_to_workspace:N`, or with no number
    /// `move_tab_to_new_workspace`, on the row's Tab, as the Workspace menu does.
    func moveToWorkspace(_ id: Tab.ID, number: Int?) {
        guard let tab = controller(id), let surface = tab.focusedSurface else { return }
        tab.performAction(number.map { "move_tab_to_workspace:\($0)" } ?? "move_tab_to_new_workspace", on: surface)
    }

    func moveToNewWindow(_ id: Tab.ID) {
        tabWindow(id)?.moveTabToNewWindow(nil)
    }

    func setColor(_ color: TerminalTabColor, for id: Tab.ID) {
        (tabWindow(id) as? TerminalWindow)?.tabColor = color
    }

    /// Returns keyboard focus to the terminal after using the bar.
    func focusTerminal() {
        guard let window,
              let surface = (window.windowController as? BaseTerminalController)?.focusedSurface,
              surface.window === window
        else { return }
        window.makeFirstResponder(surface)
    }

    // MARK: Workspaces

    /// This bar's Tab, when its Window holds Workspaces.
    private var workspaceTab: TerminalController? {
        guard let tab = window?.windowController as? TerminalController,
              tab.holdsWorkspaces
        else { return nil }
        return tab
    }

    /// The Window's store, which the customizer edits.
    var workspaceStore: WorkspaceStore? { workspaceTab?.workspaceStore }

    /// Clicking a dot: shows its Workspace, refused as `goto_workspace` is. Clicking the
    /// shown Workspace's capsule does nothing.
    func showWorkspace(_ id: Workspace.ID) {
        guard let tab = workspaceTab else { return }
        let store = tab.workspaceStore
        guard id != store.shownID else { return focusTerminal() }
        guard store.allowsRequest(from: tab, orShow: .cannotSwitch) else { return }
        store.show(id)
    }

    /// "+": runs `new_workspace` on the focused Split, as the keybind does.
    func newWorkspace() {
        guard let tab = workspaceTab, let surface = tab.focusedSurface else { return }
        tab.performAction("new_workspace", on: surface)
    }

    /// Double-clicking the header renames the shown Workspace in place.
    func beginWorkspaceRename() {
        renamingWorkspace = workspaces.first(where: \.isShown)?.id
    }

    func commitWorkspaceRename(_ id: Workspace.ID, name: String) {
        guard renamingWorkspace == id else { return }
        renamingWorkspace = nil
        workspaceTab?.workspaceStore.rename(id, to: name)
        focusTerminal()
    }

    func cancelWorkspaceRename() {
        renamingWorkspace = nil
        focusTerminal()
    }

    // The dot menu aims at its dot's Workspace, shown or hidden.

    /// Rename Workspace…: in the header for the shown Workspace of an expanded bar, else
    /// with the rename prompt.
    func renameWorkspace(_ id: Workspace.ID) {
        guard let store = workspaceTab?.workspaceStore else { return }
        if id == store.shownID && !TabBarSettings.shared.isCollapsed {
            renamingWorkspace = id
        } else {
            _ = store.promptName(for: id)
        }
    }

    /// Customize Workspace…: opens the customizer on Workspace `id`, first showing it if it's
    /// hidden, refused as clicking its dot is. The shown Tab's bar holds the customizer, and
    /// after a switch that's another Tab's.
    func customizeWorkspace(_ id: Workspace.ID) {
        guard let tab = workspaceTab else { return }
        let store = tab.workspaceStore
        if id != store.shownID {
            guard store.allowsRequest(from: tab, orShow: .cannotSwitch), store.show(id) else { return }
        }

        // A popover needs its window on screen, which a switch's incoming Tab is a turn later.
        DispatchQueue.main.async {
            guard store.shownID == id else { return }
            (store.shownTab?.window as? TerminalWindow)?.verticalTabBar.customizing = id
        }
    }

    func endCustomizing() {
        customizing = nil
        focusTerminal()
    }

    func closeWorkspace(_ id: Workspace.ID) {
        guard let tab = workspaceTab else { return }
        _ = tab.workspaceStore.closeWorkspace(id, from: tab)
    }

    func moveWorkspaceToNewWindow(_ id: Workspace.ID) {
        guard let tab = workspaceTab else { return }
        _ = tab.workspaceStore.moveToNewWindow(id, requestedBy: tab)
    }

    /// A dot's drag payload. With no Window to name, it names none that exists, so every
    /// dot refuses it.
    func dragItem(for id: Workspace.ID) -> DraggedWorkspace {
        DraggedWorkspace(window: workspaceTab?.workspaceStore.id ?? UUID(), workspace: id)
    }

    /// Something dropped on the dot of Workspace `target`, or on "+" when `target` is nil.
    /// A dot moves its Workspace to the target's place, and "+" refuses it. A Tab row moves
    /// its Tab to the end of the target, or into a new Workspace on "+", which refuses a
    /// Workspace's only Tab; the capsule takes no Tab. Both payloads from another Window are
    /// refused.
    func drop(_ item: WorkspaceDrop, on target: Workspace.ID?) -> Bool {
        guard let store = workspaceTab?.workspaceStore else { return false }

        switch item {
        case .workspace(let dragged):
            guard dragged.window == store.id,
                  let index = store.workspaces.firstIndex(where: { $0.id == target })
            else { return false }
            return store.moveWorkspace(dragged.workspace, to: index)

        case .tab(let dragged):
            guard target != store.shownID,
                  let tab = draggedWindow(dragged)?.windowController as? TerminalController,
                  tab.workspaceStore === store,
                  // A row's Tab is shown, so in non-native fullscreen its drop would change
                  // the shown Workspace's Tabs, and a drop is refused silently.
                  !store.isInNonNativeFullscreen || store.isHidden(tab)
            else { return false }
            guard let target else { return store.moveTabToNewWorkspace(tab) }
            return store.moveTab(tab, to: target)
        }
    }

    /// The room a dot and "+" each take along the expanded bar's row of dots, and a dot down
    /// the collapsed bar's column.
    static let dotPitch: CGFloat = 14
    static let newWorkspacePitch: CGFloat = 22

    /// The expanded bar's rows of dots: indices of `count` dots, then "+" as index `count`,
    /// broken greedily into rows no wider than `width`. A row breaks before the item that
    /// doesn't fit and is never empty.
    static func dotRows(count: Int, width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for i in 0...count {
            let itemWidth = i == count ? newWorkspacePitch : dotPitch
            if x + itemWidth > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(i)
            x += itemWidth
        }
        return rows
    }

    /// Where a page sits mid-swipe: an x offset in bar widths, and an opacity. The shown page
    /// moves by the swipe's amount, stretching past an end, and the neighbor's comes in beside
    /// it. Under Reduce Motion the pages stay in place and crossfade, and nothing changes past
    /// an end.
    static func pagePlacement(
        amount: CGFloat,
        isNeighbor: Bool,
        hasNeighbor: Bool,
        reduceMotion: Bool
    ) -> (offset: CGFloat, opacity: Double) {
        let t = Double(min(abs(amount), 1))
        if reduceMotion {
            guard hasNeighbor else { return (0, 1) }
            return (0, isNeighbor ? t : 1 - t)
        }
        guard isNeighbor else { return (amount, 1) }
        return (amount < 0 ? amount + 1 : amount - 1, 1)
    }

    /// How much of the capsule Workspace `id`'s mark holds. Mid-swipe the shown mark hands the
    /// neighbor's the swipe's share. A rubber band, and Reduce Motion, leave it whole on the
    /// shown mark until the switch.
    static func capsuleShare(
        of id: Workspace.ID,
        shown: Workspace.ID?,
        neighbor: Workspace.ID?,
        amount: CGFloat,
        reduceMotion: Bool
    ) -> CGFloat {
        let t = neighbor == nil || reduceMotion ? 0 : min(abs(amount), 1)
        if id == shown { return 1 - t }
        return id == neighbor ? t : 0
    }

    /// A mark holding `share` of the capsule: its long side, from the 6 pt dot to the 12 pt
    /// capsule, and its status ring's opacity, which fades as it becomes the capsule.
    static func mark(share: CGFloat) -> (length: CGFloat, ringOpacity: Double) {
        (6 + 6 * share, Double(1 - share))
    }

    // MARK: Renaming

    /// Starts renaming `target` inline. Fails if the bar can't show an editor for it.
    func beginRename(_ target: NSWindow) -> Bool {
        let id = ObjectIdentifier(target)
        guard !TabBarSettings.shared.isCollapsed, tabWindows[id] != nil else { return false }
        renamingTab = id
        return true
    }

    /// Renames inline when possible, otherwise with the title prompt.
    func rename(_ id: Tab.ID) {
        guard let target = tabWindow(id), !beginRename(target) else { return }
        target.makeKeyAndOrderFront(nil)
        (target.windowController as? BaseTerminalController)?.promptTabTitle()
    }

    func renameTitle(for id: Tab.ID) -> String {
        guard let target = tabWindow(id) else { return "" }
        return (target.windowController as? BaseTerminalController)?.titleOverride ?? target.title
    }

    func commitRename(_ id: Tab.ID, title: String) {
        guard renamingTab == id else { return }
        renamingTab = nil
        (tabWindow(id)?.windowController as? BaseTerminalController)?.titleOverride = title.isEmpty ? nil : title
        focusTerminal()
    }

    func cancelRename() {
        renamingTab = nil
        focusTerminal()
    }

    // MARK: Tab groups

    /// The Tab groups in the bar, in order.
    var groups: [TabGroup] {
        var seen = Set<TabGroup.ID>()
        return tabs.compactMap(\.group).filter { seen.insert($0.id).inserted }
    }

    /// Tab group `id` as the bar shows it.
    func group(_ id: TabGroup.ID) -> TabGroup? {
        groups.first { $0.id == id }
    }

    /// The bar's Tabs in order as AppKit holds them now. Group commands read these, which a
    /// refresh still waiting for its turn can't leave behind.
    private var liveWindows: [NSWindow] {
        guard let window else { return [] }
        let windows = window.tabGroup?.windows ?? []
        return windows.contains(window) ? windows : [window]
    }

    /// Add Tab to New Group: the Tab starts a group of its own, in a color no other group in
    /// the bar has, and the editor opens on it, as Chrome's does.
    func addToNewGroup(_ id: Tab.ID) {
        guard let tabWindow = tabWindow(id) as? TerminalWindow else { return }
        if tabWindow.group != nil { removeFromGroup(id) }
        let group = TabGroup(
            id: UUID(), name: "", color: TabGroup.color(avoiding: groups.map(\.color)), isCollapsed: false)
        tabWindow.group = group
        // A turn later, once the refresh this schedules has drawn the group's header.
        DispatchQueue.main.async { [weak self] in self?.editingGroup = group.id }
    }

    /// Add Tab to Group ▸: the Tab joins group `groupID` at its end.
    func addToGroup(_ id: Tab.ID, _ groupID: TabGroup.ID) {
        _ = join(dragItem(for: id), groupID)
    }

    /// A Tab row dropped on group `id`'s header joins the group at its end.
    func drop(_ tab: DraggedTab, intoGroup id: TabGroup.ID) -> Bool {
        join(tab, id)
    }

    /// Moves the dragged Tab, from this bar or another Window's, to the end of group `groupID`
    /// unless it's there already, and puts it in the group.
    private func join(_ tab: DraggedTab, _ groupID: TabGroup.ID) -> Bool {
        let windows = liveWindows
        guard let dragged = draggedWindow(tab) as? TerminalWindow,
              dragged.group?.id != groupID,
              let last = windows.lastIndex(where: { ($0 as? TerminalWindow)?.group?.id == groupID }),
              let group = (windows[last] as? TerminalWindow)?.group
        else { return false }

        // `moveTab` lands a Tab from above right after the target, and one from below or from
        // another Window right before it.
        let from = windows.firstIndex(of: dragged)
        let index = from.map { $0 < last ? last : last + 1 } ?? last + 1
        guard index == from || moveTab(tab, to: index) else { return false }
        dragged.group = group
        return true
    }

    /// Remove Tab from Group. A Tab from the middle of its group moves out past the group's
    /// end, as Chrome's does, so the group's Tabs still sit together.
    func removeFromGroup(_ id: Tab.ID) {
        let windows = liveWindows
        guard let tabWindow = tabWindow(id) as? TerminalWindow,
              let groupID = tabWindow.group?.id,
              let from = windows.firstIndex(of: tabWindow),
              let last = windows.lastIndex(where: { ($0 as? TerminalWindow)?.group?.id == groupID })
        else { return }

        let inMiddle = from > 0 && from < last && (windows[from - 1] as? TerminalWindow)?.group?.id == groupID
        guard !inMiddle || moveTab(dragItem(for: id), to: last) else { return }
        tabWindow.group = nil
    }

    func ungroup(_ id: TabGroup.ID) {
        for case let member as TerminalWindow in liveWindows where member.group?.id == id {
            member.group = nil
        }
    }

    func toggleCollapsed(_ id: TabGroup.ID) {
        updateGroup(id) { $0.isCollapsed.toggle() }
    }

    func renameGroup(_ id: TabGroup.ID, to name: String) {
        updateGroup(id) { $0.name = name }
    }

    func setGroupColor(_ id: TabGroup.ID, to color: TerminalTabColor) {
        updateGroup(id) { $0.color = color }
    }

    /// Changes group `id` as its first Tab carries it and gives every one of its Tabs the
    /// result, so their copies agree again.
    private func updateGroup(_ id: TabGroup.ID, _ change: (inout TabGroup) -> Void) {
        let members = liveWindows.compactMap { $0 as? TerminalWindow }.filter { $0.group?.id == id }
        guard var group = members.first?.group else { return }
        change(&group)
        for member in members { member.group = group }
    }

    /// Edit Group…: opens the editor on group `id`.
    func editGroup(_ id: TabGroup.ID) {
        editingGroup = id
    }

    func endEditingGroup() {
        editingGroup = nil
        focusTerminal()
    }

    /// New Tab in Group: a Tab opens right after the group's last and joins it.
    func newTab(inGroup id: TabGroup.ID) {
        guard let last = liveWindows.last(where: { ($0 as? TerminalWindow)?.group?.id == id }) as? TerminalWindow,
              let group = last.group,
              let parent = last.windowController as? TerminalController,
              let window = TerminalController.newTab(parent.ghostty, from: last)?.window as? TerminalWindow
        else { return }

        // Under `window-new-tab-position = end` it opened past the group, so it moves up beside it.
        let windows = liveWindows
        if let index = windows.firstIndex(of: window), let lastIndex = windows.firstIndex(of: last), index != lastIndex + 1 {
            _ = moveTab(dragItem(for: ObjectIdentifier(window)), to: lastIndex + 1)
        }
        window.group = group
    }

    /// Close Group: closes the group's Tabs, asking once first when any would. The Shown Tab
    /// stays on screen when it's outside the group; otherwise the Tab after the group, else the
    /// one before, is shown first. A group of every Tab closes as its Workspace does.
    func closeGroup(_ id: TabGroup.ID) {
        let windows = liveWindows
        guard let first = windows.firstIndex(where: { ($0 as? TerminalWindow)?.group?.id == id }),
              let last = windows.lastIndex(where: { ($0 as? TerminalWindow)?.group?.id == id })
        else { return }

        let selected = window?.tabGroup?.selectedWindow
        let outside = windows.filter { ($0 as? TerminalWindow)?.group?.id != id }
        let keeper = outside.first { $0 === selected }
            ?? (windows.indices.contains(last + 1) ? windows[last + 1] : nil)
            ?? (first > 0 ? windows[first - 1] : nil)
        guard let keeper = keeper?.windowController as? TerminalController else {
            guard let tab = windows[first].windowController as? TerminalController else { return }
            _ = tab.workspaceStore.closeWorkspace(tab.workspaceStore.shownID, from: tab)
            return
        }

        if keeper.window !== selected { keeper.window?.makeKeyAndOrderFront(nil) }
        keeper.closeTabs(inGroup: id)
    }

    // MARK: Dragging

    func dragItem(for id: Tab.ID) -> DraggedTab {
        DraggedTab(window: UInt(bitPattern: id))
    }

    private func draggedWindow(_ tab: DraggedTab) -> NSWindow? {
        NSApp.windows.first(where: { UInt(bitPattern: ObjectIdentifier($0)) == tab.window })
    }

    /// Moves the dragged tab to `index` in this window's tab group, taking it out of
    /// another group if it came from a different window.
    func moveTab(_ tab: DraggedTab, to index: Int) -> Bool {
        guard let window, let dragged = draggedWindow(tab) else { return false }

        let windows = window.tabGroup?.windows ?? [window]
        let from = windows.firstIndex(of: dragged)
        guard index >= 0, index <= windows.count, from != index else { return false }

        // Like newTab: a window in non-native fullscreen can't have tabs, so tabs
        // can't move into or out of one.
        func tabsBlocked(_ candidate: NSWindow) -> Bool {
            guard let style = (candidate.windowController as? BaseTerminalController)?.fullscreenStyle else { return false }
            return style.isFullscreen && !style.supportsTabs
        }
        guard !tabsBlocked(window), !tabsBlocked(dragged) else { return false }

        // Nor can a Tab cross into or out of a Window in non-native fullscreen through the
        // windowed group behind its fullscreen Tab.
        func windowInFullscreen(_ candidate: NSWindow) -> Bool {
            (candidate.windowController as? TerminalController)?.workspaceStore.isInNonNativeFullscreen ?? false
        }
        if from == nil, windowInFullscreen(window) || windowInFullscreen(dragged) { return false }

        // Moving down lands after the target so the tab ends up at `index`.
        let target: NSWindow
        let ordered: NSWindow.OrderingMode
        if index < windows.count {
            target = windows[index]
            ordered = (from ?? index) < index ? .above : .below
        } else {
            guard let last = windows.last else { return false }
            target = last
            ordered = .above
        }
        guard target !== dragged else { return false }

        let selected = window.tabGroup?.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        dragged.tabGroup?.removeWindow(dragged)
        let moved = target.addTabbedWindowSafely(dragged, ordered: ordered)

        // Reordering keeps the selected tab. A tab dragged in from elsewhere is shown,
        // and so is one AppKit refused to move, so it isn't left hidden.
        (moved && from != nil ? selected ?? dragged : dragged).makeKeyAndOrderFront(nil)
        NSAnimationContext.endGrouping()
        return moved
    }

    /// A Tab row dropped on the row at `index`, or past the last on "New Tab": it moves there
    /// and takes that row's Tab group, so dropping it on a group's Tab puts it in the group, and
    /// dropping it elsewhere takes it out, unless it's its group's only Tab, which takes the
    /// group along.
    func drop(_ tab: DraggedTab, at index: Int) -> Bool {
        guard let dragged = draggedWindow(tab) as? TerminalWindow else { return false }
        let windows = liveWindows
        let target = windows.indices.contains(index) ? (windows[index] as? TerminalWindow)?.group : nil
        let source = dragged.tabGroup?.windows ?? [dragged]
        let isOnly = source.firstIndex(of: dragged)
            .map { TabGroup.isOnly($0, in: source.map { ($0 as? TerminalWindow)?.group }) } ?? false

        guard moveTab(tab, to: index) else { return false }
        dragged.group = target ?? (isOnly ? dragged.group : nil)
        return true
    }
}

/// A tab dragged in a vertical tab bar. It names its window so it can be dropped into
/// the bar of any window, and has its own type so dropping it on a terminal or another
/// app doesn't paste text.
struct DraggedTab: Codable, Transferable {
    /// The `ObjectIdentifier` bits of the tab's window.
    let window: UInt

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ghosttyTab)
    }

    /// Whether the drag in flight carries a Tab row. `isTargeted` doesn't say what hovers
    /// a drop destination, and the capsule and "+" each refuse one payload.
    static var isDragging: Bool {
        NSPasteboard(name: .drag).types?.contains(.init(UTType.ghosttyTab.identifier)) ?? false
    }
}

extension UTType {
    static let ghosttyTab = UTType(exportedAs: "com.mitchellh.ghosttyTab")
    static let ghosttyWorkspace = UTType(exportedAs: "com.mitchellh.ghosttyWorkspace")
}

/// A Workspace's dot dragged in a vertical tab bar, the twin of `DraggedTab`. It names the
/// Window id and the Workspace id, so a dot only lands among its own Window's dots.
struct DraggedWorkspace: Codable, Transferable {
    let window: UUID
    let workspace: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ghosttyWorkspace)
    }
}

/// What a dot and "+" accept. Chained `.dropDestination`s honor only the first matching
/// type, so each has one destination for this enum, which wraps every payload they take.
enum WorkspaceDrop: Transferable {
    case workspace(DraggedWorkspace)
    case tab(DraggedTab)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (dragged: DraggedWorkspace) in .workspace(dragged) })
        ProxyRepresentation(importing: { (dragged: DraggedTab) in .tab(dragged) })
    }
}

// MARK: - Views

/// Places a vertical tab bar beside the terminal when the tab bar is on a side.
struct VerticalTabBarLayout<Content: View>: View {
    /// Nil for window styles that keep the native tab bar.
    let model: VerticalTabBarModel?
    @ViewBuilder let content: Content

    @ObservedObject private var settings = TabBarSettings.shared

    /// Half the window: a bar never takes more, so it can't crush the terminal.
    @State private var maxBarWidth: CGFloat = .infinity

    var body: some View {
        // The terminal is the same child in every position so moving the bar
        // never rebuilds it.
        HStack(spacing: 0) {
            if let model, settings.position == .left {
                VerticalTabBar(model: model, settings: settings, edge: .leading, maxWidth: maxBarWidth)
            }

            content

            if let model, settings.position == .right {
                VerticalTabBar(model: model, settings: settings, edge: .trailing, maxWidth: maxBarWidth)
            }
        }
        // Measured in the background so the window's default size still comes
        // from the terminal and the bar.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { maxBarWidth = geo.size.width / 2 }
                .onChange(of: geo.size.width) { maxBarWidth = $0 / 2 }
        })
    }
}

private struct VerticalTabBar: View {
    @ObservedObject var model: VerticalTabBarModel
    @ObservedObject var settings: TabBarSettings

    /// The window edge the bar is attached to.
    let edge: HorizontalEdge

    /// The most width the bar may take from the window.
    let maxWidth: CGFloat

    /// How far the inner edge is dragged to the right while resizing. The width
    /// is only stored when the drag ends so other windows don't follow every step.
    @GestureState private var dragOffset: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedTab: VerticalTabBarModel.Tab.ID? {
        model.tabs.first(where: \.isSelected)?.id
    }

    /// The shown Workspace's name, which the collapsed bar leaves out. Mid-swipe the neighbor's
    /// name comes in beside it, as part of its page.
    @ViewBuilder
    private var header: some View {
        if !settings.isCollapsed, let workspace = model.workspaces.first(where: \.isShown) {
            ZStack {
                swipePage(
                    WorkspaceHeader(model: model, settings: settings, workspace: workspace, edge: edge),
                    isNeighbor: false)
                if let neighbor = model.neighborPage {
                    swipePage(
                        WorkspaceHeader(model: model, settings: settings, workspace: neighbor.workspace, edge: edge),
                        isNeighbor: true)
                }
            }
            .clipped()
        }
    }

    /// The Tab rows, Tab groups' under their headers, down to "New Tab": the lower part of a page.
    private func tabList(_ tabs: [VerticalTabBarModel.Tab]) -> some View {
        VStack(spacing: 2) {
            ForEach(VerticalTabBarModel.sections(tabs)) { section in
                if let group = section.group {
                    groupSection(section, group: group)
                } else {
                    rows(section.rows)
                }
            }

            NewTabRow(model: model, collapsed: settings.isCollapsed)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private func rows(_ rows: [VerticalTabBarModel.Row]) -> some View {
        ForEach(rows) { row in
            VerticalTabRow(model: model, settings: settings, tab: row.tab, index: row.index)
                .id(row.tab.id)
        }
    }

    /// A Tab group's header, then the Tabs it lists along a rail of its color.
    private func groupSection(_ section: VerticalTabBarModel.Section, group: TabGroup) -> some View {
        VStack(spacing: 2) {
            TabGroupHeader(model: model, settings: settings, section: section, group: group, edge: edge)

            if !section.rows.isEmpty {
                VStack(spacing: 2) { rows(section.rows) }
                    .padding(.leading, 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color(nsColor: group.color.displayColor ?? .systemGray))
                            .frame(width: 2)
                    }
            }
        }
    }

    /// Places part of a page mid-swipe. The neighbor's page is only drawn: it takes no clicks
    /// and VoiceOver skips it.
    private func swipePage(_ page: some View, isNeighbor: Bool) -> some View {
        let placement = VerticalTabBarModel.pagePlacement(
            amount: model.swipeAmount,
            isNeighbor: isNeighbor,
            hasNeighbor: model.neighborPage != nil,
            reduceMotion: reduceMotion)
        return page
            .offset(x: placement.offset * width)
            .opacity(placement.opacity)
            .allowsHitTesting(!isNeighbor)
            .accessibilityHidden(isNeighbor)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The toggle sits on the outer edge so it stays under the pointer
            // when the bar collapses. The name header takes its inner side.
            HStack(spacing: 4) {
                if edge == .trailing { header }

                IconButton(
                    systemImage: edge == .leading ? "sidebar.left" : "sidebar.right",
                    size: 24,
                    help: settings.isCollapsed ? "Expand Tab Bar" : "Collapse Tab Bar"
                ) {
                    settings.isCollapsed.toggle()
                    model.focusTerminal()
                }

                if edge == .leading { header }
            }
            .frame(
                maxWidth: .infinity,
                alignment: settings.isCollapsed ? .center : edge == .leading ? .leading : .trailing)
            .padding(.horizontal, 6)
            .frame(height: 34)
            // The customizer hangs off the header toward the terminal, as Arc's theme
            // editor hangs off its sidebar.
            .popover(isPresented: isCustomizing, arrowEdge: edge == .leading ? .trailing : .leading) {
                if let store = model.workspaceStore, let id = model.customizing {
                    WorkspaceCustomizer(store: store, id: id)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    swipePage(tabList(model.tabs), isNeighbor: false)
                }
                .onChange(of: selectedTab) { id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            // The neighbor's page comes in from its top, however far the list is scrolled.
            .overlay(alignment: .top) {
                if let neighbor = model.neighborPage {
                    swipePage(tabList(neighbor.tabs).fixedSize(horizontal: false, vertical: true), isNeighbor: true)
                }
            }
            .clipped()

            // Pinned below the list, which scrolls to make room.
            if !model.workspaces.isEmpty {
                WorkspaceDots(model: model, settings: settings, barWidth: width)
            }
        }
        .frame(width: width)
        // No ideal height: the window's default size comes from the terminal, not
        // from how many tabs are open.
        .frame(idealHeight: 0, maxHeight: .infinity)
        .background(backdrop)
        .overlay(alignment: edge == .leading ? .trailing : .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)
        }
        .overlay(alignment: edge == .leading ? .trailing : .leading) {
            if !settings.isCollapsed { resizeHandle }
        }
        .contextMenu { TabBarMenuItems(model: model, settings: settings) }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
    }

    /// The shown Workspace's backdrop. A switch morphs its wash from the old Workspace's
    /// color to the new one's, and mid-swipe the neighbor's backdrop fades in over it.
    private var backdrop: some View {
        let shown = model.workspaces.first(where: \.isShown)
        return ZStack {
            WorkspaceBackdrop(background: model.backgroundColor, wash: shown?.color.displayColor)
                .animation(.easeOut(duration: 0.25), value: shown?.id)

            if let neighbor = model.neighborPage {
                WorkspaceBackdrop(
                    background: neighbor.backgroundColor ?? model.backgroundColor,
                    wash: neighbor.workspace.color.displayColor)
                    .opacity(Double(min(abs(model.swipeAmount), 1)))
            }
        }
    }

    private var isCustomizing: Binding<Bool> {
        Binding(
            get: { model.customizing != nil },
            set: { if !$0 { model.endCustomizing() } })
    }

    private var width: CGFloat {
        dragOffset.map(resized(byDragging:)) ?? min(settings.verticalWidth, maxWidth)
    }

    /// A strip along the inner edge that resizes the bar when dragged.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .backport.pointerStyle(.resizeLeftRight)
            .onHover { hovering in
                // Pointer styles need macOS 15. Before that, push the cursor like SplitView.Divider.
                if #available(macOS 15, *) { return }
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // Global space because the edge moves with the drag.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($dragOffset) { value, offset, _ in offset = value.translation.width }
                .onEnded { value in
                    settings.expandedWidth = resized(byDragging: value.translation.width)
                    model.focusTerminal()
                })
    }

    /// The expanded width after dragging the inner edge `offset` points to the right.
    private func resized(byDragging offset: CGFloat) -> CGFloat {
        let range = TabBarSettings.expandedWidthRange
        let width = min(settings.expandedWidth, maxWidth) + (edge == .leading ? offset : -offset)
        return min(max(width, range.lowerBound), range.upperBound, maxWidth)
    }
}

private struct VerticalTabRow: View {
    @ObservedObject var model: VerticalTabBarModel
    @ObservedObject var settings: TabBarSettings
    let tab: VerticalTabBarModel.Tab
    let index: Int

    @State private var isHovering = false
    @State private var isDropTarget = false
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        tab.title.isEmpty ? "Terminal" : tab.title
    }

    var body: some View {
        if model.renamingTab == tab.id && !settings.isCollapsed {
            RenameField(
                placeholder: "Tab Title",
                dot: ColorDot(color: tab.color.displayColor),
                font: model.tabTitleFont,
                initialText: model.renameTitle(for: tab.id),
                commit: { model.commitRename(tab.id, title: $0) },
                cancel: model.cancelRename)
                .padding(.horizontal, 8)
                .tabRow(fill: Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1))
        } else {
            label
                .tabRow(fill: fill, raised: tab.isSelected && colorScheme == .light)
                .contentShape(Rectangle())
                .onTapGesture { model.select(tab.id) }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if !settings.isCollapsed { model.rename(tab.id) }
                })
                .onHover { isHovering = $0 }
                .help(title)
                .contextMenu { menu }
                .draggable(model.dragItem(for: tab.id))
                .dropDestination(for: DraggedTab.self) { items, _ in
                    items.first.map { model.drop($0, at: index) } ?? false
                } isTargeted: {
                    isDropTarget = $0
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(tab.status?.accessibilityDescription ?? "")
                .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
        }
    }

    @ViewBuilder
    private var label: some View {
        if settings.isCollapsed {
            // Numbers match the goto_tab keybinds.
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(numberColor)
                .frame(maxWidth: .infinity)
                // The number carries the tab color, so the ring's fill is the status.
                .overlay(alignment: .leading) {
                    StatusDot(color: nil, status: tab.status, since: tab.statusDate, echoScale: 1.5)
                        .padding(.leading, 2)
                }
        } else {
            HStack(spacing: 7) {
                StatusDot(color: tab.color.displayColor, status: tab.status, since: tab.statusDate)

                Text(title)
                    .font(model.tabTitleFont)
                    // A finish nobody has looked at yet reads like an unread message.
                    .fontWeight(tab.status == .done ? .semibold : nil)
                    .foregroundStyle(tab.isSelected || tab.status == .done ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The shortcut keeps its space while hovering so the title never jumps.
                ZStack(alignment: .trailing) {
                    if let shortcut = tab.shortcut {
                        Text(shortcut)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .opacity(isHovering ? 0 : 1)
                    }

                    if isHovering {
                        IconButton(systemImage: "xmark", pointSize: 8, weight: .bold, size: 16, help: "Close Tab") {
                            model.close(tab.id)
                        }
                    }
                }
                .frame(minWidth: 16, alignment: .trailing)
            }
            .padding(.horizontal, 8)
        }
    }

    private var numberColor: Color {
        if let color = tab.color.displayColor { return Color(nsColor: color) }
        return tab.isSelected ? .primary : .secondary
    }

    private var fill: Color {
        if isDropTarget { return Color.accentColor.opacity(0.25) }
        if tab.isSelected {
            // A card lifted off the bar, as Arc draws its selected tab.
            return colorScheme == .dark
                ? Color.white.opacity(appearsActive ? 0.13 : 0.08)
                : Color.white.opacity(appearsActive ? 0.8 : 0.55)
        }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename Tab…") { model.rename(tab.id) }
        ColorMenu(title: "Tab Color", current: tab.color) { model.setColor($0, for: tab.id) }
        groupItems

        Divider()

        Button("Close Tab") { model.close(tab.id) }
        Button("Close Other Tabs") { model.closeOthers(tab.id) }
            .disabled(model.tabs.count < 2)
        Button("Close Tabs Below") { model.closeBelow(tab.id) }
            .disabled(index >= model.tabs.count - 1)
        if !model.workspaces.isEmpty {
            Menu("Move Tab to Workspace") {
                ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    if workspace.isShown {
                        Toggle(workspace.name, isOn: .constant(true)).disabled(true)
                    } else {
                        Button(workspace.name) { model.moveToWorkspace(tab.id, number: index + 1) }
                    }
                }
                Divider()
                Button("New Workspace") { model.moveToWorkspace(tab.id, number: nil) }
                    .disabled(model.tabs.count < 2)
            }
        }
        Button("Move Tab to New Window") { model.moveToNewWindow(tab.id) }
            .disabled(model.tabs.count < 2)

        Divider()

        TabBarMenuItems(model: model, settings: settings)
    }

    /// Add Tab to Group ▸ lists New Group, then the bar's other groups; with no other group
    /// it's a single item.
    @ViewBuilder
    private var groupItems: some View {
        let others = model.groups.filter { $0.id != tab.group?.id }
        if others.isEmpty {
            Button("Add Tab to New Group") { model.addToNewGroup(tab.id) }
        } else {
            Menu("Add Tab to Group") {
                Button("New Group") { model.addToNewGroup(tab.id) }
                Divider()
                ForEach(others) { group in
                    Button {
                        model.addToGroup(tab.id, group.id)
                    } label: {
                        Label {
                            Text(group.title)
                        } icon: {
                            Image(nsImage: group.color.swatchImage(selected: false))
                        }
                    }
                }
            }
        }
        if tab.group != nil {
            Button("Remove Tab from Group") { model.removeFromGroup(tab.id) }
        }
    }
}

private struct NewTabRow: View {
    @ObservedObject var model: VerticalTabBarModel
    let collapsed: Bool

    @State private var isHovering = false
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .frame(width: collapsed ? nil : 7)

            if !collapsed {
                Text("New Tab")
                    .font(model.tabTitleFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, collapsed ? 0 : 8)
        .tabRow(fill: isDropTarget
            ? Color.accentColor.opacity(0.25)
            : Color.primary.opacity(isHovering ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture { model.newTab() }
        .onHover { isHovering = $0 }
        .help("New Tab")
        // Dropping a tab here moves it to the end.
        .dropDestination(for: DraggedTab.self) { items, _ in
            items.first.map { model.drop($0, at: model.tabs.count) } ?? false
        } isTargeted: {
            isDropTarget = $0
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Tab")
        .accessibilityAddTraits(.isButton)
    }
}

/// A Tab group's header: its color and name, which a click collapses or expands, with a count of
/// the Tabs collapsing hides and their agent status. The group's editor hangs off it, and a Tab
/// row dropped on it joins the group.
private struct TabGroupHeader: View {
    @ObservedObject var model: VerticalTabBarModel
    @ObservedObject var settings: TabBarSettings
    let section: VerticalTabBarModel.Section
    let group: TabGroup
    let edge: HorizontalEdge

    @State private var isHovering = false
    @State private var isDropTarget = false

    private var color: Color {
        Color(nsColor: group.color.displayColor ?? .systemGray)
    }

    var body: some View {
        label
            .frame(height: settings.isCollapsed ? 16 : 24)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.25) : Color.primary.opacity(isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onTapGesture { model.toggleCollapsed(group.id) }
            .onHover { isHovering = $0 }
            .help("\(group.title), \(section.count) \(section.count == 1 ? "tab" : "tabs")")
            .contextMenu { TabGroupMenuItems(model: model, settings: settings, group: group) }
            .dropDestination(for: DraggedTab.self) { items, _ in
                items.first.map { model.drop($0, intoGroup: group.id) } ?? false
            } isTargeted: {
                isDropTarget = $0
            }
            .popover(isPresented: isEditing, arrowEdge: edge == .leading ? .trailing : .leading) {
                TabGroupEditor(model: model, id: group.id)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(group.title)
            .accessibilityValue("\(section.count) \(section.count == 1 ? "tab" : "tabs"), \(group.isCollapsed ? "collapsed" : "expanded")")
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var label: some View {
        if settings.isCollapsed {
            // A bar of the group's color, thicker while the group is collapsed.
            Capsule()
                .fill(color)
                .frame(width: group.isCollapsed ? 22 : 16, height: group.isCollapsed ? 8 : 4)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                HStack(spacing: 5) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)

                    if !group.name.isEmpty {
                        Text(group.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(color.opacity(0.22)))

                Spacer(minLength: 0)

                if group.isCollapsed {
                    StatusDot(color: nil, status: section.status, since: section.statusDate)
                    Text("\(section.count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .animation(.easeOut(duration: 0.15), value: group.isCollapsed)
        }
    }

    /// Only a group's first run hangs the editor, so a group split in two shows it once.
    private var isEditing: Binding<Bool> {
        Binding(
            get: { model.editingGroup == group.id && section.id == .group(group.id, run: 0) },
            set: { if !$0 { model.endEditingGroup() } })
    }
}

/// A Tab group's menu, on its header. The last group acts on the bar, not on the group.
private struct TabGroupMenuItems: View {
    @ObservedObject var model: VerticalTabBarModel
    @ObservedObject var settings: TabBarSettings
    let group: TabGroup

    var body: some View {
        Button("Edit Group…") { model.editGroup(group.id) }
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { model.toggleCollapsed(group.id) }
        Button("New Tab in Group") { model.newTab(inGroup: group.id) }

        Divider()

        Button("Ungroup") { model.ungroup(group.id) }
        Button("Close Group") { model.closeGroup(group.id) }

        Divider()

        TabBarMenuItems(model: model, settings: settings)
    }
}

/// The Window's Workspaces as page dots, then "+". Expanded they run in rows that wrap,
/// leading-aligned on either side; collapsed they stack in one column.
private struct WorkspaceDots: View {
    @ObservedObject var model: VerticalTabBarModel
    @ObservedObject var settings: TabBarSettings
    let barWidth: CGFloat

    private var collapsed: Bool { settings.isCollapsed }

    /// The dot under the pointer. Only a dot that still matches clears it, so passing
    /// from dot to dot doesn't flicker the label.
    @State private var hovered: VerticalTabBarModel.Workspace.ID?

    @State private var isNewWorkspaceDropTarget = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if collapsed {
                VStack(spacing: 0) {
                    ForEach(model.workspaces.indices, id: \.self) { dot($0) }
                    newWorkspaceButton
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            } else {
                let count = model.workspaces.count
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(VerticalTabBarModel.dotRows(count: count, width: barWidth - 16), id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(row, id: \.self) { i in
                                if i == count { newWorkspaceButton } else { dot(i) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(alignment: .top) { hoverLabel }
                .padding(.bottom, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspaces")
        // Every switch morphs the capsule from the old mark to the new, and so does a
        // cancelled swipe, from wherever the marks stand back to the shown mark.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.workspaces.first(where: \.isShown)?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.swipeCancels)
    }

    private func dot(_ index: Int) -> some View {
        let workspace = model.workspaces[index]
        return WorkspaceDot(
            model: model,
            workspace: workspace,
            index: index,
            share: VerticalTabBarModel.capsuleShare(
                of: workspace.id,
                shown: model.workspaces.first(where: \.isShown)?.id,
                neighbor: model.neighborPage?.workspace.id,
                amount: model.swipeAmount,
                reduceMotion: reduceMotion),
            settings: settings,
            hovered: $hovered)
    }

    /// "+" takes only Tab rows, and not a Workspace's only Tab, so it lights up only for those.
    private var newWorkspaceButton: some View {
        IconButton(systemImage: "plus", pointSize: 10, weight: .medium, size: 20, help: "New Workspace") {
            model.newWorkspace()
        }
        .frame(width: collapsed ? 32 : VerticalTabBarModel.newWorkspacePitch, height: 22)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isNewWorkspaceDropTarget ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
        .dropDestination(for: WorkspaceDrop.self) { items, _ in
            items.first.map { model.drop($0, on: nil) } ?? false
        } isTargeted: {
            isNewWorkspaceDropTarget = $0 && DraggedTab.isDragging && model.tabs.count > 1
        }
    }

    /// The hovered dot's name, above the dots and never wider than the bar. Collapsed,
    /// dots use tooltips instead, since nothing can draw over the terminal.
    @ViewBuilder
    private var hoverLabel: some View {
        if let workspace = model.workspaces.first(where: { $0.id == hovered }) {
            Text(workspace.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(colorScheme == .dark ? Color(white: 0.2) : .white))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .frame(maxWidth: barWidth - 12)
                .offset(y: -24)
                .allowsHitTesting(false)
                // VoiceOver reads the name on the dot itself.
                .accessibilityHidden(true)
        }
    }
}

/// One Workspace's mark: a 6 pt dot, or the 12×6 capsule (upright when collapsed) for
/// the shown Workspace. One shape for both, so a switch or a swipe morphs it in place.
private struct WorkspaceDot: View {
    @ObservedObject var model: VerticalTabBarModel
    let workspace: VerticalTabBarModel.Workspace
    let index: Int
    /// How much of the capsule this mark holds (`VerticalTabBarModel.capsuleShare`).
    let share: CGFloat
    @ObservedObject var settings: TabBarSettings
    @Binding var hovered: VerticalTabBarModel.Workspace.ID?

    private var collapsed: Bool { settings.isCollapsed }

    @State private var isDropTarget = false

    var body: some View {
        let mark = VerticalTabBarModel.mark(share: share)
        let fill = workspace.color.displayColor.map { Color(nsColor: $0) } ?? .primary

        // The capsule fades to nothing as it shrinks, and the dimmed StatusDot with its
        // ring shows in its place, so the mark morphs by its share.
        Capsule()
            .fill(fill.opacity(share))
            .frame(width: collapsed ? 6 : mark.length, height: collapsed ? mark.length : 6)
            .overlay {
                StatusDot(
                    color: workspace.color.displayColor,
                    status: workspace.status,
                    since: workspace.statusDate,
                    dotSize: 6,
                    echoScale: 1.5,
                    dimming: hovered == workspace.id ? 0.8 : 0.35)
                    .opacity(mark.ringOpacity)
            }
            .frame(
                width: collapsed ? 32 : VerticalTabBarModel.dotPitch,
                height: collapsed ? VerticalTabBarModel.dotPitch : 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.25) : .clear))
            .contentShape(Rectangle())
            .onTapGesture { model.showWorkspace(workspace.id) }
            .onHover { inside in
                if inside {
                    hovered = workspace.id
                } else if hovered == workspace.id {
                    hovered = nil
                }
            }
            .contextMenu { WorkspaceMenuItems(model: model, settings: settings, workspace: workspace) }
            .draggable(model.dragItem(for: workspace.id))
            .dropDestination(for: WorkspaceDrop.self) { items, _ in
                items.first.map { model.drop($0, on: workspace.id) } ?? false
            } isTargeted: {
                // The capsule takes no Tab, so it doesn't light up for one.
                isDropTarget = $0 && !(workspace.isShown && DraggedTab.isDragging)
            }
            .help(collapsed ? workspace.name : "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(workspace.name)
            .accessibilityValue(
                // The shown Workspace's Tabs read their own status right above.
                ["Workspace \(index + 1) of \(model.workspaces.count)",
                 workspace.isShown ? nil : workspace.status?.accessibilityDescription]
                    .compactMap { $0 }
                    .joined(separator: ", "))
            .accessibilityAddTraits(workspace.isShown ? [.isButton, .isSelected] : .isButton)
    }
}

/// A Workspace's menu, on its dot and, for the shown one, on the header. The last group
/// acts on the bar, not on the Workspace.
private struct WorkspaceMenuItems: View {
    @ObservedObject var model: VerticalTabBarModel
    @ObservedObject var settings: TabBarSettings
    let workspace: VerticalTabBarModel.Workspace

    var body: some View {
        Button("Customize Workspace…") { model.customizeWorkspace(workspace.id) }
        Button("Rename Workspace…") { model.renameWorkspace(workspace.id) }

        Divider()

        Button("Close Workspace") { model.closeWorkspace(workspace.id) }
        Button("Move Workspace to New Window") { model.moveWorkspaceToNewWindow(workspace.id) }
            .disabled(model.workspaces.count < 2)

        Divider()

        TabBarMenuItems(model: model, settings: settings)
    }
}

/// The shown Workspace's name atop the expanded bar, led by a dot of its color when it has
/// one. Double-clicking renames it in place, as with a Tab row, and the button beside it
/// opens the customizer, as Arc's does beside a Space's name.
private struct WorkspaceHeader: View {
    @ObservedObject var model: VerticalTabBarModel
    @ObservedObject var settings: TabBarSettings
    let workspace: VerticalTabBarModel.Workspace
    let edge: HorizontalEdge

    @State private var isHovering = false

    private static let font = Font.system(size: 13, weight: .semibold)

    /// Nil leaves no room for a dot.
    private var dot: ColorDot? {
        workspace.color.displayColor.map { ColorDot(color: $0) }
    }

    var body: some View {
        if model.renamingWorkspace == workspace.id {
            RenameField(
                placeholder: "Workspace Name",
                dot: dot,
                font: Self.font,
                initialText: workspace.name,
                commit: { model.commitWorkspaceRename(workspace.id, name: $0) },
                cancel: model.cancelWorkspaceRename)
        } else {
            HStack(spacing: 4) {
                if edge == .trailing { customizeButton }

                HStack(spacing: 7) {
                    dot

                    Text(workspace.name)
                        .font(Self.font)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Mirrored on a right-side bar, so the name sits against the toggle.
                .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.beginWorkspaceRename() }
                .help(workspace.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(workspace.name)
                .accessibilityAddTraits(.isHeader)

                if edge == .leading { customizeButton }
            }
            .onHover { isHovering = $0 }
            .contextMenu { WorkspaceMenuItems(model: model, settings: settings, workspace: workspace) }
        }
    }

    /// Keeps its room while hidden, so the name never shifts, and shows while the pointer is
    /// over the header or the customizer is open.
    private var customizeButton: some View {
        IconButton(systemImage: "paintpalette", pointSize: 12, size: 22, help: "Customize Workspace") {
            model.customizeWorkspace(workspace.id)
        }
        .opacity(isHovering || model.customizing == workspace.id ? 1 : 0)
    }
}

/// Edits a name in place: Return commits, Esc cancels, and clicking elsewhere commits.
private struct RenameField: View {
    let placeholder: String
    /// The dot before the field; nil leaves no room for one.
    let dot: ColorDot?
    let font: Font
    let initialText: String
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            dot

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .focused($isFocused)
                .onSubmit { commit(text) }
                .onExitCommand { cancel() }
        }
        .onAppear {
            text = initialText
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: isFocused) { focused in
            // Clicking elsewhere commits, like the native tab title editor.
            if !focused { commit(text) }
        }
        // Collapsing or moving the bar removes the field without a blur, which would
        // leave keyboard focus on the window. Commit so focus returns to the terminal.
        .onDisappear { commit(text) }
    }
}

/// Tab bar layout items shared by the bar's context menus.
private struct TabBarMenuItems: View {
    @ObservedObject var model: VerticalTabBarModel
    @ObservedObject var settings: TabBarSettings

    var body: some View {
        Button("New Tab") { model.newTab() }

        Divider()

        Picker("Tab Bar Position", selection: $settings.position) {
            ForEach(TabBarPosition.allCases, id: \.self) { position in
                Text(position.title).tag(position)
            }
        }
        Button(settings.isCollapsed ? "Expand Tab Bar" : "Collapse Tab Bar") {
            settings.isCollapsed.toggle()
        }
    }
}

/// A swatch for each color, None first, with `current` marked: the Tab Color menu.
private struct ColorMenu: View {
    let title: String
    let current: TerminalTabColor
    let set: (TerminalTabColor) -> Void

    var body: some View {
        Menu(title) {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    set(color)
                } label: {
                    Label {
                        Text(color.localizedName)
                    } icon: {
                        Image(nsImage: color.swatchImage(selected: color == current))
                    }
                }
            }
        }
    }
}

private struct IconButton: View {
    let systemImage: String
    var pointSize: CGFloat = 13
    var weight: Font.Weight = .regular
    let size: CGFloat
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: pointSize, weight: weight))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Keyboard focus belongs to the terminal.
        .focusable(false)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A Tab's or Workspace's color, or an empty slot so titles stay aligned.
private struct ColorDot: View {
    let color: NSColor?

    var body: some View {
        Circle()
            .fill(color.map { Color(nsColor: $0) } ?? .clear)
            .frame(width: 7, height: 7)
    }
}

/// A bar's backdrop: the terminal's background, receded a little so the bar reads as
/// chrome, then washed in the Workspace color, strongest at the top, the way Arc washes its
/// sidebar in a Space's color.
private struct WorkspaceBackdrop: View {
    let background: NSColor?
    let wash: NSColor?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Color(nsColor: background ?? .windowBackgroundColor)
            .overlay(Color.black.opacity(dark ? 0.16 : 0.04))
            .overlay {
                if let wash {
                    Rectangle()
                        .fill(Color(nsColor: wash))
                        .mask(LinearGradient(
                            colors: [.white.opacity(dark ? 0.3 : 0.24), .white.opacity(dark ? 0.12 : 0.1)],
                            startPoint: .top,
                            endPoint: .bottom))
                        .transition(.opacity)
                }
            }
    }
}

/// A tab's color dot, ringed while an agent in the tab is done or waiting. The ring
/// always means status; the fill keeps the tab color, or takes the status color when
/// the tab has none.
struct StatusDot: View {
    let color: NSColor?
    let status: Ghostty.AgentStatus?

    /// When `status` last changed, so only a finish that just arrived pings.
    let since: Date

    /// The plain dot's size. The ring overflows it so titles never move.
    var dotSize: CGFloat = 7

    /// How far the ping and pulse rings grow; tight spots keep them off their neighbors.
    var echoScale: CGFloat = 2.1

    /// For hidden Workspace dots: the color fill at this opacity, and gray without a color
    /// or a status. Nil keeps the color at full strength and leaves an empty slot.
    var dimming: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tint = status.map { Color(nsColor: $0.color) }
        let color = self.color.map { Color(nsColor: $0) }
        let fill = dimming.map { dimming in color.map { $0.opacity(dimming) } ?? tint ?? .primary.opacity(dimming) }
            ?? color ?? tint ?? .clear

        // One container for every state so status changes animate in place.
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: status == nil ? dotSize : 5, height: status == nil ? dotSize : 5)

            if let tint {
                // A thicker ring stands in for the pulse when motion is reduced.
                let still = status == .waiting && reduceMotion
                Circle()
                    .strokeBorder(tint, lineWidth: still ? 1.5 : 1)
                    .frame(width: still ? 10 : 9, height: still ? 10 : 9)

                if status == .waiting && !reduceMotion {
                    StatusPulse(tint: tint, scale: echoScale)
                }

                // Rows are rebuilt when switching tabs, so only a finish that just
                // arrived pings. A new date is a new ring, so a Workspace whose Tabs
                // finish one after another pings for each.
                if status == .done && !reduceMotion && Date().timeIntervalSince(since) < 0.5 {
                    Circle()
                        .strokeBorder(tint, lineWidth: 1)
                        .frame(width: 9, height: 9)
                        .id(since)
                        .transition(.asymmetric(
                            insertion: .modifier(
                                active: StatusPing(progress: 0, scale: echoScale),
                                identity: StatusPing(progress: 1, scale: echoScale))
                                .animation(.easeOut(duration: 0.9)),
                            removal: .identity))
                }
            }
        }
        .frame(width: dotSize, height: dotSize)
        .animation(.easeOut(duration: 0.16), value: status)
    }
}

/// One expanding ring for a finish that just arrived.
private struct StatusPing: ViewModifier {
    let progress: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + (scale - 1) * progress)
            .opacity(0.9 * (1 - progress))
    }
}

/// An expanding ring that repeats while an agent waits on the user.
private struct StatusPulse: View {
    let tint: Color
    let scale: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            // Expand for 1.8 s, then rest for 0.6 s.
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)
            let progress = min(phase / 1.8, 1)
            Circle()
                .strokeBorder(tint, lineWidth: 1)
                .frame(width: 9, height: 9)
                .scaleEffect(1 + (scale - 1) * (1 - pow(1 - progress, 3)))
                .opacity(0.8 * (1 - progress))
        }
    }
}

extension Ghostty.AgentStatus {
    /// Green for done, amber for waiting; each keeps at least 3:1 contrast against
    /// the tab bar in dark and light.
    var color: NSColor {
        switch self {
        case .done:
            return NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(srgbRed: 0x5E / 255, green: 0xDB / 255, blue: 0x81 / 255, alpha: 1)
                    : NSColor(srgbRed: 0x0A / 255, green: 0x7E / 255, blue: 0x3A / 255, alpha: 1)
            }
        case .waiting:
            return NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(srgbRed: 0xFC / 255, green: 0xC3 / 255, blue: 0x5D / 255, alpha: 1)
                    : NSColor(srgbRed: 0xA6 / 255, green: 0x56 / 255, blue: 0x0A / 255, alpha: 1)
            }
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .done: return "Agent finished"
        case .waiting: return "Agent waiting for you"
        }
    }
}

private extension View {
    /// Size and selection shape shared by every row of the bar. A raised row casts a faint
    /// shadow, as a card on the bar.
    func tabRow(fill: Color, raised: Bool = false) -> some View {
        frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
                .shadow(color: .black.opacity(raised ? 0.1 : 0), radius: 1.5, y: 0.5))
    }
}
