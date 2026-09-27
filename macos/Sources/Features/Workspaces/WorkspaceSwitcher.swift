import SwiftUI

/// The Workspace switcher: the command palette's view, in its spot and style, listing the
/// Window's Workspaces most recently shown first, so opening it and pressing Return shows
/// the previous Workspace.
struct WorkspaceSwitcherView: View {
    /// The surface the switcher is overlaid on. Focus returns to it on close.
    let surfaceView: Ghostty.SurfaceView

    /// The Tab the switcher is open in. Choosing a row asks its store as a dot would.
    let tab: TerminalController

    @Binding var isPresented: Bool

    /// Rows follow the Window's Workspaces while the switcher is open.
    @ObservedObject var store: WorkspaceStore

    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// Bumped when a Tab's title or agent status changes, so rows redraw.
    @State private var tabChanges = 0

    var body: some View {
        let _ = tabChanges
        ZStack {
            if isPresented {
                let options = options
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: options,
                            placeholder: "Switch to Workspace…",
                            // Row 2 is the Workspace shown before this one.
                            initialSelection: options.count > 1 ? 1 : 0
                        )
                        .zIndex(1)

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TerminalWindow.tabDidChangeNotification)) { _ in
            if isPresented { tabChanges += 1 }
        }
        .onChange(of: isPresented) { newValue in
            // Focus returns to the focused Split, unless the palette took over or the choice
            // hid this Tab, whose Split mustn't take focus beside the incoming Tab's.
            guard !newValue else { return }
            DispatchQueue.main.async {
                guard !tab.paletteOrSwitcherIsShowing, !tab.isHidden else { return }
                surfaceView.window?.makeFirstResponder(surfaceView)
            }
        }
    }

    private var options: [CommandOption] {
        let shortcuts = store.workspaces.enumerated().reduce(into: [WorkspaceStore.Workspace.ID: [String]]()) { result, entry in
            if entry.offset < 9 {
                result[entry.element.id] = ghosttyConfig.keyboardShortcut(for: "goto_workspace:\(entry.offset + 1)")?.keyList
            }
        }

        return store.recentWorkspaces.map { workspace in
            let isShown = workspace.id == store.shownID
            let tabs = store.tabs(of: workspace.id)
            let selecting = isShown ? store.shownTab : workspace.rememberedTab ?? tabs.first
            let status = store.agentStatus(of: workspace.id)
            let count = tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs"

            return CommandOption(
                title: workspace.name,
                subtitle: selecting.map { "\(count) · \(Self.title(of: $0))" } ?? count,
                symbols: shortcuts[workspace.id],
                leadingDot: StatusDot(color: workspace.color.displayColor, status: status.status, since: status.since),
                badge: isShown ? "Shown" : nil,
                tabs: tabs.map { tab in
                    let focused = tab.focusedSurface
                    let splits = (focused.map { [$0] } ?? []) + tab.surfaceTree.filter { $0 !== focused }
                    return CommandOption.Tab(
                        title: Self.title(of: tab),
                        folders: splits.compactMap { $0.pwd?.abbreviatedPath })
                },
                accessibilityValue: [status.status?.accessibilityDescription, isShown ? "shown" : nil, count]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            ) { [tab, store] in
                // Switches as its dot would. The shown one just closes the switcher.
                guard workspace.id != store.shownID,
                      store.allowsRequest(from: tab, orShow: .cannotSwitch)
                else { return }
                store.show(workspace.id)
            }
        }
    }

    /// A Tab's title as the tab bar shows it.
    private static func title(of tab: TerminalController) -> String {
        let title = tab.window?.title ?? ""
        return title.isEmpty ? "Terminal" : title
    }
}
