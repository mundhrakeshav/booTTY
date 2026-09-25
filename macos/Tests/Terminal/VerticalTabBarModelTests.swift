import AppKit
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

    /// SPEC §5.1: a row holds 11 Workspaces and "+" at the default 200 pt width and 5 at
    /// the 120 pt minimum (rows get the bar's width less 16 pt of padding). "+" is the
    /// last index.
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
}
