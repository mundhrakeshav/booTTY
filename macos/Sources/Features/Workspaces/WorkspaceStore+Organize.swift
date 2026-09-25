import Foundation

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

    /// Regroups `tabs`, in the Window's order (Workspaces left to right, then Tabs top to
    /// bottom), by `key` (SPEC §10.3). Groups come in the order of their first Tab, with the
    /// unplaced Tabs (nil key) last as "Other", and keep their Tabs' order. Each remembers
    /// its first Tab found in `remembering` (the shown Tab and the remembered Tabs), else its
    /// first Tab (§10.5).
    static func organizeGroups<Tab: AnyObject>(
        _ tabs: [Tab],
        key: (Tab) -> String?,
        remembering: [Tab],
        home: String = NSHomeDirectory()
    ) -> [OrganizeGroup<Tab>] {
        var keys: [String?] = []
        var members: [String?: [Tab]] = [:]
        for tab in tabs {
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
