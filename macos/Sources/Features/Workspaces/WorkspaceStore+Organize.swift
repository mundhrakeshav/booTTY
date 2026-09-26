import AppKit

/// Organize (SPEC §10): how Tabs are keyed, grouped, and named. `organize(by:)` applies it.
extension WorkspaceStore {
    enum OrganizeMode { case repo, folder }

    /// One Workspace Organize makes.
    struct OrganizeGroup<Tab: AnyObject> {
        let name: String
        let tabs: [Tab]
        /// The Tab it remembers while hidden (SPEC §10.5).
        let rememberedTab: Tab
    }

    /// The key of a Split whose last OSC 7 pwd is `pwd` (SPEC §10.2), or nil for no pwd.
    /// By repo: the nearest folder at or above the pwd holding `.git`, a folder or a file,
    /// so each worktree and submodule is its own repo; else the pwd. By folder: the pwd.
    static func organizeKey(of pwd: String?, by mode: OrganizeMode) -> String? {
        guard let pwd, !pwd.isEmpty else { return nil }
        let folder = URL(fileURLWithPath: pwd).standardized.path
        guard mode == .repo else { return folder }

        var dir = folder
        while true {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return folder }
            dir = parent
        }
    }

    /// A Tab's Splits as Organize breaks them up (SPEC §10.3).
    struct OrganizeSplit<View: NSView & Codable & Identifiable> {
        /// The Tab's key: its focused Split's.
        let key: String?
        /// The piece holding the focused Split, which keeps the Tab: the tree with the other
        /// pieces' Splits removed, zoomed as removing them leaves it.
        let kept: SplitTree<View>
        /// One piece per other key, in split-tree order of each piece's first Split: the tree
        /// with every other Split removed, unzoomed.
        let brokenOut: [(key: String, tree: SplitTree<View>)]
    }

    /// Breaks `tree` up by `key` (SPEC §10.3). Splits sharing a key stay together in their
    /// original layout, and the piece holding `focused` (else the first Split) keeps the Tab.
    /// A Split with no key stays with that piece.
    static func organizeSplit<View>(
        _ tree: SplitTree<View>,
        focused: View?,
        key: (View) -> String?
    ) -> OrganizeSplit<View> {
        let splits = Array(tree)
        guard let anchor = splits.first(where: { $0 === focused }) ?? splits.first else {
            return OrganizeSplit(key: nil, kept: tree, brokenOut: [])
        }
        let tabKey = key(anchor)

        var keys: [String] = []
        var members: [String: [View]] = [:]
        for split in splits where split !== anchor {
            guard let key = key(split), key != tabKey else { continue }
            if members[key] == nil { keys.append(key) }
            members[key, default: []].append(split)
        }

        func removing(_ views: [View]) -> SplitTree<View> {
            views.reduce(tree) { tree, view in tree.root?.node(view: view).map(tree.removing) ?? tree }
        }
        let brokenOut = keys.map { key in
            let piece = removing(splits.filter { split in !members[key]!.contains { $0 === split } })
            return (key: key, tree: SplitTree(root: piece.root, zoomed: nil))
        }
        return OrganizeSplit(key: tabKey, kept: removing(keys.flatMap { members[$0]! }), brokenOut: brokenOut)
    }

    /// Regroups `tabs`, in the Window's order (Workspaces left to right, then Tabs top to
    /// bottom), by `key` (SPEC §10.3). The Tabs `brokenOut` of a Tab take its place, right
    /// after it, in split-tree order. Groups come in the order of their first Tab, with the
    /// unplaced Tabs (nil key) last as "Other", and keep their Tabs' order. So when groups'
    /// first Tabs share a place, the group holding the Tab itself comes first, then the ones
    /// whose first Tab broke out of it. Each group remembers its first Tab found in
    /// `remembering` (the shown Tab and the remembered Tabs), else its first Tab (§10.5).
    static func organizeGroups<Tab: AnyObject>(
        _ tabs: [Tab],
        key: (Tab) -> String?,
        brokenOut: (Tab) -> [Tab] = { _ in [] },
        remembering: [Tab],
        home: String = NSHomeDirectory()
    ) -> [OrganizeGroup<Tab>] {
        var keys: [String?] = []
        var members: [String?: [Tab]] = [:]
        for tab in tabs.flatMap({ [$0] + brokenOut($0) }) {
            let key = key(tab)
            if members[key] == nil { keys.append(key) }
            members[key, default: []].append(tab)
        }
        if let other = keys.firstIndex(where: { $0 == nil }) { keys.append(keys.remove(at: other)) }

        let names = organizeNames(keys, home: home)
        return zip(keys, names).map { key, name in
            let tabs = members[key]!
            let remembered = tabs.first { tab in remembering.contains { $0 === tab } } ?? tabs[0]
            return OrganizeGroup(name: name, tabs: tabs, rememberedTab: remembered)
        }
    }

    /// The names of groups keyed by `keys` (SPEC §10.4): each key's basename (`~` for home,
    /// `/` for the root, "Other" for nil). Groups sharing a name get parent-folder segments,
    /// nearest first, until the names differ: "app (work)", "app (home/a)", "tmp (/)".
    static func organizeNames(_ keys: [String?], home: String = NSHomeDirectory()) -> [String] {
        let home = URL(fileURLWithPath: home).standardized.path
        let segments: [[String]] = keys.map { key in
            guard let key else { return [] }
            if key == home { return ["~"] }
            if key.hasPrefix(home + "/") {
                return ["~"] + key.dropFirst(home.count + 1).split(separator: "/").map(String.init)
            }
            return ["/"] + key.split(separator: "/").map(String.init)
        }

        func name(_ segments: [String], parents count: Int) -> String {
            guard let base = segments.last else { return "Other" }
            let parents = segments.dropLast().suffix(count)
            guard !parents.isEmpty else { return base }
            // The root is one segment and isn't doubled when joined: "(/a)", not "(//a)".
            let joined = parents.first == "/" && parents.count > 1
                ? "/" + parents.dropFirst().joined(separator: "/")
                : parents.joined(separator: "/")
            return "\(base) (\(joined))"
        }

        // The unplaced group is "Other" whatever it's up against, so a folder named Other
        // takes its parent instead.
        var names = segments.map { name($0, parents: 0) }
        let clashes = Dictionary(grouping: keys.indices) { names[$0] }
        for indices in clashes.values where indices.count > 1 {
            let deepest = indices.map { segments[$0].count - 1 }.max() ?? 0
            var count = 1
            while true {
                let tried = indices.map { name(segments[$0], parents: count) }
                if Set(tried).count == indices.count || count >= deepest {
                    for (index, name) in zip(indices, tried) { names[index] = name }
                    break
                }
                count += 1
            }
        }

        return names
    }
}

