import AppKit
import Testing
@testable import Ghostty

@MainActor
struct TabGroupTests {
    private let a = TabGroup(id: UUID(), name: "api", color: .blue, isCollapsed: false)
    private let b = TabGroup(id: UUID(), name: "", color: .red, isCollapsed: false)

    // MARK: Keeping groups whole

    /// A group keeps its first run of Tabs; its Tabs further on leave it, and nothing else changes.
    @Test func groupKeepsItsFirstRun() {
        #expect(TabGroup.whole([a, a, nil, a, b, b, a]) == [a, a, nil, nil, b, b, nil])
        #expect(TabGroup.whole([nil, a, a, b]) == [nil, a, a, b])
    }

    // MARK: Moving a Tab

    /// A Tab moved between two Tabs of a group joins it, so the group stays whole.
    @Test func movedTabJoinsTheGroupAroundIt() {
        #expect(TabGroup.moved(at: 1, in: [a, nil, a]) == a)
        #expect(TabGroup.moved(at: 1, in: [a, b, a]) == a)
    }

    /// A Tab keeps its group while it's beside another of its Tabs, and leaves it otherwise.
    @Test func movedTabKeepsItsGroupOnlyBesideIt() {
        #expect(TabGroup.moved(at: 1, in: [a, a, nil]) == a)
        #expect(TabGroup.moved(at: 0, in: [a, a, nil]) == a)
        #expect(TabGroup.moved(at: 3, in: [a, a, nil, a]) == nil)
        #expect(TabGroup.moved(at: 0, in: [a, nil, a]) == nil)
        #expect(TabGroup.moved(at: 1, in: [nil, nil, b]) == nil)
    }

    /// A group's only Tab takes the group along wherever it moves.
    @Test func movedOnlyTabTakesItsGroupAlong() {
        #expect(TabGroup.moved(at: 1, in: [nil, b, a, a]) == b)
        #expect(TabGroup.isOnly(1, in: [nil, b, a, a]))
        #expect(!TabGroup.isOnly(2, in: [nil, b, a, a]))
        #expect(!TabGroup.isOnly(0, in: [nil, b, a, a]))
    }

    // MARK: New groups

    /// A new group takes the first palette color no group uses, never None, and the colors in
    /// turn once all are taken.
    @Test func newGroupTakesAnUnusedColor() {
        #expect(!TabGroup.colors.contains(.none))
        #expect(TabGroup.color(avoiding: []) == .blue)
        #expect(TabGroup.color(avoiding: [.blue, .purple]) == .pink)
        #expect(TabGroup.color(avoiding: TabGroup.colors) == TabGroup.colors[0])
        #expect(TabGroup.color(avoiding: TabGroup.colors + [.blue]) == TabGroup.colors[1])
    }

    /// An unnamed group goes by its color.
    @Test func unnamedGroupGoesByItsColor() {
        #expect(a.title == "api")
        #expect(b.title == "Red Group")
    }

    // MARK: Sections

    /// Each ungrouped Tab is a section, and each run of a group is one, with the Tabs' own
    /// indices. A group split in two runs gets a section per run, with distinct ids.
    @Test func sectionsFollowTheRuns() {
        let tabs = Self.tabs([nil, a, a, nil, a])
        let sections = VerticalTabBarModel.sections(tabs)

        #expect(sections.map(\.id) == [
            .tab(tabs[0].id), .group(a.id, run: 0), .tab(tabs[3].id), .group(a.id, run: 1),
        ])
        #expect(sections[1].rows.map(\.index) == [1, 2])
        #expect(sections[1].count == 2)
        #expect(sections[3].rows.map(\.index) == [4])
    }

    /// A collapsed group lists only the Shown Tab when it's one of its own, and its header
    /// carries the most urgent status of the Tabs it hides.
    @Test func collapsedGroupListsOnlyItsShownTab() {
        var collapsed = a
        collapsed.isCollapsed = true
        let tabs = Self.tabs(
            [nil, collapsed, collapsed, collapsed],
            selected: 2,
            statuses: [3: .done, 2: .waiting])
        let group = VerticalTabBarModel.sections(tabs)[1]

        #expect(group.rows.map(\.index) == [2])
        #expect(group.count == 3)
        #expect(group.status == .done)

        let unselected = VerticalTabBarModel.sections(Self.tabs([collapsed, collapsed, nil], selected: 2))
        #expect(unselected[0].rows.isEmpty)
        #expect(unselected[0].count == 2)
    }

    /// Rows for `groups`, one Tab each; `windows` keeps the objects their ids name alive.
    private static var windows: [NSObject] = []

    private static func tabs(
        _ groups: [TabGroup?],
        selected: Int = 0,
        statuses: [Int: Ghostty.AgentStatus] = [:]
    ) -> [VerticalTabBarModel.Tab] {
        groups.enumerated().map { index, group in
            let object = NSObject()
            windows.append(object)
            return VerticalTabBarModel.Tab(
                id: ObjectIdentifier(object),
                title: "\(index)",
                color: .none,
                status: statuses[index],
                statusDate: .distantPast,
                shortcut: nil,
                group: group,
                isSelected: index == selected)
        }
    }
}
