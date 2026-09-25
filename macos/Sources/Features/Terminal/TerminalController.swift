import Foundation
import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A classic, tabbed terminal experience.
class TerminalController: BaseTerminalController, TabGroupCloseCoordinator.Controller {
    override var windowNibName: NSNib.Name? { windowStyle.nibName }

    /// The Window's titlebar style and decorations, fixed when the Window is created. A Tab
    /// created into an existing Window takes that Window's, not a reloaded config's, so it
    /// always joins the Window's group, and the Window keeps (or keeps lacking) Workspaces
    /// (SPEC §4.2).
    struct WindowStyle: Equatable {
        let nibName: String

        /// False under `window-decoration = none`. Recorded because non-native fullscreen
        /// also removes `.titled`.
        let isDecorated: Bool

        init(_ config: Ghostty.Config) {
            isDecorated = config.windowDecorations

            // If we have no window decorations, there's no reason to do anything but
            // the default titlebar (because there will be no titlebar).
            guard isDecorated else {
                nibName = "Terminal"
                return
            }

            nibName = switch config.macosTitlebarStyle {
            case .native: "Terminal"
            case .hidden: "TerminalHiddenTitlebar"
            case .transparent: "TerminalTransparentTitlebar"
            case .tabs:
#if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    "TerminalTabsTitlebarTahoe"
                } else {
                    "TerminalTabsTitlebarVentura"
                }
#else
                "TerminalTabsTitlebarVentura"
#endif
            }
        }
    }

    let windowStyle: WindowStyle

    /// This is set to true when we care about frame changes. This is a small optimization since
    /// this controller registers a listener for ALL frame change notifications and this lets us bail
    /// early if we don't care.
    private var tabListenForFrame: Bool = false

    /// This is the hash value of the last tabGroup.windows array. We use this to detect order
    /// changes in the list.
    private var tabWindowsHash: Int = 0

    /// The initial window presentation is deferred by one runloop turn in a few places so
    /// AppKit can settle tab/window state first. Close actions must cancel it to avoid
    /// re-showing a tab/window that was already closed.
    private var pendingInitialPresentation: DispatchWorkItem?

    /// This is set to false by init if the window managed by this controller should not be restorable.
    /// For example, terminals executing custom scripts are not restorable.
    private var restorable: Bool = true

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// Draws the most urgent agent status of this tab's surfaces on the tab.
    private var agentStatusCancellable: AnyCancellable?

    /// The store of the Window this Tab belongs to, shown or hidden. A Tab that starts a
    /// Window makes one, holding "Workspace 1"; a Tab added to a Window adopts its store.
    lazy var workspaceStore = WorkspaceStore(tab: self) {
        // The bar draws the Window's Workspaces, so it follows the Tab to its new store.
        // No object: reading `window` here would load it before the Tab is set up.
        didSet { NotificationCenter.default.post(name: TerminalWindow.tabDidChangeNotification, object: nil) }
    }

    /// The target of this Tab's Undo and Redo Move Tab entries, so they alone come off the
    /// stack when the Tab leaves its Window (SPEC §11.4).
    let moveTabUndoTarget = NSObject()

    /// Turns two-finger horizontal swipes over this Tab's vertical tab bar into Workspace
    /// switches (SPEC §6.2).
    private var swipeMonitor: Any?

    /// `windowStyle` is the style of the Window this Tab is created into. Nil means a new
    /// Window, styled by the current config.
    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         windowStyle: WindowStyle? = nil
    ) {
        // The window we manage is not restorable if we've specified a command
        // to execute. We do this because the restored window is meaningless at the
        // time of writing this: it'd just restore to a shell in the same directory
        // as the script. We may want to revisit this behavior when we have scrollback
        // restoration.
        self.restorable = (base?.command ?? "") == ""

        // Setup our initial derived config based on the current app config
        self.derivedConfig = DerivedConfig(ghostty.config)
        self.windowStyle = windowStyle ?? WindowStyle(ghostty.config)

        super.init(ghostty, baseConfig: base, surfaceTree: tree)

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onToggleFullscreen),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onGotoTab),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseOtherTabs),
            name: .ghosttyCloseOtherTabs,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTabsOnTheRight),
            name: .ghosttyCloseTabsOnTheRight,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onResetWindowSize),
            name: .ghosttyResetWindowSize,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseWindow),
            name: .ghosttyCloseWindow,
            object: nil
        )

        // Local monitors see every window's events, so this acts only on its own.
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.swipeMonitorEvent(event) ?? event
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        // Remove all of our notificationcenter subscriptions
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
    }

    private func swipeMonitorEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }

        let store = workspaceStore
        switch store.swipeAction(
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            startsSwipe: startsSwipe(at: event.locationInWindow)
        ) {
        case .pass:
            return event
        case .drop:
            return nil
        case .track:
            store.trackSwipe(event)
            return event
        }
    }

    /// Whether a scroll gesture beginning at `point` may become a swipe (SPEC §6.1): it's
    /// over the vertical tab bar of a Window with Workspaces, and nothing else holds the bar
    /// or the Window.
    private func startsSwipe(at point: NSPoint) -> Bool {
        guard let window = window as? TerminalWindow,
              window.showsVerticalTabBar,
              workspacesUnavailableAlert == nil,
              NSEvent.pressedMouseButtons == 0,
              window.attachedSheet == nil,
              window.verticalTabBar.renamingTab == nil,
              window.verticalTabBar.renamingWorkspace == nil,
              !workspaceStore.isInNonNativeFullscreen
        else { return false }

        // The bar sits below the titlebar and takes at most half the window, as
        // VerticalTabBarLayout lays it out.
        let content = window.contentLayoutRect
        let settings = TabBarSettings.shared
        let width = min(settings.verticalWidth, content.width / 2)
        let minX = settings.position == .left ? content.minX : content.maxX - width
        return point.y < content.maxY && point.x >= minX && point.x < minX + width
    }

    private func cancelPendingInitialPresentation() {
        pendingInitialPresentation?.cancel()
        pendingInitialPresentation = nil
    }

    /// True while the new Window this Tab starts waits a runloop turn to be presented. It
    /// forms no tab group until then.
    var awaitsInitialPresentation: Bool { pendingInitialPresentation != nil }

    private func scheduleInitialPresentation(_ block: @escaping () -> Void) {
        cancelPendingInitialPresentation()

        var scheduledWorkItem: DispatchWorkItem?
        scheduledWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingInitialPresentation = nil }
            guard pendingInitialPresentation?.isCancelled == false else { return }
            block()
        }

        let workItem = scheduledWorkItem!
        pendingInitialPresentation = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: Base Controller Overrides

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // Whenever our surface tree changes in any way (new split, close split, etc.)
        // we want to invalidate our state.
        invalidateRestorableState()
        // Only the app-level Workspaces entry saves a hidden Tab.
        if workspaceStore.isHidden(self) { NSApp.invalidateRestorableState() }

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        // If our surface tree is now nil then we close our window.
        if to.isEmpty {
            self.window?.close()
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // We have a special case if our tree is empty to close our tab immediately.
        // This makes it so that undo is handled properly.
        if newTree.isEmpty {
            closeTabImmediately()
            return
        }

        super.replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        if hasFixedPos { return }

        if all.count > 1 {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            // We assume the window frame is already correct at this point,
            // so we pass .zero to let cascade use the current frame position.
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
        }
    }

    /// Places this Tab's window as Cmd+N places a new Window: at the configured
    /// `window-position-x` and `window-position-y`, else at the next cascade point.
    func placeAsNewWindow() {
        guard let window = window as? TerminalWindow else { return }
        let hasFixedPos = window.setInitialWindowPosition(
            x: derivedConfig.windowPositionX,
            y: derivedConfig.windowPositionY)
        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
    }

    // The preferred parent terminal controller. It's never a hidden Tab: a hidden `lastMain`,
    // left behind by a switch made while booTTY was inactive, stands for its Window's shown
    // Tab (SPEC §2.5). A hidden Tab is never main.
    static var preferredParent: TerminalController? {
        all.first {
            $0.window?.isMainWindow ?? false
        } ?? lastMain?.onScreenTab ?? all.last { !$0.isInHiddenWorkspace }
    }

    // The last controller to be main. We use this when paired with "preferredParent"
    // to find the preferred window to attach new tabs, perform actions, etc. We
    // always prefer the main window but if there isn't any (because we're triggered
    // by something like an App Intent) then we prefer the most previous main.
    static private(set) weak var lastMain: TerminalController?

    /// The "new window" action. The Window's one Workspace is `workspaceName`, by default
    /// "Workspace 1" (SPEC §1.2).
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil,
        workspaceName: String? = nil
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withBaseConfig: baseConfig)
        if let workspaceName { c.workspaceStore = WorkspaceStore(tab: c, name: workspaceName) }

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window
        let parentController = parent?.windowController as? TerminalController
        if let parentController {
            c.isBackgroundOpaque = parentController.isBackgroundOpaque
        }

        // Whether the parent's Window is fullscreen is read from its shown Tab, since a
        // hidden or unselected Tab's own window doesn't say (SPEC §2.6, §14).
        let fullscreenParent = parentController?.workspaceStore.shownTab?.window ?? parent
        if let fullscreenParent, fullscreenParent.styleMask.contains(.fullScreen) {
            // If our previous window was fullscreen then we want our new window to
            // be fullscreen. This behavior actually doesn't match the native tabbing
            // behavior of macOS apps where new windows create tabs when in native
            // fullscreen but this is how we've always done it. This matches iTerm2
            // behavior.
            c.toggleFullscreen(mode: .native)
        } else if let fullscreenMode = ghostty.config.windowFullscreen {
            switch fullscreenMode {
            case .native:
                // Native has to be done immediately so that our stylemask contains
                // fullscreen for the logic later in this method.
                c.toggleFullscreen(mode: .native)

            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                // If we're non-native then we have to do it on a later loop
                // so that the content view is setup.
                DispatchQueue.main.async {
                    c.toggleFullscreen(mode: fullscreenMode)
                }
            }
        }

        c.scheduleInitialPresentation {
            // We're dispatching this async because in some cases AppKit will tab this window,
            // although we have a check in `windowDidLoad` and it works in most cases, but not for AppIntent
            //
            // That weird tabbing behavior only happens in the following cases at the point of writing.
            // - Creating a window via the Shortcuts app for now.
            // - Creating a window via `New Ghostty Window Here` service.
            c.showWindowSafely(self)

            // Only cascade if we aren't fullscreen.
            if let window = c.window {
                if !window.styleMask.contains(.fullScreen) {
                    let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                    // We're dispatching this async because otherwise the lastCascadePoint doesn't
                    // take effect after positioning in `showWindow`. Our best theory is there is
                    // some next-event-loop-tick logic that Cocoa is doing that we need to be after.
                    DispatchQueue.main.async {
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }

            // All new_window actions force our app to be active, so that the new
            // window is focused and visible.
            NSApp.activate(ignoringOtherApps: true)
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent,
                        workspaceName: workspaceName)
                }
            }
        }

        return c
    }

    /// Create a new window with an existing split tree.
    /// The window will be sized to match the tree's current view bounds if available.
    /// - Parameters:
    ///   - ghostty: The Ghostty app instance.
    ///   - tree: The split tree to use for the new window.
    ///   - position: Optional screen position (top-left corner) for the new window.
    ///               If nil, the window will cascade from the last cascade point.
    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil
    ) -> TerminalController {
        // Calculate the target frame based on the tree's view bounds
        // before moving into the new window
        let treeSize: CGSize? = tree.root?.viewBounds()

        let c = TerminalController.init(ghostty, withSurfaceTree: tree)
        if let inheritBackgroundOpacity {
            c.isBackgroundOpaque = inheritBackgroundOpacity
        }

        // Showing window in current event loop works so far with dragging surface into
        // a new window, but remember to defer the cascade when you move it inside
        // `scheduleInitialPresentation` to solve other issues in the future.
        c.showWindowSafely(self)
        c.scheduleInitialPresentation {
            if let window = c.window {
                // If we have a tree size, resize the window's content to match
                if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                    window.setContentSize(treeSize)
                    window.constrainToScreen()
                }

                if !window.styleMask.contains(.fullScreen) {
                    if let position {
                        window.setFrameTopLeftPoint(position)
                        window.constrainToScreen()
                    } else {
                        let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        tree: tree,
                        inheritBackgroundOpacity: inheritBackgroundOpacity
                    )
                }
            }
        }

        return c
    }

    /// A new Tab in `parent`'s shown Workspace. Without a `parent`, a new Window opens, and
    /// its one Workspace is `workspaceName`, by default "Workspace 1" (SPEC §1.2).
    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        workspaceName: String? = nil
    ) -> TerminalController? {
        // Making sure that we're dealing with a TerminalController. If not,
        // then we just create a new window.
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent, workspaceName: workspaceName)
        }

        // A Tab opened from a hidden Split joins its Workspace out of sight, and booTTY
        // isn't activated (SPEC §14).
        if parentController.isHidden {
            let controller = parentController.workspaceStore.newHiddenTab(
                beside: parentController, withBaseConfig: baseConfig)
            if let controller {
                registerUndoForNewTab(controller, from: parent, of: parentController, withBaseConfig: baseConfig)
            }
            return controller
        }

        // If our parent is in non-native fullscreen, then new tabs do not work.
        // See: https://github.com/mitchellh/ghostty/issues/392
        if let fullscreenStyle = parentController.fullscreenStyle,
           fullscreenStyle.isFullscreen && !fullscreenStyle.supportsTabs {
            let alert = NSAlert()
            alert.messageText = "Cannot Create New Tab"
            alert.informativeText = "New tabs are unsupported while in non-native fullscreen. Exit fullscreen and try again."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: parent)
            return nil
        }

        // Create a new window and add it to the parent
        let controller = TerminalController.init(
            ghostty, withBaseConfig: baseConfig, windowStyle: parentController.windowStyle)
        controller.isBackgroundOpaque = parentController.isBackgroundOpaque
        guard let window = controller.window else { return controller }

        // If the parent is miniaturized, then macOS exhibits really strange behaviors
        // so we have to bring it back out.
        if parent.isMiniaturized { parent.deminiaturize(self) }

        // If our parent tab group already has this window, macOS added it and
        // we need to remove it so we can set the correct order in the next line.
        // If we don't do this, macOS gets really confused and the tabbedWindows
        // state becomes incorrect.
        //
        // At the time of writing this code, the only known case this happens
        // is when the "+" button is clicked in the tab bar.
        if let tg = parent.tabGroup,
           tg.windows.firstIndex(of: window) != nil {
            tg.removeWindow(window)
        }

        // If we don't allow tabs then we create a new window instead.
        if window.tabbingMode != .disallowed {
            let tabCreated: Bool
            // Add the window to the tab group and show it.
            switch ghostty.config.windowNewTabPosition {
            case "end":
                // If we already have a tab group and we want the new tab to open at the end,
                // then we use the last window in the tab group as the parent.
                if let last = parent.tabGroup?.windows.last {
                    tabCreated = last.addTabbedWindowSafely(window, ordered: .above)
                } else {
                    fallthrough
                }

            case "current": fallthrough
            default:
                tabCreated = parent.addTabbedWindowSafely(window, ordered: .above)
            }
            if tabCreated {
                // Cmd+T joins the shown Workspace.
                controller.workspaceStore = parentController.workspaceStore

                // We set the selectedWindow early here because we want the next window
                // to become first responder as quickly as possible. Usually this is
                // set while `-[NSWindowController showWindow:]` is called, but we're
                // dispatching it to resolve other issues.
                parent.tabGroup?.selectedWindow = window
            }
        }

        // showWindow makes regular windows key and ordered front. AppKit can
        // throw while selecting a tab if its fullscreen stack is inconsistent,
        // so this must cross the Objective-C exception bridge.
        // We don't need to dispatch this because `tabbingMode = .disallowed`
        // for HiddenTitlebarTerminalWindow.
        controller.showWindowSafely(self)

        // Windows with `macos-titlebar-style = hidden` create new windows when the
        // new tab binding is pressed, we should cascade those windows as well.

        // We're dispatching this async because otherwise the lastCascadePoint doesn't
        // take effect after position in `showWindow`. Our best theory is there is some
        // next-event-loop-tick logic that Cocoa is doing that we need to be after.
        controller.scheduleInitialPresentation {
            // Only cascade if we aren't fullscreen and are alone in the tab group.
            if !window.styleMask.contains(.fullScreen) &&
                window.tabGroup?.windows.count ?? 1 == 1 {
                let hasFixedPos = controller.derivedConfig.windowPositionX != nil && controller.derivedConfig.windowPositionY != nil
                Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
            }

            // We also activate our app so that it becomes front. This may be
            // necessary for the dock menu.
            NSApp.activate(ignoringOtherApps: true)
        }

        // It takes an event loop cycle until the macOS tabGroup state becomes
        // consistent which causes our tab labeling to be off when the "+" button
        // is used in the tab bar. This fixes that. If we can find a more robust
        // solution we should do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            controller.relabelTabs()
        }

        registerUndoForNewTab(controller, from: parent, of: parentController, withBaseConfig: baseConfig)

        return controller
    }

    /// Registers Undo New Tab: undo closes `controller`, and redo opens another Tab from
    /// `parent` the same way.
    private static func registerUndoForNewTab(
        _ controller: TerminalController,
        from parent: NSWindow,
        of parentController: TerminalController,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration?
    ) {
        guard let undoManager = parentController.undoManager else { return }
        undoManager.setActionName("New Tab")
        undoManager.registerUndo(
            withTarget: controller,
            expiresAfter: controller.undoExpiration
        ) { target in
            // Close the tab when undoing
            target.showForUndo()
            undoManager.disableUndoRegistration {
                target.closeTab(nil)
            }

            // Register redo action
            undoManager.registerUndo(
                withTarget: target.ghostty,
                expiresAfter: target.undoExpiration
            ) { ghostty in
                if let tab = parent.windowController as? TerminalController {
                    tab.showForUndo()
                    // Joining the shown Workspace leaves non-native fullscreen first (SPEC §16).
                    if !tab.isHidden { tab.workspaceStore.leaveNonNativeFullscreen() }
                }
                _ = TerminalController.newTab(
                    ghostty,
                    from: parent,
                    withBaseConfig: baseConfig)
            }
        }
    }

    // MARK: - Methods

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // If this is an app-level config update then we update some things.
        if notification.object == nil {
            // Update our derived config
            self.derivedConfig = DerivedConfig(config)

            // If we have no surfaces in our window (is that possible?) then we update
            // our window appearance based on the root config. If we have surfaces, we
            // don't call this because focused surface changes will trigger appearance updates.
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }

            return
        }
        /// Surface-level config will be updated in
        /// ``Ghostty/Ghostty/SurfaceView/derivedConfig`` then
        /// ``TerminalController/focusedSurfaceDidChange(to:)``
    }

    /// Update the accessory view of each tab according to the keyboard
    /// shortcut that activates it (if any). This is called when the key window
    /// changes, when a window is closed, and when tabs are reordered
    /// with the mouse.
    func relabelTabs() {
        // We only listen for frame changes if we have more than 1 window,
        // otherwise the accessory view doesn't matter.
        tabListenForFrame = window?.tabbedWindows?.count ?? 0 > 1

        if let windows = window?.tabbedWindows as? [TerminalWindow] {
            for (tab, window) in zip(1..., windows) {
                // We need to clear any windows beyond this because they have had
                // a keyEquivalent set previously.
                guard tab <= 9 else {
                    window.keyEquivalent = ""
                    continue
                }

                if let equiv = ghostty.config.keyboardShortcut(for: "goto_tab:\(tab)") {
                    window.keyEquivalent = "\(equiv)"
                } else {
                    window.keyEquivalent = ""
                }
            }
        }
    }

    private func fixTabBar() {
        // We do this to make sure that the tab bar will always re-composite. If we don't,
        // then the it will "drag" pieces of the background with it when a transparent
        // window is moved around.
        //
        // There might be a better way to make the tab bar "un-lazy", but I can't find it.
        if let window = window, !window.isOpaque {
            window.isOpaque = true
            window.isOpaque = false
        }
    }

    @objc private func onFrameDidChange(_ notification: NSNotification) {
        // This is a huge hack to set the proper shortcut for tab selection
        // on tab reordering using the mouse. There is no event, delegate, etc.
        // as far as I can tell for when a tab is manually reordered with the
        // mouse in a macOS-native tab group, so the way we detect it is setting
        // the accessoryView "postsFrameChangedNotification" to true, listening
        // for the view frame to change, comparing the windows list, and
        // relabeling the tabs.
        guard tabListenForFrame else { return }
        guard let v = self.window?.tabbedWindows?.hashValue else { return }
        guard tabWindowsHash != v else { return }
        tabWindowsHash = v
        self.relabelTabs()
    }

    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Let our window handle its own appearance
        guard let window = window as? TerminalWindow else { return }

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // Call this last in case it uses any of the properties above.
        window.syncAppearance(surfaceConfig)
        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: window.preferredBackgroundColor)
    }

    /// Adjusts the given frame for the configured window position.
    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        // Return our new origin
        var result = frame
        result.origin = safeOrigin
        return result
    }

    /// The Tabs of this one's Workspace, in tab order, this one included. Decisions
    /// about which Tabs sit beside this one read this, never the tab group. A shown
    /// Tab's are the live tab group's.
    var groupedTabs: [NSWindow] {
        guard let window else { return [] }
        if let workspace = workspaceStore.hiddenWorkspace(holding: self) {
            return workspace.hiddenTabs.compactMap(\.window)
        }
        return window.tabGroup?.windows ?? [window]
    }

    /// How many Tabs this one's Workspace holds: `groupedTabs`, except that in non-native
    /// fullscreen the shown Workspace's are the windowed group's plus the fullscreen Tab,
    /// which has left that group (SPEC §3).
    private var workspaceTabCount: Int {
        let store = workspaceStore
        store.reconcile()
        guard !isHidden, store.isInNonNativeFullscreen else { return groupedTabs.count }
        return store.tabs(of: store.shownID).count
    }

    /// Whether this is the only Tab of its Window's only Workspace, so closing it closes
    /// the Window (SPEC §13.2).
    var isOnlyTabInWindow: Bool { workspaceTabCount <= 1 && workspaceStore.workspaces.count <= 1 }

    override var isHidden: Bool { workspaceStore.isHidden(self) }

    /// Where a sheet about this Tab goes: the Tab itself, or for a hidden Tab its Window's
    /// shown Tab (SPEC §2.5).
    private var sheetTab: TerminalController {
        isHidden ? workspaceStore.shownTab ?? self : self
    }

    /// " in the hidden Workspace “api”" for a hidden Tab, else "". A confirmation names a
    /// hidden Tab's Workspace right after its subject (SPEC §13.8).
    private var hiddenWorkspacePhrase: String {
        guard let name = workspaceStore.hiddenWorkspace(holding: self)?.name else { return "" }
        return " in the hidden Workspace “\(name)”"
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            // A hidden Split asks on the Window's shown Tab, naming its Workspace.
            guard withConfirmation, isHidden, surfaceTree.contains(node) else {
                super.closeSurface(node, withConfirmation: withConfirmation)
                return
            }

            sheetTab.confirmClose(
                messageText: "Close Terminal?",
                informativeText: "The terminal\(hiddenWorkspacePhrase) still has a running process. If you close the terminal the process will be killed."
            ) { [weak self] in
                self?.removeSurfaceNode(node)
            }
            return
        }

        // Closing one of several Tabs closes just that Tab.
        if !isOnlyTabInWindow {
            if withConfirmation {
                closeTab(nil)
            } else {
                closeTabImmediately()
            }
            return
        }

        // 1 window, closing the window
        if withConfirmation {
            closeWindow(nil)
        } else {
            closeWindowImmediately()
        }
    }

    func closeTabImmediately(registerRedo: Bool = true, showing neighbor: WorkspaceStore.Workspace.ID? = nil) {
        guard let window = window else { return }
        guard !isOnlyTabInWindow else {
            closeWindowImmediately()
            return
        }

        cancelPendingInitialPresentation()

        // Captured while the Tab is still where it was, before a switch hides it.
        let undoState = self.undoState

        // The shown Workspace's last Tab ends it. The neighbor is shown first, so the live
        // group never empties and the Window stays (SPEC §13); non-native fullscreen has no
        // group to switch, so the Window leaves it before that (§13.6). If that switch can't
        // run, the Window closes, as for a lone Tab.
        if workspaceTabCount <= 1, !isHidden {
            let store = workspaceStore
            let next = neighbor.flatMap { id in
                id != store.shownID && store.workspaces.contains { $0.id == id } ? id : nil
            } ?? store.neighborID
            store.leaveNonNativeFullscreen()
            guard let next, store.show(next) else {
                closeWindowImmediately()
                return
            }
        }

        // Undo
        if let undoManager, let undoState {
            // Register undo action to restore the tab
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: ghostty,
                expiresAfter: undoExpiration
            ) { ghostty in
                let newController = TerminalController(ghostty, with: undoState)

                if registerRedo {
                    undoManager.registerUndo(
                        withTarget: newController,
                        expiresAfter: newController.undoExpiration
                    ) { target in
                        target.showForUndo()
                        target.closeTabImmediately()
                    }
                }
            }
        }

        window.close()
    }

    private func closeOtherTabsImmediately() {
        guard groupedTabs.count > 1 else { return }

        // Start an undo grouping
        if let undoManager {
            undoManager.beginUndoGrouping()
        }
        defer {
            undoManager?.endUndoGrouping()
        }

        // Iterate through all tabs except the current one.
        for window in groupedTabs where window != self.window {
            // We ignore any non-terminal tabs. They don't currently exist and we can't
            // properly undo them anyways so I'd rather ignore them and get a bug report
            // later if and when we introduce non-terminal tabs.
            if let controller = window.windowController as? TerminalController {
                // We must not register a redo, because it messes with our own redo
                // that we register later.
                controller.closeTabImmediately(registerRedo: false)
            }
        }

        if let undoManager {
            undoManager.setActionName("Close Other Tabs")

            // We need to register an undo that refocuses this window. Otherwise, the
            // undo operation above for each tab will steal focus. A hidden Tab stays
            // out of sight.
            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    if !target.isHidden { target.window?.makeKeyAndOrderFront(nil) }
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeOtherTabsImmediately()
                }
            }
        }
    }

    private func closeTabsOnTheRightImmediately() {
        guard let window = window else { return }
        let tabs = groupedTabs
        guard let currentIndex = tabs.firstIndex(of: window) else { return }

        let tabsToClose = tabs.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
        }

        for (_, candidate) in tabsToClose {
            if let controller = candidate.windowController as? TerminalController {
                controller.closeTabImmediately(registerRedo: false)
            }
        }

        if let undoManager {
            undoManager.setActionName("Close Tabs to the Right")

            undoManager.registerUndo(
                withTarget: self,
                expiresAfter: undoExpiration
            ) { target in
                DispatchQueue.main.async {
                    if !target.isHidden { target.window?.makeKeyAndOrderFront(nil) }
                }

                undoManager.registerUndo(
                    withTarget: target,
                    expiresAfter: target.undoExpiration
                ) { target in
                    target.closeTabsOnTheRightImmediately()
                }
            }
        }
    }

    /// Every Tab of this Window, by Workspace in bar order, hidden Workspaces included: what
    /// Close Window checks, closes, and brings back (SPEC §13.2). The shown Workspace's are its
    /// live group's plus a Tab in non-native fullscreen, or this Tab alone while the store has
    /// no group, which only a Window without hidden Workspaces lacks.
    private var windowTabs: [(workspace: WorkspaceStore.Workspace, tabs: [TerminalController])] {
        let store = workspaceStore
        store.reconcile()
        let shown = store.tabs(of: store.shownID)
        return store.workspaces.map { workspace in
            (workspace, workspace.id != store.shownID ? workspace.hiddenTabs : shown.isEmpty ? [self] : shown)
        }
    }

    /// This Tab's Window's shown Tab, where Close Window, Close All Windows, and Quit ask about
    /// the whole Window (SPEC §13), or this Tab while the store has no group to find it in.
    var windowShownTab: TerminalController {
        workspaceStore.reconcile()
        return workspaceStore.shownTab ?? self
    }

    /// Close Window without asking (SPEC §13.2): closes every Tab of every Workspace of this
    /// Window and registers Undo Close Window.
    func closeWindowImmediately() {
        guard window != nil else { return }

        let workspaces = windowTabs
        registerUndoForCloseWindow(workspaces)

        for tab in workspaces.flatMap(\.tabs) {
            tab.cancelPendingInitialPresentation()
            // Clear out the surfacetree to ensure there is no undo state.
            // This prevents unnecessary undos registered since AppKit may
            // process them on later ticks so we can't just disable undo registration.
            tab.surfaceTree = .init()
            tab.window?.close()
        }
    }

    /// What Undo Close Window keeps of one of the Window's Workspaces.
    private struct ClosedWorkspace {
        let saved: WorkspaceStore.UndoState
        let tabs: [UndoState]
        /// The index in `tabs` of the Tab it showed, or remembered while hidden.
        let selected: Int?
    }

    /// Registers Undo Close Window (SPEC §16) for the Window's `workspaces`: it reopens the
    /// Window with its Window id and every Workspace, each with its id, name, original name,
    /// color, Tabs, and selected or remembered Tab, and the same one shown.
    private func registerUndoForCloseWindow(_ workspaces: [(workspace: WorkspaceStore.Workspace, tabs: [TerminalController])]) {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }

        let store = workspaceStore
        let shownTab = store.shownTab ?? self
        let closed = workspaces.compactMap { workspace, tabs -> ClosedWorkspace? in
            let kept = tabs.compactMap { tab -> (tab: TerminalController, state: UndoState)? in
                guard var state = tab.undoState else { return nil }
                // It comes back with its Window, not into a Workspace of a live one.
                state.workspace = nil
                return (tab, state)
            }
            guard !kept.isEmpty, let saved = store.undoState(of: workspace.id) else { return nil }
            let selected = workspace.id == store.shownID ? shownTab : workspace.rememberedTab
            return ClosedWorkspace(saved: saved, tabs: kept.map(\.state), selected: kept.firstIndex { $0.tab === selected })
        }
        guard !closed.isEmpty else { return }
        let shown = closed.firstIndex { $0.saved.id == store.shownID } ?? 0
        let windowID = store.id

        undoManager.setActionName("Close Window")
        undoManager.registerUndo(
            withTarget: ghostty,
            expiresAfter: undoExpiration
        ) { ghostty in
            guard let tab = Self.reopenWindow(windowID, closed, shown: shown, ghostty: ghostty) else { return }

            // Register redo action
            undoManager.registerUndo(
                withTarget: tab,
                expiresAfter: tab.undoExpiration
            ) { target in
                target.closeWindowImmediately()
            }
        }
    }

    /// Undo Close Window: reopens Window `id` with `closed`'s Workspaces in bar order, the one at
    /// `shown` shown and the others hidden. Returns its first shown Tab.
    private static func reopenWindow(
        _ id: UUID,
        _ closed: [ClosedWorkspace],
        shown: Int,
        ghostty: Ghostty.App
    ) -> TerminalController? {
        // The shown Tabs each open as a window, then tab in after the first, in order.
        let controllers = closed[shown].tabs.map { TerminalController(ghostty, with: $0) }
        guard let first = controllers.first else { return nil }
        let store = WorkspaceStore(id: id, tab: first)
        for (index, controller) in controllers.enumerated() {
            controller.workspaceStore = store
            if index > 0, let previous = controllers[index - 1].window, let window = controller.window {
                previous.addTabbedWindowSafely(window, ordered: .above)
            }
        }

        store.bringBack(closed.enumerated().map { index, entry in
            let tabs = index == shown ? [] : entry.tabs.map { TerminalController(ghostty, rebuilding: $0) }
            var workspace = WorkspaceStore.Workspace(id: entry.saved.id, name: entry.saved.name, hiddenTabs: tabs)
            workspace.originalName = entry.saved.originalName
            workspace.color = entry.saved.color
            if let selected = entry.selected, tabs.indices.contains(selected) {
                workspace.rememberedTab = tabs[selected]
            }
            return workspace
        }, shown: closed[shown].saved.id)

        let selected = closed[shown].selected.map { controllers[$0] } ?? controllers.last
        selected?.window?.makeKeyAndOrderFront(nil)
        store.reconcile()
        return first
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        // The alert goes on the shown Tab of the first Window that would ask (SPEC §13.4).
        guard let confirmWindow = all
            .first(where: { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) })?
            .windowShownTab.window
        else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        // Each Window once: Close Window closes all of its Workspaces.
        var closed = Set<ObjectIdentifier>()
        for tab in all where closed.insert(ObjectIdentifier(tab.workspaceStore)).inserted {
            tab.closeWindowImmediately()
        }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let surfaceTree: SplitTree<Ghostty.SurfaceView>
        let focusedSurface: UUID?
        /// The Tab's index in its Workspace.
        let tabIndex: Int?
        /// The Tab's Workspace, to put the Tab back in. Nil reopens it as a Window of its own.
        var workspace: WorkspaceStore.UndoState?
        let tabColor: TerminalTabColor
        let windowStyle: WindowStyle
    }

    /// A Tab rebuilt from `undoState`, its window loaded but not placed or shown.
    convenience init(_ ghostty: Ghostty.App, rebuilding undoState: UndoState) {
        self.init(ghostty, withSurfaceTree: undoState.surfaceTree, windowStyle: undoState.windowStyle)
        guard let window else { return }

        // Focus goes back to the Split that had it, else the first. It's set before the Tab
        // goes back, so a switch that shows it focuses that Split.
        focusedSurface = undoState.focusedSurface.flatMap { id in surfaceTree.first { $0.id == id } }
            ?? surfaceTree.first
        if let terminalWindow = window as? TerminalWindow {
            terminalWindow.tabColor = undoState.tabColor
        }
        window.setFrame(undoState.frame, display: false)
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: UndoState) {
        self.init(ghostty, rebuilding: undoState)
        guard let window else { return }
        let focusTarget = focusedSurface

        // Back into its Workspace while its Window is open, else a Window of its own.
        if let saved = undoState.workspace, let store = WorkspaceStore.live(saved.windowID) {
            if store.returnTab(self, to: saved, at: undoState.tabIndex) {
                if let focusTarget, !isHidden {
                    DispatchQueue.main.async { Ghostty.moveFocus(to: focusTarget, from: nil) }
                }
                return
            }
        }

        showWindow(nil)
        window.setFrame(undoState.frame, display: true)
        if let focusTarget {
            DispatchQueue.main.async { Ghostty.moveFocus(to: focusTarget, from: nil) }
        }
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard !surfaceTree.isEmpty else { return nil }
        return .init(
            frame: window.frame,
            surfaceTree: surfaceTree,
            focusedSurface: focusedSurface?.id,
            tabIndex: groupedTabs.firstIndex(of: window),
            workspace: workspaceStore.undoState(of: workspaceStore.workspace(holding: self).id),
            tabColor: (window as? TerminalWindow)?.tabColor ?? .none,
            windowStyle: windowStyle)
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        // I copy this because we may change the source in the future but also because
        // I regularly audit our codebase for "ghostty.config" access because generally
        // you shouldn't use it. Its safe in this case because for a new window we should
        // use whatever the latest app-level config is.
        let config = ghostty.config

        // Setting all three of these is required for restoration to work.
        window.isRestorable = restorable
        if restorable {
            window.restorationClass = TerminalWindowRestoration.self
            window.identifier = .init(String(describing: TerminalWindowRestoration.self))
        }

        // If we have only a single surface (no splits) and there is a default size then
        // we should resize to that default size.
        if case let .leaf(view) = surfaceTree.root {
            // If this is our first surface then our focused surface will be nil
            // so we force the focused surface to the leaf.
            focusedSurface = view
        }

        // Initialize our content view to the SwiftUI root. Window styles that support
        // it get a vertical tab bar beside the terminal when the tab bar is on a side.
        let terminalWindow = window as? TerminalWindow
        let verticalTabBar = terminalWindow?.supportsVerticalTabBar == true ? terminalWindow?.verticalTabBar : nil
        let container = TerminalViewContainer {
            VerticalTabBarLayout(model: verticalTabBar) {
                TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
            }
        }

        // Set the initial content size on the container so that
        // intrinsicContentSize returns the correct value immediately,
        // without waiting for @FocusedValue to propagate through the
        // SwiftUI focus chain. A vertical tab bar adds to the terminal size.
        let tabBarWidth = terminalWindow?.showsVerticalTabBar == true ? TabBarSettings.shared.verticalWidth : 0
        container.initialContentSize = focusedSurface?.initialSize.map {
            NSSize(width: $0.width + tabBarWidth, height: $0.height)
        }

        window.contentView = container

        // The tab shows its most urgent agent status. This emits the current value
        // right away, so tabs moved into a new window keep their ring.
        agentStatusCancellable = surfaceValuesPublisher(
            valueKeyPath: \.agentStatus,
            publisherKeyPath: \.$agentStatus
        )
            .map { $0.values.compactMap { $0 }.max() }
            .removeDuplicates()
            .sink { [weak terminalWindow] in terminalWindow?.agentStatus = $0 }

        // If we have a default size, we want to apply it.
        if let defaultSize {
            defaultSize.apply(to: window)

            if case .contentIntrinsicSize = defaultSize {
                if let screen = window.screen ?? NSScreen.main {
                    let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                    window.setFrameOrigin(frame.origin)
                }
            }
        }

        // In various situations, macOS automatically tabs new windows. Ghostty handles
        // its own tabbing so we DONT want this behavior. This detects this scenario and undoes
        // it.
        //
        // Example scenarios where this happens:
        //   - When the system user tabbing preference is "always"
        //   - When the "+" button in the tab bar is clicked
        //
        // We don't run this logic in fullscreen because in fullscreen this will end up
        // removing the window and putting it into its own dedicated fullscreen, which is not
        // the expected or desired behavior of anyone I've found.
        //
        // We also only run this when the system tabbing preference is "always",
        // which is the only scenario AppKit will have auto-tabbed a fresh window
        // at this point: the tab bar "+" button goes through newWindowForTab
        // which we route through our own tab logic. This check matters because
        // accessing `window.tabGroup` materializes the window's tab group
        // machinery, which takes ~15-20ms and is otherwise not needed during
        // window creation.
        if NSWindow.userTabbingPreference == .always,
           !window.styleMask.contains(.fullScreen) {
            // If we have more than 1 window in our tab group we know we're a new window.
            // Since Ghostty manages tabbing manually this will never be more than one
            // at this point in the AppKit lifecycle (we add to the group after this).
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                window.tabGroup?.removeWindow(window)
            }
        }

        // Apply any additional appearance-related properties to the new window. We
        // apply this based on the root config but change it later based on surface
        // config (see focused surface change callback).
        syncAppearance(.init(config))
    }

    /// Setup correct window frame before showing the window
    override func showWindow(_ sender: Any?) {
        guard let terminalWindow = window as? TerminalWindow else { return }

        // Set the initial window position. This must happen after the window
        // is fully set up (content view, toolbar, default size) so that
        // decorations added by subclass awakeFromNib (e.g. toolbar for tabs
        // style) don't change the frame after the position is restored.
        let originChanged = terminalWindow.setInitialWindowPosition(
            x: derivedConfig.windowPositionX,
            y: derivedConfig.windowPositionY,
        )
        let restored = LastWindowPosition.shared.restore(
            terminalWindow,
            origin: !originChanged,
            size: defaultSize == nil,
        )

        // If nothing is changed for the frame,
        // we should center the window
        if !originChanged, !restored {
            // This doesn't work in `windowDidLoad` somehow
            terminalWindow.center()
        }

        super.showWindow(sender)

        syncAppearance()
    }

    // Shows the "+" button in the tab bar, responds to that click.
    override func newWindowForTab(_ sender: Any?) {
        // Trigger the ghostty core event logic for a new tab.
        guard let surface = self.focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    // MARK: NSWindowDelegate

    // TabGroupCloseCoordinator.Controller
    lazy private(set) var tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        tabGroupCloseCoordinator.windowShouldClose(sender) { [weak self] scope in
            guard let self else { return }
            switch scope {
            case .tab: closeTab(nil)
            case .window:
                guard self.window?.isFirstWindowInTabGroup ?? false else { return }
                closeWindow(nil)
            }
        }

        // We will always explicitly close the window using the above
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        cancelPendingInitialPresentation()
        workspaceStore.removeHiddenTab(self)
        self.relabelTabs()

        // If we remove a window, we reset the cascade point to the key window so that
        // the next window cascade's from that one.
        if let focusedWindow = NSApplication.shared.keyWindow {
            // If we are NOT the focused window, then we are a tabbed window. If we
            // are closing a tabbed window, we want to set the cascade point to be
            // the next cascade point from this window.
            if focusedWindow != window {
                // The cascadeTopLeft call below should NOT move the window. Starting with
                // macOS 15, we found that specifically when used with the new window snapping
                // features of macOS 15, this WOULD move the frame. So we keep track of the
                // old frame and restore it if necessary. Issue:
                // https://github.com/ghostty-org/ghostty/issues/2565
                let oldFrame = focusedWindow.frame

                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: .zero)

                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }

                return
            }

            // If we are the focused window, then we set the last cascade point to
            // our own frame so that it shows up in the same spot.
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        self.relabelTabs()
        self.fixTabBar()
        workspaceStore.reconcile()
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)
        self.fixTabBar()

        // Whenever we move save our last position for the next start.
        LastWindowPosition.shared.save(window)
        workspaceStore.recordShownFrame()
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)

        // Whenever we resize save our last position and size for the next start.
        LastWindowPosition.shared.save(window)
        workspaceStore.recordShownFrame()

        if let window = self.window as? TerminalWindow {
            // Expand the title frame to new width.
            // This is needed because when the new window size becomes bigger,
            // window's title will be clipped again.
            window.syncWindowTitleAppearance()
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Whenever we get focused, use that as our last window position for
        // restart. This differs from Terminal.app but matches iTerm2 behavior
        // and I think its sensible.
        LastWindowPosition.shared.save(window)

        // Remember our last main
        Self.lastMain = self
    }

    // Called when the window will be encoded. We handle the data encoding here in the
    // window controller.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let data = TerminalRestorableState(from: self)
        data.encode(with: state)
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        closeTab(showing: nil)
    }

    /// Close Tab, asking first when a Split would. `neighbor` is the Workspace shown if this
    /// ends the shown Workspace; nil, or one that has ended, means its neighbor.
    func closeTab(showing neighbor: WorkspaceStore.Workspace.ID?) {
        guard !isOnlyTabInWindow else {
            closeWindow(nil)
            return
        }

        guard surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately(showing: neighbor)
            return
        }

        sheetTab.confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal\(hiddenWorkspacePhrase) still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabImmediately(showing: neighbor)
        }
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        // If the Workspace has only this Tab then there are no other tabs to close
        guard groupedTabs.count > 1 else { return }

        // Check if we have to confirm close.
        guard groupedTabs.contains(where: { window in
            // Ignore ourself
            if window == self.window { return false }

            // Ignore non-terminals
            guard let controller = window.windowController as? TerminalController else {
                return false
            }

            // Check if any surfaces require confirmation
            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }) else {
            self.closeOtherTabsImmediately()
            return
        }

        sheetTab.confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab\(hiddenWorkspacePhrase) still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        guard let window = window else { return }
        let tabs = groupedTabs
        guard let currentIndex = tabs.firstIndex(of: window) else { return }

        let tabsToClose = tabs.enumerated().filter { $0.offset > currentIndex }
        guard !tabsToClose.isEmpty else { return }

        let needsConfirm = tabsToClose.contains { (_, candidate) in
            guard let controller = candidate.windowController as? TerminalController else {
                return false
            }

            return controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }

        if !needsConfirm {
            self.closeTabsOnTheRightImmediately()
            return
        }

        sheetTab.confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right\(hiddenWorkspacePhrase) still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    /// Close Window (SPEC §13.2): asks once, on the shown Tab, when any Tab of any Workspace
    /// would, naming the hidden Workspaces that would; else closes silently.
    @IBAction override func closeWindow(_ sender: Any?) {
        guard window != nil else { return }

        let asks: (TerminalController) -> Bool = { $0.surfaceTree.contains(where: { $0.needsConfirmQuit }) }
        guard windowTabs.contains(where: { $0.tabs.contains(where: asks) }) else {
            closeWindowImmediately()
            return
        }

        let hidden = WorkspaceStore.hiddenWorkspacesPhrase(naming: workspaceStore.hiddenNames(where: asks))
        windowShownTab.confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated\(hidden.map { ", including those in \($0)" } ?? "").",
        ) {
            self.closeWindowImmediately()
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: - TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        // We always cancel our event listener
        surfaceAppearanceCancellables.removeAll()

        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        // We also want to get notified of certain changes to update our appearance.
        focusedSurface.$derivedConfig
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    // MARK: - Notifications

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let window = self.window else { return }

        // Get the move action
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard action.amount != 0 else { return }

        // A hidden Tab moves among its Workspace's Tabs, out of sight (SPEC §14).
        if isHidden {
            let tabs = groupedTabs
            guard let index = tabs.firstIndex(of: window) else { return }
            workspaceStore.moveHiddenTab(self, to: Self.movedTabIndex(from: index, by: action.amount, count: tabs.count))
            return
        }

        // Determine our current selected index
        guard let windowController = window.windowController else { return }
        guard let tabGroup = windowController.window?.tabGroup else { return }
        guard let selectedWindow = tabGroup.selectedWindow else { return }
        let tabbedWindows = groupedTabs
        guard tabbedWindows.count > 0 else { return }
        guard let selectedIndex = tabbedWindows.firstIndex(where: { $0 == selectedWindow }) else { return }

        // Determine the final index we want to insert our tab
        let finalIndex = Self.movedTabIndex(from: selectedIndex, by: action.amount, count: tabbedWindows.count)

        // If our index is the same we do nothing
        guard finalIndex != selectedIndex else { return }

        // Get our target window
        let targetWindow = tabbedWindows[finalIndex]

        // Moving tabs on macOS 26 RC causes very nasty visual glitches in the titlebar tabs.
        // I believe this is due to messed up constraints for our hacky tab bar. I'd like to
        // find a better workaround. For now, this improves things dramatically.
        //
        // Reproduction: titlebar tabs, create two tabs, "move tab left"
        if #available(macOS 26, *) {
            if window is TitlebarTabsTahoeTerminalWindow {
                tabGroup.removeWindow(selectedWindow)
                targetWindow.addTabbedWindowSafely(selectedWindow, ordered: action.amount < 0 ? .below : .above)
                DispatchQueue.main.async {
                    selectedWindow.makeKey()
                }

                return
            }
        }

        // Begin a group of window operations to minimize visual updates
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        // Remove and re-add the window in the correct position
        tabGroup.removeWindow(selectedWindow)
        targetWindow.addTabbedWindowSafely(selectedWindow, ordered: action.amount < 0 ? .below : .above)

        // Ensure our window remains selected
        selectedWindow.makeKey()

        NSAnimationContext.endGrouping()
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the tab index from the notification
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }

        // A hidden Workspace's remembered Tab stands in for the selected Tab, and going to a
        // Tab remembers it, out of sight (SPEC §14).
        let hiddenWorkspace = workspaceStore.hiddenWorkspace(holding: self)
        let selectedWindow = hiddenWorkspace == nil
            ? window?.tabGroup?.selectedWindow
            : hiddenWorkspace?.rememberedTab?.window
        let tabbedWindows = groupedTabs
        guard let finalIndex = Self.gotoTabIndex(
            tabEnum,
            selected: tabbedWindows.firstIndex { $0 == selectedWindow },
            count: tabbedWindows.count
        ) else { return }

        let targetWindow = tabbedWindows[finalIndex]
        if hiddenWorkspace == nil {
            targetWindow.makeKeyAndOrderFront(nil)
        } else if let tab = targetWindow.windowController as? TerminalController {
            workspaceStore.remember(tab)
        }
    }

    /// The index `goto_tab` goes to among `count` Tabs, `selected` being the selected Tab's:
    /// previous and next wrap around, last is the last, and N counts from 1 and stops at the
    /// last. Nil when there's nowhere to go.
    static func gotoTabIndex(_ tab: ghostty_action_goto_tab_e, selected: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch tab {
        case GHOSTTY_GOTO_TAB_PREVIOUS: return selected.map { ($0 + count - 1) % count }
        case GHOSTTY_GOTO_TAB_NEXT: return selected.map { ($0 + 1) % count }
        case GHOSTTY_GOTO_TAB_LAST: return count - 1
        default:
            // The configured value is 1-indexed, and other values below 1 go nowhere.
            let n = Int(tab.rawValue)
            return n >= 1 ? min(n, count) - 1 : nil
        }
    }

    /// The index a Tab at `index` among `count` Tabs moves to by `amount`. It stops at the ends.
    static func movedTabIndex(from index: Int, by amount: Int, count: Int) -> Int {
        if amount < 0 {
            return index - min(index, -amount)
        }
        return index + min(count - 1 - index, amount)
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        // Get the fullscreen mode we want to toggle
        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTabsOnTheRight):
            guard let window else { return false }
            let tabs = groupedTabs
            guard let currentIndex = tabs.firstIndex(of: window) else { return false }
            return tabs.indices.contains { $0 > currentIndex }

        case #selector(moveTabToNewWorkspace):
            // A Workspace's only Tab can't move (SPEC §11.1). A Window that can't hold Tabs
            // keeps the item and shows its alert (§7.3).
            let store = workspaceStore
            return workspacesUnavailableAlert != nil || store.tabs(of: store.workspace(holding: self).id).count > 1

        case #selector(returnToDefaultSize):
            guard let window else { return false }

            // Native fullscreen windows can't revert to default size.
            if window.styleMask.contains(.fullScreen) {
                return false
            }

            // If we're fullscreen at all then we can't change size
            if fullscreenStyle?.isFullscreen ?? false {
                return false
            }

            // If our window is already the default size or we don't have a
            // default size, then disable.
            return defaultSize?.isChanged(for: window) ?? false

        case #selector(moveWorkspaceToNewWindow):
            // Disabled for the Window's only Workspace (SPEC §7.3). A Window that can't hold
            // Workspaces keeps it enabled, so it shows "Workspaces Unavailable".
            return workspacesUnavailableAlert != nil || workspaceStore.workspaces.count > 1

        default:
            return super.validateMenuItem(item)
        }
    }
}

