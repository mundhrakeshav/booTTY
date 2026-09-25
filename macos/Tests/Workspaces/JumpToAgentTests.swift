import Testing
@testable import Ghostty

struct JumpToAgentTests {
    /// Splits by position, named "window.workspace.tab.split", with their agent status.
    private let splits: [(name: String, status: Ghostty.AgentStatus?)] = [
        ("1.1.1.1", nil),
        ("1.1.1.2", .done),
        ("1.1.2.1", nil),
        ("1.2.1.1", .waiting),
        ("2.1.1.1", nil),
        ("2.2.1.1", .waiting),
        ("2.2.1.2", nil),
    ]

    private func next(from start: String?, in splits: [(name: String, status: Ghostty.AgentStatus?)]? = nil) -> String? {
        let splits = splits ?? self.splits
        let index = start.flatMap { name in splits.firstIndex { $0.name == name } }
        return JumpToAgent.next(in: splits, from: index) { $0.status }.map { splits[$0].name }
    }

    @Test func walksByPositionAcrossWorkspacesAndWindows() {
        #expect(next(from: "1.1.1.1") == "1.2.1.1")
        #expect(next(from: "1.2.1.1") == "2.2.1.1")
    }

    @Test func wrapsAroundToEarlierSplits() {
        #expect(next(from: "2.2.1.1") == "1.2.1.1")
        #expect(next(from: "2.2.1.2") == "1.2.1.1")
    }

    @Test func visitsWaitingBeforeDone() {
        // 1.1.1.2 is done and comes next by position, but a waiting Split wins.
        #expect(next(from: "1.1.1.1") == "1.2.1.1")

        let noneWaiting = splits.map { ($0.name, $0.status == .waiting ? nil : $0.status) }
        #expect(next(from: "2.1.1.1", in: noneWaiting) == "1.1.1.2")
    }

    @Test func theSplitYouAreOnDoesNotCount() {
        let oneWaiting: [(name: String, status: Ghostty.AgentStatus?)] = [("a", nil), ("b", .waiting)]
        #expect(next(from: "b", in: oneWaiting) == nil)
        #expect(next(from: "a", in: oneWaiting) == "b")
        #expect(next(from: "a", in: [("a", nil)]) == nil)
        #expect(next(from: nil, in: []) == nil)
    }

    @Test func withNoFocusedSplitStartsAtTheFirst() {
        let splits: [(name: String, status: Ghostty.AgentStatus?)] = [("a", .waiting), ("b", .waiting)]
        #expect(next(from: nil, in: splits) == "a")
    }
}
