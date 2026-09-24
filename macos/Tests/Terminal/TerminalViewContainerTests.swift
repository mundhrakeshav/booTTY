//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import Combine
import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @Test func glassAvailability() async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }

    /// Once SwiftUI reports the content's ideal size, the initial size fallback must not
    /// hold the window at a size the content has since shrunk from.
    @MainActor
    @Test func followsContentAfterLayout() async throws {
        final class IdealWidth: ObservableObject { @Published var value: CGFloat = 400 }
        struct Content: View {
            @ObservedObject var width: IdealWidth
            var body: some View { Color.clear.frame(idealWidth: width.value, idealHeight: 300) }
        }

        let width = IdealWidth()
        let view = TerminalViewContainer { Content(width: width) }
        view.initialContentSize = NSSize(width: 400, height: 300)
        #expect(view.intrinsicContentSize == NSSize(width: 400, height: 300))

        width.value = 250
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.intrinsicContentSize == NSSize(width: 250, height: 300))
    }
}
