import Foundation
import Testing
@testable import Ghostty

@MainActor
struct WorkspaceOrganizeTests {
    private final class Tab {
        let pwd: String?
        init(_ pwd: String?) { self.pwd = pwd }
    }

    /// A fresh folder holding `folders` and, for each of `gitFiles`, a `.git` file.
    private func tree(folders: [String], gitFiles: [String] = []) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceOrganizeTests-\(UUID().uuidString)").standardized.path
        for folder in folders {
            try FileManager.default.createDirectory(
                atPath: (root as NSString).appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in gitFiles {
            let path = (root as NSString).appendingPathComponent(file)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            #expect(FileManager.default.createFile(atPath: path, contents: Data("gitdir: ../.git/worktrees/x".utf8)))
        }
        return root
    }

    private func key(_ pwd: String?, _ mode: WorkspaceStore.OrganizeMode) -> String? {
        WorkspaceStore.organizeKey(of: pwd, by: mode)
    }

    // MARK: Keys

    @Test func repoKeyIsTheNearestFolderHoldingAGitFolder() throws {
        let root = try tree(folders: ["app/.git", "app/src/deep"])
        defer { try? FileManager.default.removeItem(atPath: root) }

        #expect(key("\(root)/app", .repo) == "\(root)/app")
        #expect(key("\(root)/app/src/deep/", .repo) == "\(root)/app")
        #expect(key("\(root)/app/src/deep", .folder) == "\(root)/app/src/deep")
    }

    @Test func aGitFileMakesAWorktreeOrSubmoduleItsOwnRepo() throws {
        let root = try tree(folders: ["app/.git", "app/lib/src"], gitFiles: ["app/lib/.git"])
        defer { try? FileManager.default.removeItem(atPath: root) }

        #expect(key("\(root)/app/lib/src", .repo) == "\(root)/app/lib")
        #expect(key("\(root)/app", .repo) == "\(root)/app")
    }

    @Test func aPwdOutsideAnyRepoKeysByItsOwnFolder() throws {
        let root = try tree(folders: ["plain/sub"])
        defer { try? FileManager.default.removeItem(atPath: root) }

        #expect(key("\(root)/plain/sub", .repo) == "\(root)/plain/sub")
    }

    @Test func aNilOrEmptyPwdHasNoKey() {
        #expect(key(nil, .repo) == nil)
        #expect(key("", .repo) == nil)
        #expect(key("", .folder) == nil)
    }

    // MARK: Groups

    @Test(arguments: [WorkspaceStore.OrganizeMode.repo, .folder])
    func tabsGroupByRepoOrFolder(mode: WorkspaceStore.OrganizeMode) throws {
        // A stand-in home: ~/code/app is a repo, ~/code/app/src sits in it, ~/tmp isn't one.
        let home = try tree(folders: ["code/app/.git", "code/app/src", "tmp"])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let tabs = [Tab("\(home)/code/app"), Tab("\(home)/code/app/src"), Tab("\(home)/tmp"), Tab("\(home)/code/app")]

        let groups = WorkspaceStore.organizeGroups(
            tabs, key: { key($0.pwd, mode) }, remembering: [], home: home)

        switch mode {
        case .repo:
            #expect(groups.map(\.name) == ["app", "tmp"])
            #expect(groups[0].tabs.count == 3 && groups[0].tabs[1] === tabs[1] && groups[0].tabs[2] === tabs[3])
        case .folder:
            #expect(groups.map(\.name) == ["app", "src", "tmp"])
            #expect(groups[0].tabs.count == 2)
        }
    }

    @Test func groupsFollowTheirFirstTabAndOtherComesLast() {
        let tabs = [Tab(nil), Tab("/x/b"), Tab("/x/a"), Tab("/x/b"), Tab("")]

        let groups = WorkspaceStore.organizeGroups(
            tabs, key: { key($0.pwd, .folder) }, remembering: [], home: "/Users/me")

        #expect(groups.map(\.name) == ["b", "a", "Other"])
        #expect(groups[0].tabs.count == 2 && groups[0].tabs[0] === tabs[1] && groups[0].tabs[1] === tabs[3])
        #expect(groups[2].tabs.count == 2 && groups[2].tabs[0] === tabs[0] && groups[2].tabs[1] === tabs[4])
    }

    @Test func eachGroupRemembersItsFirstShownOrRememberedTabElseItsFirst() {
        let tabs = [Tab("/a"), Tab("/a"), Tab("/a"), Tab("/b"), Tab("/b")]

        let groups = WorkspaceStore.organizeGroups(
            tabs, key: { key($0.pwd, .folder) }, remembering: [tabs[2], tabs[1]], home: "/Users/me")

        #expect(groups[0].rememberedTab === tabs[1])
        #expect(groups[1].rememberedTab === tabs[3])
    }

    // MARK: Names

    private func names(_ keys: [String?]) -> [String] {
        WorkspaceStore.organizeNames(keys, home: "/Users/me")
    }

    @Test func namesAreBasenamesWithTildeRootAndOther() {
        #expect(names(["/Users/me/code/app", "/Users/me", "/", nil]) == ["app", "~", "/", "Other"])
    }

    @Test func sharedNamesGetTheParentFolder() {
        #expect(names(["/Users/me/work/app", "/Users/me/personal/app", "/Users/me/web"])
            == ["app (work)", "app (personal)", "web"])
    }

    @Test func sharedNamesGetMoreSegmentsUntilTheyDiffer() {
        #expect(names(["/Users/me/work/a/app", "/Users/me/home/a/app"]) == ["app (work/a)", "app (home/a)"])
    }

    @Test func homeAndRootAreOneSegmentEach() {
        #expect(names(["/tmp", "/Users/me/tmp"]) == ["tmp (/)", "tmp (~)"])
        #expect(names(["/a/app", "/b/a/app"]) == ["app (/a)", "app (b/a)"])
    }
}
