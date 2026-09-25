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

    @Test func renameNamesAnyWorkspaceAndBlankRestoresTheOriginal() {
        let store = store(["Workspace 1", "Workspace 2"])
        let hidden = store.workspaces[1].id

        // Names needn't be unique, and a hidden Workspace renames without being shown.
        store.rename(hidden, to: "Workspace 1")
        #expect(store.workspaces.map(\.name) == ["Workspace 1", "Workspace 1"])
        #expect(store.shownIndex == 0)

        store.rename(hidden, to: "  ")
        #expect(store.workspaces[1].name == "Workspace 2")

        store.rename(hidden, to: "api")
        store.rename(hidden, to: "")
        #expect(store.workspaces[1].name == "Workspace 2")
        #expect(store.workspaces[1].originalName == "Workspace 2")
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

    // MARK: Hidden Tabs

    @Test func newHiddenTabGoesAfterTheRememberedTabOrAtTheEnd() {
        let a = NSObject(), b = NSObject(), c = NSObject()
        let tabs = [a, b, c]
        #expect(WorkspaceStore.newTabIndex(after: a, in: tabs, atEnd: false) == 1)
        #expect(WorkspaceStore.newTabIndex(after: c, in: tabs, atEnd: false) == 3)
        #expect(WorkspaceStore.newTabIndex(after: a, in: tabs, atEnd: true) == 3)
        #expect(WorkspaceStore.newTabIndex(after: nil as NSObject?, in: tabs, atEnd: false) == 3)
    }

    // MARK: Undo

    private func undoState(of store: WorkspaceStore, position: Int) -> WorkspaceStore.UndoState {
        .init(windowID: store.id, id: UUID(), name: "api", originalName: "Workspace 2", color: .teal, position: position)
    }

    @Test func recreatedWorkspaceComesBackAtItsOldPosition() {
        let store = store(["a", "b", "c"], shown: 2)
        let shown = store.shownID
        let saved = undoState(of: store, position: 1)

        store.recreate(saved, holding: [])

        #expect(store.workspaces.map(\.name) == ["a", "api", "b", "c"])
        let workspace = store.workspaces[1]
        #expect(workspace.id == saved.id)
        #expect(workspace.originalName == "Workspace 2")
        #expect(workspace.color == .teal)
        #expect(store.shownID == shown)
    }

    @Test func recreatedWorkspaceGoesAtTheEndOfAWindowWithFewerWorkspaces() {
        for (position, names) in [(2, ["a", "b", "api"]), (7, ["a", "b", "api"]), (0, ["api", "a", "b"])] {
            let store = store(["a", "b"])
            store.recreate(undoState(of: store, position: position), holding: [])
            #expect(store.workspaces.map(\.name) == names)
        }
    }

    @Test func undoStateRemembersTheWorkspacesPlace() throws {
        let store = store(["a", "b", "c"])
        let saved = try #require(store.undoState(of: store.workspaces[1].id))

        #expect(saved.windowID == store.id)
        #expect(saved.id == store.workspaces[1].id)
        #expect(saved.name == "b")
        #expect(saved.position == 1)
        #expect(store.undoState(of: UUID()) == nil)
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

    // MARK: Re-forming an emptied group

    /// Four ordered-out windows, as a hidden Workspace's Tabs are, and the window the last
    /// shown Tab left for, ordered in. All are transparent.
    private func reformWindows() -> (tabs: [NSWindow], joined: NSWindow) {
        let windows = (0..<5).map { _ in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: true)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            window.alphaValue = 0
            return window
        }
        windows[4].orderFront(nil)
        return (Array(windows[0...3]), windows[4])
    }

    @Test func reformKeepsTheTabOrderAroundTheRememberedTab() throws {
        let (tabs, joined) = reformWindows()
        defer { (tabs + [joined]).forEach { $0.close() } }
        let frame = NSRect(x: 40, y: 60, width: 300, height: 200)

        let reformed = try #require(WorkspaceStore.reform(tabs, around: tabs[2], frame: frame, below: joined))

        #expect(reformed.group.windows == tabs)
        #expect(reformed.group.selectedWindow === tabs[2])
        #expect(reformed.failed.isEmpty)
        #expect(tabs[2].frame == frame)
        #expect(joined.tabGroup?.windows == [joined])
    }

    @Test func reformLeavesOutATabThatFailsToJoin() throws {
        let (tabs, joined) = reformWindows()
        defer { (tabs + [joined]).forEach { $0.close() } }

        // Fails the second add: the Tab before the Remembered Tab.
        var adds = 0
        let reformed = try #require(WorkspaceStore.reform(tabs, around: tabs[2], frame: nil, below: joined) { step, block in
            if step == .add { adds += 1 }
            return step == .add && adds == 2 ? false : WorkspaceStore.performSafely(step, block)
        })

        #expect(reformed.group.windows == [tabs[0], tabs[2], tabs[3]])
        #expect(reformed.failed == [tabs[1]])
    }

    // MARK: Swiping

    private func scroll(
        _ store: WorkspaceStore,
        _ phase: NSEvent.Phase,
        momentum: NSEvent.Phase = [],
        dx: CGFloat = 0,
        dy: CGFloat = 0,
        overBar: Bool = true
    ) -> WorkspaceStore.SwipeEventAction {
        store.swipeAction(phase: phase, momentumPhase: momentum, deltaX: dx, deltaY: dy, startsSwipe: overBar)
    }

    /// A flick's momentum after the fingers lift.
    private func momentum(_ store: WorkspaceStore) -> [WorkspaceStore.SwipeEventAction] {
        [.began, .changed, .ended].map { scroll(store, [], momentum: $0, dx: -3) }
    }

    @Test func horizontalFirstMovementClaimsTheGestureAndDropsItsMomentum() {
        let store = store(["a", "b"])
        #expect(scroll(store, .mayBegin) == .pass)
        #expect(scroll(store, .began, dx: -4, dy: 1) == .track)
        // AppKit's tracker needs the gesture's own events.
        #expect(scroll(store, .changed, dx: 1, dy: -9) == .pass)
        #expect(scroll(store, .ended) == .pass)
        #expect(momentum(store) == [.drop, .drop, .drop])
        // The momentum is over, so the next scroll is the user's again.
        #expect(scroll(store, [], momentum: .changed, dx: -3) == .pass)
    }

    @Test func verticalFirstMovementKeepsTheWholeGestureForTheList() {
        let store = store(["a", "b"])
        // No movement yet decides nothing.
        #expect(scroll(store, .began) == .pass)
        #expect(scroll(store, .changed, dx: 2, dy: -6) == .pass)
        #expect(scroll(store, .changed, dx: -20) == .pass)
        #expect(scroll(store, .ended) == .pass)
        #expect(momentum(store) == [.pass, .pass, .pass])
    }

    @Test func gestureThatCantStartASwipeIsNeverClaimed() {
        // Over the terminal, or while the bar or Window refuses a swipe.
        let store = store(["a", "b"])
        #expect(scroll(store, .began, dx: -8, overBar: false) == .pass)
        #expect(scroll(store, .changed, dx: -8) == .pass)
        #expect(scroll(store, .ended) == .pass)
        #expect(momentum(store) == [.pass, .pass, .pass])
    }

    @Test func newGestureStopsDroppingMomentum() {
        let store = store(["a", "b"])
        _ = scroll(store, .began, dx: -4)
        _ = scroll(store, .ended)
        #expect(scroll(store, .began, dy: 5, overBar: false) == .pass)
        #expect(scroll(store, .ended) == .pass)
        #expect(momentum(store) == [.pass, .pass, .pass])
    }

    @Test func swipeTargetsANeighborAndNeverWraps() {
        let store = store(["a", "b", "c"])
        let ids = store.workspaces.map(\.id)

        let first = store.claimSwipe()
        #expect(first.target(-0.4) == ids[1]) // fingers left: the next Workspace
        #expect(first.target(0.4) == nil)
        #expect(first.target(0) == nil)

        // A rubber band at the first Workspace switches nothing when the fingers lift.
        #expect(store.stepSwipe(first, amount: 0.1, phase: .ended))
        #expect(store.shownIndex == 0)

        let atLast = self.store(["a", "b", "c"], shown: 2)
        let last = atLast.claimSwipe()
        #expect(last.target(0.4) == atLast.workspaces[1].id) // fingers right: the previous Workspace
        #expect(last.target(-0.4) == nil)
    }

    @Test func newSwipeStopsTheOneBefore() {
        let store = store(["a", "b"])
        let older = store.claimSwipe()
        let newer = store.claimSwipe()
        #expect(!store.stepSwipe(older, amount: -0.3, phase: []))
        #expect(store.stepSwipe(newer, amount: -0.3, phase: .changed))
    }

    @Test func swipeWhoseTargetEndedIsCancelledAndDropped() {
        let store = store(["a", "b"])
        #expect(scroll(store, .began, dx: -4) == .track)
        let claimed = store.claimSwipe()
        let swipe = WorkspaceStore.Swipe(generation: claimed.generation, previous: nil, next: UUID())

        #expect(!store.stepSwipe(swipe, amount: -0.3, phase: .changed))
        #expect(store.shownIndex == 0)
        // Once AppKit's tracker lets go, the rest of the gesture and its momentum are dropped.
        #expect(scroll(store, .changed, dx: -4) == .drop)
        #expect(scroll(store, .ended) == .drop)
        #expect(momentum(store) == [.drop, .drop, .drop])
    }

    // MARK: Moving Tabs

    @Test func detachingTheSelectedTabSelectsItsNeighborFirst() throws {
        let (group, old, incoming) = try tabGroup()
        defer { (old + incoming).forEach { $0.close() } }

        var steps: [WorkspaceStore.SwapStep] = []
        let detached = WorkspaceStore.detach(old[0], from: group, makeKey: false) { step, block in
            steps.append(step)
            return WorkspaceStore.performSafely(step, block)
        }

        #expect(detached)
        #expect(steps == [.select, .orderOut])
        #expect(group.windows == [old[1]])
        #expect(group.selectedWindow === old[1])
    }

    @Test func detachingAnUnselectedTabKeepsTheSelection() throws {
        let (group, old, incoming) = try tabGroup()
        defer { (old + incoming).forEach { $0.close() } }

        #expect(WorkspaceStore.detach(old[1], from: group, makeKey: false))
        #expect(group.windows == [old[0]])
        #expect(group.selectedWindow === old[0])
    }

    @Test(arguments: [WorkspaceStore.SwapStep.select, .orderOut])
    func failedDetachKeepsTheTab(failing: WorkspaceStore.SwapStep) throws {
        let (group, old, incoming) = try tabGroup()
        defer { (old + incoming).forEach { $0.close() } }

        // Fails only the first try of the step, so a rollback's select still runs.
        var failed = false
        let detached = WorkspaceStore.detach(old[0], from: group, makeKey: false) { step, block in
            if step == failing && !failed {
                failed = true
                return false
            }
            return WorkspaceStore.performSafely(step, block)
        }

        #expect(!detached)
        #expect(group.windows == old)
        #expect(group.selectedWindow === old[0])
    }

    @Test func insertingPutsTheTargetsTabsInFrontAndKeepsTheSelection() throws {
        let (group, old, incoming) = try tabGroup()
        defer { (old + incoming).forEach { $0.close() } }

        #expect(WorkspaceStore.insert(incoming, around: old[1], in: group))
        #expect(group.windows == [old[0]] + incoming + [old[1]])
        #expect(group.selectedWindow === old[0])
    }

    @Test func insertingWithLeadingPutsTheRestAfterTheTab() throws {
        let (group, old, incoming) = try tabGroup()
        defer { (old + incoming).forEach { $0.close() } }

        #expect(WorkspaceStore.insert(incoming, around: old[0], leading: 1, in: group))
        #expect(group.windows == [incoming[0], old[0], incoming[1], old[1]])
        #expect(group.selectedWindow === old[0])
    }

    @Test func failedInsertOrdersTheAddedTabsOutAgain() throws {
        let (group, old, incoming) = try tabGroup()
        defer { (old + incoming).forEach { $0.close() } }

        var adds = 0
        let inserted = WorkspaceStore.insert(incoming, around: old[0], in: group) { step, block in
            if step == .add { adds += 1 }
            if step == .add && adds == 2 { return false }
            return WorkspaceStore.performSafely(step, block)
        }

        #expect(!inserted)
        #expect(group.windows == old)
        #expect(group.selectedWindow === old[0])
    }
}
