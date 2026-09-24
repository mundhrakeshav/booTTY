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
}
