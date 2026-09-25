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
        // Left by default so the Workspace dots show (SPEC §4.1); a stored position wins.
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
        let isSelected: Bool
    }

    /// A Workspace of the Window, drawn as a dot at the foot of the bar.
    struct Workspace: Identifiable, Equatable {
        let id: WorkspaceStore.Workspace.ID
        let name: String
        let color: TerminalTabColor
        let isShown: Bool
        /// A hidden Workspace's agent status roll-up, and its date. None for the shown
        /// Workspace: its Tabs show theirs right above (SPEC §5.6).
        let status: Ghostty.AgentStatus?
        let statusDate: Date
    }

    @Published private(set) var tabs: [Tab] = []

    /// The Window's Workspaces in bar order. Empty when the Window can't hold them
    /// (SPEC §4.2), so the bar draws no dots.
    @Published private(set) var workspaces: [Workspace] = []

    /// The tab being renamed inline.
    @Published private(set) var renamingTab: Tab.ID?

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
        let selected = tabGroup?.selectedWindow ?? window
        let config = (window.windowController as? BaseTerminalController)?.ghostty.config

        // Keep the first of any duplicate: AppKit's tab state can go wrong, and a
        // duplicate key would crash.
        tabWindows = Dictionary(
            windows.map { (ObjectIdentifier($0), Weak($0)) },
            uniquingKeysWith: { first, _ in first })
        let tabs = windows.enumerated().map { index, tabWindow in
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
                isSelected: tabWindow === selected)
        }
        if tabs != self.tabs { self.tabs = tabs }

        // Every Tab's bar follows the Window's store, so a switch also redraws the bar of
        // a Tab that comes in without becoming key.
        let store = workspaceTab?.workspaceStore
        if store !== observedStore { observe(store: store) }
        let workspaces = store.map { store in
            store.workspaces.map { workspace -> Workspace in
                let isShown = workspace.id == store.shownID
                let rollUp = isShown ? (nil, .distantPast) : store.agentStatus(of: workspace.id)
                return Workspace(
                    id: workspace.id, name: workspace.name, color: workspace.color, isShown: isShown,
                    status: rollUp.status, statusDate: rollUp.since)
            }
        } ?? []
        if workspaces != self.workspaces { self.workspaces = workspaces }
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

    /// This bar's Tab, when its Window holds Workspaces (SPEC §4.2).
    private var workspaceTab: TerminalController? {
        guard let tab = window?.windowController as? TerminalController,
              tab.workspacesUnavailableAlert == nil
        else { return nil }
        return tab
    }

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

    /// The expanded bar's rows of dots (SPEC §5.1): indices of `count` 14 pt dots, then
    /// "+" (22 pt) as index `count`, broken greedily into rows no wider than `width`. A row
    /// breaks before the item that doesn't fit and is never empty.
    static func dotRows(count: Int, width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for i in 0...count {
            let itemWidth: CGFloat = i == count ? 22 : 14
            if x + itemWidth > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(i)
            x += itemWidth
        }
        return rows
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

    // MARK: Dragging

    func dragItem(for id: Tab.ID) -> DraggedTab {
        DraggedTab(window: UInt(bitPattern: id))
    }

    /// Moves the dragged tab to `index` in this window's tab group, taking it out of
    /// another group if it came from a different window.
    func moveTab(_ tab: DraggedTab, to index: Int) -> Bool {
        guard let window,
              let dragged = NSApp.windows.first(where: { UInt(bitPattern: ObjectIdentifier($0)) == tab.window })
        else { return false }

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
}

extension UTType {
    static let ghosttyTab = UTType(exportedAs: "com.mitchellh.ghosttyTab")
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

    @Environment(\.colorScheme) private var colorScheme

    private var selectedTab: VerticalTabBarModel.Tab.ID? {
        model.tabs.first(where: \.isSelected)?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // The toggle sits on the outer edge so it stays under the pointer
            // when the bar collapses.
            IconButton(
                systemImage: edge == .leading ? "sidebar.left" : "sidebar.right",
                size: 24,
                help: settings.isCollapsed ? "Expand Tab Bar" : "Collapse Tab Bar"
            ) {
                settings.isCollapsed.toggle()
                model.focusTerminal()
            }
            .frame(
                maxWidth: .infinity,
                alignment: settings.isCollapsed ? .center : edge == .leading ? .leading : .trailing)
            .padding(.horizontal, 6)
            .frame(height: 34)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                            VerticalTabRow(model: model, settings: settings, tab: tab, index: index)
                                .id(tab.id)
                        }

                        NewTabRow(model: model, collapsed: settings.isCollapsed)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onChange(of: selectedTab) { id in
                    if let id { proxy.scrollTo(id) }
                }
            }

            // Pinned below the list, which scrolls to make room.
            if !model.workspaces.isEmpty {
                WorkspaceDots(model: model, collapsed: settings.isCollapsed, barWidth: width)
            }
        }
        .frame(width: width)
        // No ideal height: the window's default size comes from the terminal, not
        // from how many tabs are open.
        .frame(idealHeight: 0, maxHeight: .infinity)
        .background(
            // Recede slightly from the terminal so the bar reads as chrome.
            Color(nsColor: model.backgroundColor ?? .windowBackgroundColor)
                .overlay(Color.black.opacity(colorScheme == .dark ? 0.16 : 0.04))
        )
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

    private var title: String {
        tab.title.isEmpty ? "Terminal" : tab.title
    }

    var body: some View {
        if model.renamingTab == tab.id && !settings.isCollapsed {
            TabRenameField(model: model, tab: tab)
                .tabRow(fill: Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1))
        } else {
            label
                .tabRow(fill: fill)
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
                    items.first.map { model.moveTab($0, to: index) } ?? false
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
                    StatusDot(color: .none, status: tab.status, since: tab.statusDate, echoScale: 1.5)
                        .padding(.leading, 2)
                }
        } else {
            HStack(spacing: 7) {
                StatusDot(color: tab.color, status: tab.status, since: tab.statusDate)

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
        if tab.isSelected { return Color.primary.opacity(appearsActive ? 0.14 : 0.08) }
        return isHovering ? Color.primary.opacity(0.06) : .clear
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename Tab…") { model.rename(tab.id) }
        Menu("Tab Color") {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    model.setColor(color, for: tab.id)
                } label: {
                    Label {
                        Text(color.localizedName)
                    } icon: {
                        Image(nsImage: color.swatchImage(selected: color == tab.color))
                    }
                }
            }
        }

        Divider()

        Button("Close Tab") { model.close(tab.id) }
        Button("Close Other Tabs") { model.closeOthers(tab.id) }
            .disabled(model.tabs.count < 2)
        Button("Close Tabs Below") { model.closeBelow(tab.id) }
            .disabled(index >= model.tabs.count - 1)
        Button("Move Tab to New Window") { model.moveToNewWindow(tab.id) }
            .disabled(model.tabs.count < 2)

        Divider()

        TabBarMenuItems(model: model, settings: settings)
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
            items.first.map { model.moveTab($0, to: model.tabs.count) } ?? false
        } isTargeted: {
            isDropTarget = $0
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Tab")
        .accessibilityAddTraits(.isButton)
    }
}

