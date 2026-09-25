import AppKit
import Testing
@testable import Ghostty

@MainActor
struct WorkspaceMenuTests {
    private func store(_ names: [String], shown: Int) -> WorkspaceStore {
        let workspaces = names.map { WorkspaceStore.Workspace(name: $0) }
        return WorkspaceStore(workspaces: workspaces, shownID: workspaces[shown].id)
    }

    @Test func rowsFollowBarOrderAndMarkTheShownWorkspace() throws {
        let rows = store(["api", "web", "docs"], shown: 1).menuItems(config: try TemporaryConfig(""))

        #expect(rows.map(\.title) == ["api", "web", "docs"])
        #expect(rows.map(\.state) == [.off, .on, .off])
        #expect(rows.map(\.tag) == [1, 2, 3])
        #expect(rows.allSatisfy { $0.action == #selector(BaseTerminalController.selectWorkspace(_:)) })
    }

    @Test func rowsShowTheDefaultGotoWorkspaceShortcuts() throws {
        let rows = store(["a", "b"], shown: 0).menuItems(config: try TemporaryConfig(""))

        #expect(rows.map(\.keyEquivalent) == ["1", "2"])
        #expect(rows.allSatisfy { $0.keyEquivalentModifierMask == [.command, .option] })
    }

    @Test func rowsFollowRebindsAndStopAtNine() throws {
        let config = try TemporaryConfig("""
            keybind = clear
            keybind = ctrl+k=goto_workspace:2
            keybind = ctrl+j=goto_workspace:10
            """)
        let rows = store((1...10).map { "w\($0)" }, shown: 0).menuItems(config: config)

        #expect(rows[0].keyEquivalent == "")
        #expect(rows[1].keyEquivalent == "k")
        #expect(rows[1].keyEquivalentModifierMask == [.control])
        #expect(rows[9].keyEquivalent == "")
    }
}
