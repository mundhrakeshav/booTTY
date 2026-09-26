//
//  CommandPaletteTests.swift
//  GhosttyTests
//
//  Tests for command palette query filtering and match ranking.
//

import Testing
import SwiftUI
@testable import Ghostty

struct CommandPaletteFilterTests {
    private func option(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        leadingColor: Color? = nil,
        sortKey: ObjectIdentifier? = nil
    ) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            description: description,
            leadingColor: leadingColor,
            sortKey: sortKey
        ) {}
    }

    /// Title matches outrank subtitle matches, which outrank description
    /// matches. Options that don't match at all are dropped.
    @Test func textMatchTiers() {
        let byDescription = option(title: "Alpha", description: "make it fast")
        let bySubtitle = option(title: "Beta", subtitle: "fast scrolling")
        let byTitle = option(title: "Fast Redraw")
        let noMatch = option(title: "Quit")

        let results = [noMatch, byDescription, bySubtitle, byTitle]
            .filteredAndSorted(query: "fast")

        #expect(results == [byTitle, bySubtitle, byDescription])
    }

    /// Workspace rows: name matches rank above Tab matches, which match on a Tab's title or
    /// any of its folders; ties keep the given (recency) order. The subtitle ("N tabs · …")
    /// doesn't match, and a Tab match shows that Tab as the subtitle.
    @Test func workspaceNameMatchesRankAboveTabMatches() {
        func workspace(_ name: String, _ tabs: [CommandOption.Tab]) -> CommandOption {
            CommandOption(title: name, subtitle: "\(tabs.count) tabs · \(tabs.first?.title ?? "")", tabs: tabs) {}
        }
        let byFolder = workspace("web", [.init(title: "vim", folders: ["~/code/site", "~/code/api"])])
        let byTabTitle = workspace("scratch", [.init(title: "zsh", folders: []), .init(title: "api logs", folders: ["/tmp"])])
        let byName = workspace("api", [.init(title: "zsh", folders: ["~"])])
        let noMatch = workspace("docs", [.init(title: "man", folders: ["~/docs"])])

        #expect([byFolder, byTabTitle, noMatch, byName].filteredAndSorted(query: "api") == [byName, byFolder, byTabTitle])
        #expect([byTabTitle, byFolder].filteredAndSorted(query: "api") == [byTabTitle, byFolder])
        #expect([byName, noMatch].filteredAndSorted(query: "tabs").isEmpty)

        #expect(byFolder.tabSubtitle(matching: "api") == "vim · ~/code/api")
        #expect(byTabTitle.tabSubtitle(matching: "logs") == "api logs · /tmp")
        #expect(byName.tabSubtitle(matching: "api") == nil)
    }

    /// Options with equal scores keep their original relative order.
    @Test func tiesPreserveOriginalOrder() {
        let first = option(title: "New Window")
        let second = option(title: "New Tab")

        #expect([first, second].filteredAndSorted(query: "new") == [first, second])
        #expect([second, first].filteredAndSorted(query: "new") == [second, first])
    }

    /// Equal titles use their sort keys independent of input order.
    @Test func equalTitlesUseSortKey() {
        let firstKey = NSObject()
        let secondKey = NSObject()
        let first = option(
            title: "Focus: Shell",
            subtitle: "/tmp",
            sortKey: ObjectIdentifier(firstKey)
        )
        let second = option(
            title: "Focus: Shell",
            subtitle: "/tmp",
            sortKey: ObjectIdentifier(secondKey)
        )

        let forward = sortedTerminalPaletteOptions([first, second])
        let reverse = sortedTerminalPaletteOptions([second, first])
        #expect(forward == reverse)
    }
}
