import Testing
import GhosttyKit
@testable import Ghostty

/// `goto_tab` and `move_tab` count over a Workspace's Tabs, shown or hidden.
@MainActor
struct TabNavigationTests {
    @Test func gotoTabWrapsAndStopsAtTheLast() {
        let goto = TerminalController.gotoTabIndex
        #expect(goto(GHOSTTY_GOTO_TAB_NEXT, 1, 3) == 2)
        #expect(goto(GHOSTTY_GOTO_TAB_NEXT, 2, 3) == 0)
        #expect(goto(GHOSTTY_GOTO_TAB_PREVIOUS, 0, 3) == 2)
        #expect(goto(GHOSTTY_GOTO_TAB_PREVIOUS, 2, 3) == 1)
        #expect(goto(GHOSTTY_GOTO_TAB_LAST, 0, 3) == 2)
        #expect(goto(ghostty_action_goto_tab_e(rawValue: 2), 0, 3) == 1)
        #expect(goto(ghostty_action_goto_tab_e(rawValue: 9), 0, 3) == 2)
        #expect(goto(ghostty_action_goto_tab_e(rawValue: 0), 0, 3) == nil)
        #expect(goto(GHOSTTY_GOTO_TAB_NEXT, nil, 3) == nil)
        #expect(goto(GHOSTTY_GOTO_TAB_LAST, nil, 0) == nil)
    }

    @Test func moveTabStopsAtTheEnds() {
        let moved = TerminalController.movedTabIndex
        #expect(moved(1, 1, 3) == 2)
        #expect(moved(1, 5, 3) == 2)
        #expect(moved(1, -1, 3) == 0)
        #expect(moved(1, -5, 3) == 0)
        #expect(moved(2, 1, 3) == 2)
    }
}
