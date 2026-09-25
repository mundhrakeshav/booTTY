import AppKit
import Testing
@testable import Ghostty

@MainActor
struct WorkspaceStoreTests {
    private func store(_ names: [String], shown: Int = 0) -> WorkspaceStore {
        let workspaces = names.map { WorkspaceStore.Workspace(name: $0) }
        return WorkspaceStore(workspaces: workspaces, shownID: workspaces[shown].id)
    }

    // MARK: Naming

    @Test func newNameTakesTheLowestFreeNumber() {
        #expect(WorkspaceStore.newName(in: []) == "Workspace 1")
        #expect(WorkspaceStore.newName(in: store(["Workspace 1", "Workspace 3"]).workspaces) == "Workspace 2")
        #expect(WorkspaceStore.newName(in: store(["Workspace 2"]).workspaces) == "Workspace 1")
    }

    @Test func newNameCountsOnlyNamesAsShown() {
        // A renamed Workspace frees its number, and names that only look alike don't take one.
        let workspaces = store(["api", "Workspace 1", "Workspace 02", "workspace 2", "Workspace 2 "]).workspaces
        #expect(WorkspaceStore.newName(in: workspaces) == "Workspace 2")
    }

    // MARK: Ordering

    @Test func addedWorkspaceGoesAtTheEnd() {
        let store = store(["Workspace 1", "api", "Workspace 3"], shown: 1)
        let before = store.workspaces.map(\.id)

        let id = store.addWorkspace(holding: [])

        #expect(store.workspaces.map(\.id) == before + [id])
        #expect(store.workspaces.last?.name == "Workspace 2")
        #expect(store.shownIndex == 1)
    }

    @Test func gotoShowsTheNthOrTheLast() {
        let store = store(["a", "b", "c"], shown: 1)
        #expect(store.index(of: .number(1)) == 0)
        #expect(store.index(of: .number(3)) == 2)
        #expect(store.index(of: .number(9)) == 2)
        #expect(store.index(of: .number(0)) == nil)
        #expect(store.index(of: .number(-1)) == nil)
    }

    @Test func previousAndNextWrap() {
        #expect(store(["a", "b", "c"], shown: 1).index(of: .previous) == 0)
        #expect(store(["a", "b", "c"], shown: 1).index(of: .next) == 2)
        #expect(store(["a", "b", "c"], shown: 0).index(of: .previous) == 2)
        #expect(store(["a", "b", "c"], shown: 2).index(of: .next) == 0)
    }

    @Test func oneWorkspaceHasNothingToShow() {
        let store = store(["a"])
        #expect(store.index(of: .number(1)) == nil)
        #expect(store.index(of: .previous) == nil)
        #expect(store.index(of: .next) == nil)
        #expect(store.show(.next) == false)
    }

    @Test func showingTheShownWorkspaceReportsTrue() {
        let store = store(["a", "b"], shown: 1)
        #expect(store.show(store.workspaces[1].id))
        #expect(store.shownIndex == 1)
    }

    // MARK: Ending

    @Test func anEndingShownWorkspaceHandsOffToTheRightElseTheLeft() {
        let names = ["a", "b", "c"]
        for (shown, neighbor) in [(0, 1), (1, 2), (2, 1)] {
            let store = store(names, shown: shown)
            #expect(store.neighborID == store.workspaces[neighbor].id)
        }
        #expect(store(["a"]).neighborID == nil)
    }

    @Test func rememberedTabHandsOffToTheRightElseTheLeft() {
        let a = NSObject(), b = NSObject(), c = NSObject()
        let tabs = [a, b, c]
        #expect(WorkspaceStore.remembered(a, after: a, leaves: tabs) === b)
        #expect(WorkspaceStore.remembered(b, after: b, leaves: tabs) === c)
        #expect(WorkspaceStore.remembered(c, after: c, leaves: tabs) === b)
        #expect(WorkspaceStore.remembered(a, after: a, leaves: [a]) == nil)
    }

    @Test func rememberedTabStaysWhenAnotherTabLeaves() {
        let a = NSObject(), b = NSObject(), c = NSObject()
        #expect(WorkspaceStore.remembered(a, after: b, leaves: [a, b, c]) === a)
        #expect(WorkspaceStore.remembered(c, after: a, leaves: [a, b, c]) === c)
    }

    // MARK: Agent status

    @Test func agentStatusIsTheMostUrgentTabs() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        #expect(WorkspaceStore.agentStatus(of: []).status == nil)
        #expect(WorkspaceStore.agentStatus(of: [(nil, t)]).status == nil)
        #expect(WorkspaceStore.agentStatus(of: [(nil, t), (.done, t)]).status == .done)
        #expect(WorkspaceStore.agentStatus(of: [(.done, t), (.waiting, t), (nil, t)]).status == .waiting)
    }

    @Test func agentStatusDateIsTheNewestAmongTheWinners() {
        let t = (0..<4).map { Date(timeIntervalSinceReferenceDate: Double($0)) }

        // No status has no date, however recently a Tab's status cleared.
        #expect(WorkspaceStore.agentStatus(of: [(nil, t[3])]).since == .distantPast)

        // A second finish moves the date, so an already-green dot pings again.
        #expect(WorkspaceStore.agentStatus(of: [(.done, t[1]), (.done, t[2]), (nil, t[3])]).since == t[2])

        // A finish behind a waiting agent keeps the waiting date.
        let behindWaiting = WorkspaceStore.agentStatus(of: [(.waiting, t[0]), (.done, t[3])])
        #expect(behindWaiting.status == .waiting)
        #expect(behindWaiting.since == t[0])
    }

    // MARK: Switching

    /// A tab group of two windows, `old` with the first selected, and two ordered-out
    /// windows to switch to. None is ever shown.
    private func tabGroup() throws -> (group: NSWindowTabGroup, old: [NSWindow], incoming: [NSWindow]) {
        let windows = (0..<4).map { _ in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: true)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            return window
        }
        let group = try #require(windows[0].tabGroup)
        group.addWindow(windows[1])
        group.selectedWindow = windows[0]
        return (group, Array(windows[0...1]), Array(windows[2...3]))
    }

    @Test(arguments: [false, true])
    func swapAddsSelectsThenOrdersOut(makeKey: Bool) throws {
        let (group, old, incoming) = try tabGroup()
        defer { (old + incoming).forEach { $0.close() } }

        let orderedOut = WorkspaceStore.swap(in: group, adding: incoming, selecting: incoming[1], makeKey: makeKey)

        #expect(orderedOut == old)
        #expect(group.windows == incoming)
        #expect(group.selectedWindow === incoming[1])
    }

    @Test(arguments: [WorkspaceStore.SwapStep.add, .select])
    func failedSwapKeepsTheOldTabs(failing: WorkspaceStore.SwapStep) throws {
        let (group, old, incoming) = try tabGroup()
        defer { (old + incoming).forEach { $0.close() } }

        // Fails the second add, after the first incoming window joined, or the selection.
        var adds = 0
        let orderedOut = WorkspaceStore.swap(in: group, adding: incoming, selecting: incoming[1], makeKey: false) { step, block in
            if step == .add { adds += 1 }
            if step == failing && (step != .add || adds == 2) { return false }
            return WorkspaceStore.performSafely(step, block)
        }

        #expect(orderedOut == nil)
        #expect(group.windows == old)
        #expect(group.selectedWindow === old[0])
    }
}
