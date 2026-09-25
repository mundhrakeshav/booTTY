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

        var names = segments.map { name($0, parents: 0) }
        let clashes = Dictionary(grouping: keys.indices.filter { keys[$0] != nil }) { names[$0] }
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
