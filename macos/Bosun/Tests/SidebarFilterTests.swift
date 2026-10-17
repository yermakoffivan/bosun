import XCTest
@testable import BosunCore

final class SidebarFilterTests: XCTestCase {
    /// The dev.sh fixture: api and docs ungrouped; Work with parser, ticker and web (three tabs);
    /// Reviews (collapsed here) with review-1, review-2 and shell.
    private let sb = Sidebar(
        ungrouped: [
            Container(id: "c-api", name: "api", active: "api", tabs: [Tab(session: "api")]),
            Container(id: "c-docs", name: "docs", active: "docs", tabs: [Tab(session: "docs")]),
        ],
        sections: [
            Section(id: "work", name: "Work", members: [
                Container(id: "c-parser", name: "parser", active: "parser", tabs: [Tab(session: "parser")]),
                Container(id: "c-ticker", name: "ticker", active: "ticker", tabs: [Tab(session: "ticker")]),
                Container(id: "c-web", name: "web", active: "web", tabs: [Tab(session: "web"), Tab(session: "web tests"), Tab(session: "web shell")]),
            ]),
            Section(id: "reviews", name: "Reviews", collapsed: true, members: [
                Container(id: "c-r1", name: "review-1", active: "review-1", tabs: [Tab(session: "review-1")]),
                Container(id: "c-r2", name: "review-2", active: "review-2", tabs: [Tab(session: "review-2")]),
                Container(id: "c-shell", name: "shell", active: "shell", tabs: [Tab(session: "shell")]),
            ]),
        ])

    private var states: [String: AgentState] = ["parser": .waiting, "review-1": .done, "ticker": .running]
    private var agents: [String: String] = ["api": "claude", "docs": "codex"]
    private var dead: Set<String> = []

    private func apply(_ q: String, current: String? = nil) -> FilteredSidebar? {
        SidebarFilter.apply(q, sidebar: sb, current: current, label: { $0.tabs.first?.session ?? $0.name }) { s in
            SidebarFilter.TabInfo(name: s, path: s == "docs" ? "/Users/me/Projects/handbook" : "/tmp/fx",
                                  agent: self.agents[s] ?? "terminal", state: self.states[s] ?? .idle, alive: !self.dead.contains(s))
        }
    }

    func testBlankQueryIsNoFilter() {
        XCTAssertNil(apply(""))
        XCTAssertNil(apply("   "))
        XCTAssertEqual(sb.visibleRows(filter: nil).map(\.id), ["c-api", "c-docs", "c-parser", "c-ticker", "c-web"])
    }

    func testNamesMatchBySubsequenceAndEmptySectionsHide() throws {
        let f = try XCTUnwrap(apply("rev"))
        XCTAssertEqual(f.ungrouped, [])
        // review-1 and review-2 by name, shell because it's in Reviews.
        XCTAssertEqual(f.sections, [.init(id: "reviews", rows: ["c-r1", "c-r2", "c-shell"])])
        XCTAssertEqual(f.countLabel, "3 of 8")
        XCTAssertEqual(apply("review-")?.matchingRows, ["c-r1", "c-r2"])
        // "rw" is a subsequence of "review-1", not a substring.
        XCTAssertEqual(apply("rw")?.matchingRows, ["c-r1", "c-r2"])
        XCTAssertEqual(apply("REVIEW-")?.matchingRows, ["c-r1", "c-r2"], "case-insensitive")
    }

    func testCollapsedSectionsAreSearchedAndNumberedAsShown() throws {
        // Reviews is collapsed: without a filter its rows aren't numbered; with one they are.
        let f = try XCTUnwrap(apply("review-"))
        XCTAssertEqual(sb.visibleRows(filter: f).map(\.id), ["c-r1", "c-r2"])
    }

    func testUnderlinesPreferAWholeRunThenTheSubsequence() {
        XCTAssertEqual(SidebarFilter.matchOffsets("view", in: "review-1"), [2, 3, 4, 5])
        XCTAssertEqual(SidebarFilter.matchOffsets("rw", in: "review-1"), [0, 5])
        XCTAssertEqual(SidebarFilter.matchOffsets("Re", in: "the review"), [4, 5])
        XCTAssertNil(SidebarFilter.matchOffsets("xyz", in: "review"))
        XCTAssertEqual(apply("view")?.nameMatches["c-r1"], [2, 3, 4, 5])
    }