/// The Window's Workspaces as page dots, then "+" (SPEC §5.1). Expanded they run in rows
/// that wrap, leading-aligned on either side; collapsed they stack in one column.
private struct WorkspaceDots: View {
    @ObservedObject var model: VerticalTabBarModel
    let collapsed: Bool
    let barWidth: CGFloat

    /// The dot under the pointer. Only a dot that still matches clears it, so passing
    /// from dot to dot doesn't flicker the label.
    @State private var hovered: VerticalTabBarModel.Workspace.ID?

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
        // Every switch morphs the capsule from the old mark to the new (SPEC §6.5).
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.workspaces.first(where: \.isShown)?.id)
    }

    private func dot(_ index: Int) -> some View {
        WorkspaceDot(
            model: model,
            workspace: model.workspaces[index],
            index: index,
            collapsed: collapsed,
            hovered: $hovered)
    }

    private var newWorkspaceButton: some View {
        IconButton(systemImage: "plus", pointSize: 10, weight: .medium, size: 20, help: "New Workspace") {
            model.newWorkspace()
        }
        .frame(width: collapsed ? 32 : 22, height: 22)
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
/// the shown Workspace. One shape for both, so a switch morphs it in place.
private struct WorkspaceDot: View {
    @ObservedObject var model: VerticalTabBarModel
    let workspace: VerticalTabBarModel.Workspace
    let index: Int
    let collapsed: Bool
    @Binding var hovered: VerticalTabBarModel.Workspace.ID?

    var body: some View {
        let long: CGFloat = workspace.isShown ? 12 : 6
        let fill = workspace.color.displayColor.map { Color(nsColor: $0) } ?? .primary

        // The capsule fades to nothing as it shrinks, and the hidden dot's StatusDot
        // shows in its place, so a switch still morphs the mark.
        Capsule()
            .fill(fill.opacity(workspace.isShown ? 1 : 0))
            .frame(width: collapsed ? 6 : long, height: collapsed ? long : 6)
            .overlay {
                if !workspace.isShown {
                    StatusDot(
                        color: workspace.color,
                        status: workspace.status,
                        since: workspace.statusDate,
                        dotSize: 6,
                        echoScale: 1.5,
                        dimming: hovered == workspace.id ? 0.8 : 0.35)
                }
            }
            .frame(width: collapsed ? 32 : 14, height: collapsed ? 14 : 22)
            .contentShape(Rectangle())
            .onTapGesture { model.showWorkspace(workspace.id) }
            .onHover { inside in
                if inside {
                    hovered = workspace.id
                } else if hovered == workspace.id {
                    hovered = nil
                }
            }
            .help(collapsed ? workspace.name : "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(workspace.name)
            .accessibilityValue(
                ["Workspace \(index + 1) of \(model.workspaces.count)", workspace.status?.accessibilityDescription]
                    .compactMap { $0 }
                    .joined(separator: ", "))
            .accessibilityAddTraits(workspace.isShown ? [.isButton, .isSelected] : .isButton)
    }
}

private struct TabRenameField: View {
    @ObservedObject var model: VerticalTabBarModel
    let tab: VerticalTabBarModel.Tab

    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            ColorDot(color: tab.color)

            TextField("Tab Title", text: $title)
                .textFieldStyle(.plain)
                .font(model.tabTitleFont)
                .focused($isFocused)
                .onSubmit { model.commitRename(tab.id, title: title) }
                .onExitCommand { model.cancelRename() }
        }
        .padding(.horizontal, 8)
        .onAppear {
            title = model.renameTitle(for: tab.id)
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: isFocused) { focused in
            // Clicking elsewhere commits, like the native tab title editor.
            if !focused { model.commitRename(tab.id, title: title) }
        }
        // Collapsing or moving the bar removes the field without a blur, which would
        // leave keyboard focus on the window. Commit so focus returns to the terminal.
        .onDisappear { model.commitRename(tab.id, title: title) }
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

/// The user-assigned tab color, or an empty slot so titles stay aligned.
private struct ColorDot: View {
    let color: TerminalTabColor

    var body: some View {
        Circle()
            .fill(color.displayColor.map { Color(nsColor: $0) } ?? .clear)
            .frame(width: 7, height: 7)
    }
}

/// A tab's color dot, ringed while an agent in the tab is done or waiting. The ring
/// always means status; the fill keeps the tab color, or takes the status color when
/// the tab has none.
struct StatusDot: View {
    let color: TerminalTabColor
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
        let color = self.color.displayColor.map { Color(nsColor: $0) }
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
    /// Size and selection shape shared by every row of the bar.
    func tabRow(fill: Color) -> some View {
        frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
    }
}