// MARK: Default Size

extension TerminalController {
    /// The possible default sizes for a terminal. The size can't purely be known as a
    /// window frame because if we set `window-width/height` then it is based
    /// on content size.
    enum DefaultSize {
        /// A frame, set with `window.setFrame`
        case frame(NSRect)

        /// A content size, set with `window.setContentSize`
        case contentIntrinsicSize

        func isChanged(for window: NSWindow) -> Bool {
            switch self {
            case .frame(let rect):
                return window.frame != rect
            case .contentIntrinsicSize:
                guard let view = window.contentView else {
                    return false
                }

                return view.frame.size != view.intrinsicContentSize
            }
        }

        func apply(to window: NSWindow) {
            switch self {
            case .frame(let rect):
                window.setFrame(rect, display: true)
            case .contentIntrinsicSize:
                guard let size = window.contentView?.intrinsicContentSize else {
                    return
                }

                window.setContentSize(size)
                window.constrainToScreen()
            }
        }
    }

    private var defaultSize: DefaultSize? {
        if derivedConfig.maximize, let screen = window?.screen ?? NSScreen.main {
            // Maximize takes priority, we take up the full screen we're on.
            return .frame(screen.visibleFrame)
        } else if focusedSurface?.initialSize != nil {
            // Initial size as requested by the configuration (e.g. `window-width`)
            // takes next priority.
            return .contentIntrinsicSize
        } else {
            return nil
        }
    }
}