    func testMultiTabRowsMatchAsAUnitWithTheMatchingTabUnderlined() throws {
        let f = try XCTUnwrap(apply("tests"))
        XCTAssertEqual(f.matchingRows, ["c-web"])
        XCTAssertEqual(f.tabMatches["web tests"], [4, 5, 6, 7, 8])
        XCTAssertNil(f.tabMatches["web shell"])
        XCTAssertNil(f.nameMatches["c-web"], "the row is labelled web, which doesn't contain tests")
    }

    func testStateWordsAgentPathAndSection() {
        XCTAssertEqual(apply("wait")?.matchingRows, ["c-parser"])
        XCTAssertEqual(apply("done")?.matchingRows, ["c-r1"])
        XCTAssertEqual(apply("runn")?.matchingRows, ["c-ticker"])
        XCTAssertEqual(apply("claude")?.matchingRows, ["c-api"])
        XCTAssertEqual(apply("handbook")?.matchingRows, ["c-docs"], "the directory's last two components")
        XCTAssertEqual(apply("Projects/hand")?.matchingRows, ["c-docs"])
        XCTAssertEqual(apply("work")?.matchingRows, ["c-parser", "c-ticker", "c-web"], "the section name")
        // A path matches as a whole, not as a scattered subsequence.
        XCTAssertNil(apply("hbk")?.matchingRows.first { $0 == "c-docs" })
    }

    func testExitedMatchesEndedRows() {
        dead = ["docs"]
        XCTAssertEqual(apply("exit")?.matchingRows, ["c-docs"])
    }

    func testOneLetterNeverMatchesAStateWord() {
        // docs is idle and "i" is in nothing else of it: one letter is too little to mean a state.
        XCTAssertFalse(apply("i")?.matchingRows.contains("c-docs") ?? true)
        XCTAssertEqual(apply("id")?.matchingRows.contains("c-docs"), true)
    }

    func testTheRowOnScreenIsNeverHidden() throws {
        let f = try XCTUnwrap(apply("review-", current: "c-web"))
        XCTAssertEqual(f.onScreen, "c-web")
        XCTAssertEqual(f.visibleRows, ["c-r1", "c-r2", "c-web"])
        XCTAssertEqual(f.countLabel, "2 of 8", "the on-screen extra isn't a match")
        // A matching current row is just listed where it is.
        XCTAssertNil(apply("review-", current: "c-r2")?.onScreen)
        // A row id the sidebar doesn't have isn't listed.
        XCTAssertNil(apply("review-", current: "gone")?.onScreen)
    }

    func testNoMatchesStillListsTheRowOnScreen() throws {
        let f = try XCTUnwrap(apply("zzz", current: "c-api"))
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.visibleRows, ["c-api"])
        XCTAssertEqual(f.countLabel, "0 of 8")
    }

    func testVisibleRowsWithAFilterFollowSidebarOrder() throws {
        let f = try XCTUnwrap(apply("sh", current: "c-api"))
        // web (by its tab "web shell") and shell, in sidebar order, then the row on screen.
        XCTAssertEqual(sb.visibleRows(filter: f).map(\.id), ["c-web", "c-shell", "c-api"])
    }

    func testFilterIsAFocusException() {
        var m = FocusModel(active: "a")
        m.begin(.filter)
        XCTAssertFalse(m.terminalOwnsKeyboard)
        XCTAssertNil(m.pointerMoved(to: .zero, over: "b", buttonsDown: false))
        XCTAssertFalse(m.end(.rename), "another exception's end doesn't hand the keyboard back")
        XCTAssertTrue(m.end(.filter))
        XCTAssertTrue(m.terminalOwnsKeyboard)
    }

    func testInkFollowsTheTUIsLuminanceRule() {
        // Light accents get near-black ink, dark ones near-white (the header's anchor tile).
        XCTAssertEqual(RGB(hex: "#fab283")!.ink.hex, "#101218")
        XCTAssertEqual(RGB(hex: "#7c5cff")!.ink.hex, "#f2f3f5")
        XCTAssertEqual(RGB(hex: "#ffd866")!.ink.hex, "#101218")
        XCTAssertEqual(RGB(hex: "#0969da")!.ink.hex, "#f2f3f5")
    }
}
