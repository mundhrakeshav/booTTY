import Testing
@testable import Ghostty

struct WindowStyleTests {
    @Test func decorationsWinOverAHiddenTitlebar() throws {
        // With both settings `window-decoration` wins, so the window counts as undecorated and
        // gets the plain nib and "Enable window decorations to use Workspaces.".
        let style = TerminalController.WindowStyle(try TemporaryConfig("""
            window-decoration = none
            macos-titlebar-style = hidden
            """))
        #expect(style.nibName == "Terminal")
        #expect(!style.isDecorated)
    }

    @Test func hiddenTitlebarIsDecorated() throws {
        let style = TerminalController.WindowStyle(try TemporaryConfig("macos-titlebar-style = hidden"))
        #expect(style.nibName == "TerminalHiddenTitlebar")
        #expect(style.isDecorated)
    }
}