extension WorkspaceStore {
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
        var keys: [ObjectIdentifier: String] = [:] // no entry: no pwd
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
        let undoCanRun = organizeUndoCanRun
        organizeUndoCanRun = nil
        defer { if organizeUndoCanRun == nil { organizeUndoCanRun = undoCanRun } }

        guard let made = breakOut(keeping: kept, into: pieces) else { return false }
        var brokenOut: [ObjectIdentifier: [TerminalController]] = [:]
        for (index, tab) in made.enumerated() {
            keys[ObjectIdentifier(tab)] = pieceKeys[index]
            brokenOut[ObjectIdentifier(pieces[index].tab), default: []].append(tab)
        }

        let groups = Self.organizeGroups(
            ordered,
            key: { keys[ObjectIdentifier($0)] },
            brokenOut: { brokenOut[ObjectIdentifier($0)] ?? [] },
            remembering: [selected] + workspaces.compactMap(\.rememberedTab))
        let organized = groups.map { group in
            Workspace(
                name: group.name,
                hiddenTabs: group.tabs,
                rememberedTab: group.tabs.contains { $0 === selected } ? selected : group.rememberedTab)
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
    /// Window, or once bringing `arrangement` back would lose a Split
    /// (`dropOrganizeUndoIfStale`).
    private func registerUndoOrganize(restoring arrangement: Arrangement, from tab: TerminalController) {
        guard let undoManager = tab.undoManager else { return }
        let tabs = tabIDs
        organizeUndoCanRun = { [unowned self] in self.tabIDs == tabs && self.restoring(arrangement) != nil }
        undoManager.setActionName("Organize")
        undoManager.registerUndo(withTarget: organizeUndoTarget, expiresAfter: tab.undoExpiration) { [weak self] _ in
            self?.restoreArrangement(arrangement)
        }
    }

    /// What bringing back `arrangement` changes, or nil unless every Split is where the entry
    /// left it, so none is lost: the Window's Tabs it doesn't hold (`extras`, broken out
    /// since), which fold back into its trees; its trees whose Tab is in the Window (`kept`);
    /// and its trees whose Tab has folded back since (`missing`), which break out again.
    private func restoring(_ arrangement: Arrangement) -> (extras: [TerminalController], kept: Trees, missing: Trees)? {
        let windowTabs = tabIDs
        let held = Set(arrangement.workspaces.flatMap(\.hiddenTabs).map(ObjectIdentifier.init))
        let extras = workspaces.flatMap { tabs(of: $0.id) }.filter { !held.contains(ObjectIdentifier($0)) }
        let missing = arrangement.trees.filter { !windowTabs.contains(ObjectIdentifier($0.tab)) }
        let kept = arrangement.trees.filter { windowTabs.contains(ObjectIdentifier($0.tab)) }
        guard extras.isEmpty || missing.isEmpty,
              held.subtracting(windowTabs) == Set(missing.map { ObjectIdentifier($0.tab) }),
              Self.splits(of: (kept.map(\.tab) + extras).map(\.surfaceTree))
                == Self.splits(of: arrangement.trees.map(\.tree))
        else { return nil }
        return (extras, kept, missing)
    }

    /// Undo or Redo Organize: leaves non-native fullscreen, brings back `arrangement`, then
    /// registers the opposite entry. Tabs broken out since fold back, and Tabs folded back
    /// since break out again (SPEC §10.3). Refused, with nothing changed, when `restoring`
    /// is nil. With a sheet on the shown Tab, the Workspace holding that Tab is shown
    /// instead, with the Tab still selected, and the Window comes forward with its sheet
    /// (§16); a shown Tab with a sheet doesn't fold back, so that refuses.
    private func restoreArrangement(_ arrangement: Arrangement) {
        reconcile()
        guard let changes = restoring(arrangement) else { return }
        let (extras, kept, missing) = changes
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
        let undoCanRun = organizeUndoCanRun
        organizeUndoCanRun = nil
        defer { if organizeUndoCanRun == nil { organizeUndoCanRun = undoCanRun } }

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

    /// Takes Undo and Redo Organize off the stack once the last one registered can't run
    /// (`organizeUndoCanRun`). Every change to the Window's Tabs ends in `reconcile()` or
    /// `invalidateRestorableState()`, and both call this, as does every Tab whose Splits
    /// change.
    func dropOrganizeUndoIfStale() {
        guard let canRun = organizeUndoCanRun, !canRun() else { return }
        organizeUndoCanRun = nil
        (NSApp.delegate as? AppDelegate)?.undoManager.removeAllActions(withTarget: organizeUndoTarget)
    }
}
