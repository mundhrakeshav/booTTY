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
}
