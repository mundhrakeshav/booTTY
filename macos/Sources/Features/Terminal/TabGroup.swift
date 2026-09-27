import SwiftUI

/// A Tab group as each of its Tabs carries it: a named, colored run of side-by-side Tabs in one
/// Workspace, which the vertical tab bar lists under a header that collapses it. Not AppKit's
/// native tab group (`NSWindow.tabGroup`), which holds the shown Workspace's Tabs.
///
/// Every Tab of a group holds a copy, so a Tab takes its group wherever it's saved, restored,
/// or brought back by undo. The bar reads a run's first copy, and edits write every copy.
struct TabGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var color: TerminalTabColor
    var isCollapsed: Bool

    /// The name the bar shows: the group's own, else its color's, as in "Blue Group".
    var title: String { name.isEmpty ? "\(color.localizedName) Group" : name }

    /// The colors a group can take: the Tab palette's, without None.
    static let colors = TerminalTabColor.allCases.filter { $0 != .none }

    /// A new group's color: the first the other groups don't use, else the colors in turn.
    static func color(avoiding used: [TerminalTabColor]) -> TerminalTabColor {
        colors.first { !used.contains($0) } ?? colors[used.count % colors.count]
    }

    /// Each Tab's group once every group's Tabs sit together, for `groups`, the groups of a
    /// Workspace's Tabs in order: a group keeps its first run, and its Tabs further on leave it.
    static func whole(_ groups: [TabGroup?]) -> [TabGroup?] {
        var ended = Set<ID>()
        return groups.indices.map { i in
            if i > 0, let previous = groups[i - 1]?.id, previous != groups[i]?.id { ended.insert(previous) }
            guard let group = groups[i], !ended.contains(group.id) else { return nil }
            return group
        }
    }

    /// The group the Tab at `index` takes once moved there, for `groups`, the groups of a
    /// Workspace's Tabs in order: the group on both sides of it, else its own while it's beside
    /// another of that group's Tabs or is its only one, else none.
    static func moved(at index: Int, in groups: [TabGroup?]) -> TabGroup? {
        let before = index > 0 ? groups[index - 1] : nil
        let after = index + 1 < groups.count ? groups[index + 1] : nil
        if let before, before.id == after?.id { return before }
        guard let group = groups[index] else { return nil }
        if group.id == before?.id { return before }
        if group.id == after?.id { return after }
        return isOnly(index, in: groups) ? group : nil
    }

    /// Whether the Tab at `index` is the only one of its group among `groups`.
    static func isOnly(_ index: Int, in groups: [TabGroup?]) -> Bool {
        guard let id = groups[index]?.id else { return false }
        return !groups.indices.contains { $0 != index && groups[$0]?.id == id }
    }
}

/// Edit Group…: the popover where a Tab group gets its name and color, as Chrome's group editor
/// does. Every change applies as it's made.
struct TabGroupEditor: View {
    @ObservedObject var model: VerticalTabBarModel
    let id: TabGroup.ID

    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        if let group = model.group(id) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name This Group", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .focused($isNameFocused)
                    .onAppear {
                        name = group.name
                        // A new group opens its editor to be named, as Chrome's does.
                        DispatchQueue.main.async { isNameFocused = true }
                    }
                    .onChange(of: name) { model.renameGroup(id, to: $0) }
                    .onSubmit { model.endEditingGroup() }

                HStack(spacing: 2) {
                    ForEach(TabGroup.colors, id: \.self) { color in
                        Swatch(isSelected: color == group.color, help: color.localizedName) {
                            model.setGroupColor(id, to: color)
                        } fill: {
                            Circle().fill(color.displayColor.map { Color(nsColor: $0) } ?? .clear)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 238)
        }
    }
}
