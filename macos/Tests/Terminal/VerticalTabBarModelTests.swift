import AppKit
import CoreTransferable
import Testing
@testable import Ghostty

@MainActor
struct VerticalTabBarModelTests {
    /// Moving the bar to the other side shows the new bar before the old one
    /// disappears. The bar must keep following its tabs afterwards.
    @Test func keepsUpdatingAfterBarMovesSides() async throws {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "before"
        let model = VerticalTabBarModel(window: window)

        model.activate() // bar on the old side
        model.activate() // bar on the new side appears
        model.deactivate() // bar on the old side disappears

        window.title = "after"
        NotificationCenter.default.post(name: TerminalWindow.tabDidChangeNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.tabs.map(\.title) == ["after"])
    }

    /// A row holds 11 Workspaces and "+" at the default 200 pt width and 5 at the 120 pt
    /// minimum (rows get the bar's width less 16 pt of padding). "+" is the last index.
    @Test func dotRowsWrapWhenFull() {
        #expect(VerticalTabBarModel.dotRows(count: 11, width: 184) == [Array(0...11)])
        #expect(VerticalTabBarModel.dotRows(count: 12, width: 184) == [Array(0..<12), [12]])
        #expect(VerticalTabBarModel.dotRows(count: 14, width: 184) == [Array(0..<13), [13, 14]])
        #expect(VerticalTabBarModel.dotRows(count: 5, width: 104) == [Array(0...5)])
        #expect(VerticalTabBarModel.dotRows(count: 6, width: 104) == [Array(0..<6), [6]])
        #expect(VerticalTabBarModel.dotRows(count: 15, width: 104) == [Array(0..<7), Array(7..<14), [14, 15]])
    }

    /// A bar narrower than one item still places everything, one item per row.
    @Test func dotRowsNeverLeaveARowEmpty() {
        #expect(VerticalTabBarModel.dotRows(count: 2, width: 10) == [[0], [1], [2]])
    }

    /// The one drop type of a dot and "+" tells a Tab row from a dot.
    @Test func workspaceDropTellsTabRowsFromDots() async throws {
        func drop(_ provider: NSItemProvider) async throws -> WorkspaceDrop {
            try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadTransferable(type: WorkspaceDrop.self) { continuation.resume(with: $0) }
            }
        }

        let row = NSItemProvider()
        row.register(DraggedTab(window: 7))
        guard case .tab(let tab) = try await drop(row) else {
            Issue.record("a row isn't a Tab drop")
            return
        }
        #expect(tab.window == 7)

        let dragged = DraggedWorkspace(window: UUID(), workspace: UUID())
        let dot = NSItemProvider()
        dot.register(dragged)
        guard case .workspace(let workspace) = try await drop(dot) else {
            Issue.record("a dot isn't a Workspace drop")
            return
        }
        #expect(workspace.window == dragged.window && workspace.workspace == dragged.workspace)
    }

    // MARK: Swiping

    /// Fingers left move the shown page left and bring the next one in from the right;
    /// fingers right bring the previous one in from the left. Past an end the shown page
    /// stretches by the dampened amount.
    @Test func pagesFollowTheSwipe() {
        func place(_ amount: CGFloat, neighbor: Bool) -> (offset: CGFloat, opacity: Double) {
            VerticalTabBarModel.pagePlacement(
                amount: amount, isNeighbor: neighbor, hasNeighbor: true, reduceMotion: false)
        }
        #expect(place(-0.25, neighbor: false) == (-0.25, 1))
        #expect(place(-0.25, neighbor: true) == (0.75, 1))
        #expect(place(0.25, neighbor: true) == (-0.75, 1))
        // After the switch at the lift, -0.4 counts as +0.6 from the incoming Workspace.
        #expect(place(0.6, neighbor: false) == (0.6, 1))
        #expect(place(0.6, neighbor: true) == (-0.4, 1))

        let band = VerticalTabBarModel.pagePlacement(amount: 0.08, isNeighbor: false, hasNeighbor: false, reduceMotion: false)
        #expect(band == (0.08, 1))
    }

    /// Under Reduce Motion the pages crossfade in place, and nothing changes past an end.
    @Test func reduceMotionCrossfadesThePages() {
        func place(_ amount: CGFloat, neighbor: Bool, hasNeighbor: Bool = true) -> (offset: CGFloat, opacity: Double) {
            VerticalTabBarModel.pagePlacement(
                amount: amount, isNeighbor: neighbor, hasNeighbor: hasNeighbor, reduceMotion: true)
        }
        #expect(place(-0.25, neighbor: false) == (0, 0.75))
        #expect(place(-0.25, neighbor: true) == (0, 0.25))
        #expect(place(0.08, neighbor: false, hasNeighbor: false) == (0, 1))
    }

    /// The shown mark hands the neighbor's the swipe's share of the capsule; other marks,
    /// a rubber band, and Reduce Motion leave it whole on the shown mark.
    @Test func capsuleSharePassesFromTheShownMarkToTheNeighbor() {
        let (shown, neighbor, other) = (UUID(), UUID(), UUID())
        func share(_ id: UUID, _ amount: CGFloat, neighbor n: UUID? = neighbor, reduceMotion: Bool = false) -> CGFloat {
            VerticalTabBarModel.capsuleShare(of: id, shown: shown, neighbor: n, amount: amount, reduceMotion: reduceMotion)
        }
        #expect(share(shown, -0.25) == 0.75)
        #expect(share(neighbor, -0.25) == 0.25)
        #expect(share(other, -0.25) == 0)
        #expect(share(neighbor, 1.2) == 1)
        #expect(share(shown, 0.08, neighbor: nil) == 1)
        #expect(share(shown, -0.5, reduceMotion: true) == 1)
        #expect(share(neighbor, -0.5, reduceMotion: true) == 0)
    }

    /// A mark grows from the 6 pt dot to the 12 pt capsule by its share, and its status
    /// ring fades by the same share.
    @Test func markGrowsAndItsRingFadesByItsShare() {
        #expect(VerticalTabBarModel.mark(share: 0) == (6, 1))
        #expect(VerticalTabBarModel.mark(share: 0.25) == (7.5, 0.75))
        #expect(VerticalTabBarModel.mark(share: 1) == (12, 0))
    }
}
