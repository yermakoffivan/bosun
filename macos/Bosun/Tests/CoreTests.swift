import XCTest
@testable import BosunCore

final class SplitTreeTests: XCTestCase {
    private func h(_ a: SplitNode, _ b: SplitNode, _ r: Double = 0.5) -> SplitNode { .split(axis: .horizontal, ratio: r, first: a, second: b) }
    private func v(_ a: SplitNode, _ b: SplitNode, _ r: Double = 0.5) -> SplitNode { .split(axis: .vertical, ratio: r, first: a, second: b) }

    func testSplitAndLayout() {
        var t = RowLayout(root: .leaf("a"))
        XCTAssertEqual(t.panes, ["a"])
        t.split(nil, axis: .horizontal, newPane: "b")
        XCTAssertEqual(t.active, "b")
        t.split(nil, axis: .vertical, newPane: "c")
        XCTAssertEqual(t.panes, ["a", "b", "c"])
        let l = t.root!.layout(in: CGRect(x: 0, y: 0, width: 1001, height: 601), gap: 1)
        XCTAssertEqual(l.tiles["a"], CGRect(x: 0, y: 0, width: 500, height: 601))
        XCTAssertEqual(l.tiles["b"], CGRect(x: 501, y: 0, width: 500, height: 300))
        XCTAssertEqual(l.tiles["c"], CGRect(x: 501, y: 301, width: 500, height: 300))
        XCTAssertEqual(l.dividers.count, 2)
        // Panes and dividers never overlap and fill the rect.
        let area = l.tiles.values.reduce(0) { $0 + $1.width * $1.height } + l.dividers.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(area, 1001 * 601)
    }

    func testRatioAndClamp() {
        var t = RowLayout(root: .leaf("a"))
        t.split("a", axis: .horizontal, newPane: "b")
        t.setRatio(at: [], 0.25)
        let l = t.root!.layout(in: CGRect(x: 0, y: 0, width: 401, height: 100), gap: 1)
        XCTAssertEqual(l.tiles["a"]?.width, 100)
        t.setRatio(at: [], 0.01)
        if case .split(_, let r, _, _) = t.root! { XCTAssertEqual(r, 0.1) } else { XCTFail() }
        let d = l.dividers[0]
        XCTAssertEqual(SplitNode.ratio(for: d, at: CGPoint(x: 200.5, y: 0), gap: 1), 0.5, accuracy: 0.001)
    }

    func testNeighbors() {
        // 2x2 grid: a | b over c | d
        let root = h(v(.leaf("a"), .leaf("c")), v(.leaf("b"), .leaf("d")))
        let l = root.layout(in: CGRect(x: 0, y: 0, width: 800, height: 600), gap: 1)
        XCTAssertEqual(SplitNode.neighbor(of: "a", .right, in: l), "b")
        XCTAssertEqual(SplitNode.neighbor(of: "a", .down, in: l), "c")
        XCTAssertEqual(SplitNode.neighbor(of: "d", .left, in: l), "c")
        XCTAssertEqual(SplitNode.neighbor(of: "d", .up, in: l), "b")
        XCTAssertNil(SplitNode.neighbor(of: "a", .left, in: l))
        XCTAssertNil(SplitNode.neighbor(of: "a", .up, in: l))
    }
}

final class RowLayoutTests: XCTestCase {
    private func h(_ a: SplitNode, _ b: SplitNode, _ r: Double = 0.5) -> SplitNode { .split(axis: .horizontal, ratio: r, first: a, second: b) }
    private func v(_ a: SplitNode, _ b: SplitNode, _ r: Double = 0.5) -> SplitNode { .split(axis: .vertical, ratio: r, first: a, second: b) }
    private let a = SplitNode.leaf("a"), b = SplitNode.leaf("b"), c = SplitNode.leaf("c"), d = SplitNode.leaf("d")

    // MARK: First layout of a row

    func testFirstLayoutOfOneToFourTabs() {
        var one = RowLayout()
        one.reconcile(liveTabs: ["a"], preferredActive: "a", aspect: 1.6)
        XCTAssertEqual(one.root, a)
        XCTAssertEqual(one.active, "a")

        var two = RowLayout()
        two.reconcile(liveTabs: ["a", "b"], preferredActive: "b", aspect: 1.6)
        XCTAssertEqual(two.root, h(a, b), "side by side in a landscape area")
        XCTAssertEqual(two.active, "b", "the row's active tab keeps the keyboard")

        var three = RowLayout()
        three.reconcile(liveTabs: ["a", "b", "c"], preferredActive: nil, aspect: 1.6)
        XCTAssertEqual(three.root, h(v(a, c), b), "the third splits the first pane down")
        XCTAssertEqual(three.active, "a", "no active tab given: the first pane")

        var four = RowLayout()
        let change = four.reconcile(liveTabs: ["a", "b", "c", "d"], preferredActive: "c", aspect: 1.6)
        XCTAssertEqual(four.root, h(v(a, c), v(b, d)), "four tabs open as a 2×2 grid, in reading order")
        XCTAssertEqual(change.added, ["a", "b", "c", "d"])
        XCTAssertEqual(four.active, "c")
        let l = four.root!.layout(in: CGRect(x: 0, y: 0, width: 1600, height: 1000), gap: 1)
        XCTAssertEqual(SplitNode.neighbor(of: "a", .right, in: l), "b")
        XCTAssertEqual(SplitNode.neighbor(of: "a", .down, in: l), "c")
        XCTAssertEqual(SplitNode.neighbor(of: "d", .left, in: l), "c")
    }

    func testFirstLayoutInATallAreaStacksFirst() {
        var two = RowLayout()
        two.reconcile(liveTabs: ["a", "b"], preferredActive: nil, aspect: 0.7)
        XCTAssertEqual(two.root, v(a, b))
    }

    func testNineTabsAllGetPanesWithNoneTooSmall() {
        let tabs = (1...9).map { "t\($0)" }
        var row = RowLayout()
        row.reconcile(liveTabs: tabs, preferredActive: nil, aspect: 1.6)
        XCTAssertEqual(Set(row.panes), Set(tabs))
        let l = row.root!.layout(in: CGRect(x: 0, y: 0, width: 1600, height: 1000), gap: 0)
        let areas = l.tiles.values.map { $0.width * $0.height }
        XCTAssertLessThanOrEqual(areas.max()! / areas.min()!, 2.01, "the biggest pane is never more than twice the smallest")
    }

    // MARK: Tabs added, removed or died

    func testTabFromElsewhereSplitsTheBiggestPaneAndLeavesTheActivePane() {
        var row = RowLayout(root: h(a, b, 0.7), active: "b")
        let change = row.reconcile(liveTabs: ["a", "b", "c"], preferredActive: "c", aspect: 1.6)
        XCTAssertEqual(change.added, ["c"])
        XCTAssertTrue(change.removed.isEmpty)
        XCTAssertEqual(row.root, h(h(a, c), b, 0.7), "a (70% wide, so wider than tall) is the biggest pane and splits across; the ratio the user set stays")
        XCTAssertEqual(row.active, "b", "a tab from elsewhere doesn't take the keyboard")
    }

    func testEndedTabLosesItsPaneAndTheSiblingTakesOver() {
        var row = RowLayout(root: h(a, v(b, c, 0.3), 0.6), active: "b")
        let change = row.reconcile(liveTabs: ["a", "c"], preferredActive: "a", aspect: 1.6)
        XCTAssertEqual(change.removed, ["b"])
        XCTAssertEqual(row.root, h(a, c, 0.6), "c takes b's space")
        XCTAssertEqual(row.active, "c", "the active pane went: its sibling gets the keyboard")
    }

    func testEveryTabEndedLeavesNoPanes() {
        var row = RowLayout(root: h(a, b), active: "a")
        row.reconcile(liveTabs: [], preferredActive: "a", aspect: 1.6)
        XCTAssertTrue(row.isEmpty)
        XCTAssertNil(row.active)
        // A restarted tab comes back as the row's pane.
        row.reconcile(liveTabs: ["a"], preferredActive: "a", aspect: 1.6)
        XCTAssertEqual(row.root, a)
        XCTAssertEqual(row.active, "a")
    }

    func testNothingChangesWhenTabsMatch() {
        var row = RowLayout(root: h(a, b, 0.3), active: "b")
        let before = row
        let change = row.reconcile(liveTabs: ["b", "a"], preferredActive: "a", aspect: 1.6)
        XCTAssertTrue(change.isEmpty)
        XCTAssertEqual(row, before, "tab order and the daemon's active tab never rearrange existing panes")
    }

    func testPendingSplitPlacesTheAppsOwnNewTab() {
        var row = RowLayout(root: h(a, b), active: "a")
        let change = row.reconcile(liveTabs: ["a", "b", "c"], preferredActive: "a", aspect: 1.6,
                                   pending: PendingSplit(from: "a", axis: .vertical))
        XCTAssertTrue(change.usedPending)
        XCTAssertEqual(row.root, h(v(a, c), b))
        XCTAssertEqual(row.active, "c", "the app's new pane takes the keyboard")
        // Two new tabs at once: the first takes the pending split, the next one the automatic place.
        var row2 = RowLayout(root: a, active: "a")
        row2.reconcile(liveTabs: ["a", "b", "c"], preferredActive: nil, aspect: 1.6, pending: PendingSplit(from: "a", axis: .horizontal))
        XCTAssertEqual(Set(row2.panes), ["a", "b", "c"])
        XCTAssertEqual(row2.active, "b")
    }

    // MARK: Closing a pane

    func testCloseGivesTheSpaceAndTheKeyboardToTheSibling() {
        // a | (b / c): close c -> b gets its space and the keyboard.
        var row = RowLayout(root: h(a, v(b, c)), active: "c")
        XCTAssertTrue(row.close("c"))
        XCTAssertEqual(row.root, h(a, b))
        XCTAssertEqual(row.active, "b")
        // Closing a pane whose sibling is a subtree: the nearest pane of it (first child's first, second child's last).
        var grid = RowLayout(root: h(a, v(b, c)), active: "a")
        grid.close("a")
        XCTAssertEqual(grid.root, v(b, c))
        XCTAssertEqual(grid.active, "b", "a was the first child: the sibling's first pane")
        var grid2 = RowLayout(root: h(v(a, b), c), active: "c")
        grid2.close("c")
        XCTAssertEqual(grid2.active, "b", "c was the second child: the sibling's last pane")
        // An inactive pane closing leaves the active one alone.
        var row3 = RowLayout(root: h(a, v(b, c)), active: "a")
        row3.close("c")
        XCTAssertEqual(row3.active, "a")
        // The last pane.
        var one = RowLayout(root: a)
        XCTAssertTrue(one.close("a"))
        XCTAssertTrue(one.isEmpty)
        XCTAssertNil(one.active)
        XCTAssertFalse(one.close("zz"))
    }

    func testSplitPutsTheNewPaneRightOrBelowAndActivatesIt() {
        var row = RowLayout(root: h(a, b), active: "a")
        row.split(nil, axis: .vertical, newPane: "c")
        XCTAssertEqual(row.root, h(v(a, c), b))
        XCTAssertEqual(row.active, "c")
        row.split("b", axis: .horizontal, newPane: "d")
        XCTAssertEqual(row.root, h(v(a, c), h(b, d)))
        XCTAssertEqual(row.active, "d")
        var empty = RowLayout()
        empty.split(nil, axis: .horizontal, newPane: "x")
        XCTAssertEqual(empty.root, .leaf("x"))
    }

    // MARK: Tab-order navigation

    func testStepFollowsTabOrderNotPosition() {
        // Laid out d | (a / c) / b, tab order a b c d.
        var row = RowLayout(root: h(d, v(v(a, c), b)), active: "a")
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(row.step(forward: true, order: order), "b")
        row.activate("d")
        XCTAssertEqual(row.step(forward: true, order: order), "a", "wraps")
        XCTAssertEqual(row.step(forward: false, order: order), "c")
        // Tabs without a pane (ended) are skipped; panes the order doesn't know come last.
        XCTAssertEqual(row.step(forward: true, order: ["a", "zz", "d"]), "c", "a, d, then c and b (no tab order) in tree order")
        XCTAssertNil(RowLayout(root: a).step(forward: true, order: ["a"]), "one pane: nowhere to go")
    }

    func testMoveKeepsPanesAndActivatesTheMovedPane() {
        var row = RowLayout(root: h(a, v(b, c)), active: "a")
        XCTAssertTrue(row.move("c", to: "a", zone: .edge(.left)))
        XCTAssertEqual(row.active, "c")
        XCTAssertEqual(row.panes, ["c", "a", "b"])
        let before = row
        XCTAssertFalse(row.move("c", to: "a", zone: .edge(.left)), "same place again is a no-op")
        XCTAssertEqual(row, before)
        XCTAssertTrue(row.move("b", to: "c", zone: .swap))
        XCTAssertEqual(row.panes, ["b", "a", "c"])
        XCTAssertEqual(row.active, "b")
    }

    // MARK: Zoom

    func testZoomShowsTheActivePaneAloneAndKeepsTheTree() {
        var row = RowLayout(root: h(a, v(b, c, 0.3), 0.65), active: "b")
        let tree = row.root
        XCTAssertTrue(row.toggleZoom())
        XCTAssertEqual(row.zoomed, "b")
        XCTAssertEqual(row.shownRoot, b)
        XCTAssertEqual(row.shown, ["b"])
        XCTAssertEqual(row.panes, ["a", "b", "c"], "every pane stays in the row")
        XCTAssertEqual(row.root, tree)
        XCTAssertTrue(row.toggleZoom())
        XCTAssertNil(row.zoomed)
        XCTAssertEqual(row.shownRoot, tree, "unzoomed, ratios and all")
        var one = RowLayout(root: a)
        XCTAssertFalse(one.toggleZoom(), "one pane: nothing to zoom")
        XCTAssertNil(one.zoomed)
    }

    func testZoomFollowsTheActivePane() {
        var row = RowLayout(root: h(a, v(b, c)), active: "a")
        row.toggleZoom()
        row.activate("c")
        XCTAssertEqual(row.zoomed, "c")
        XCTAssertEqual(row.shown, ["c"])
        row.activate("x")
        XCTAssertEqual(row.zoomed, "c", "a pane that isn't in the row changes nothing")
    }

    func testZoomEndsWhenTheRowGainsOrLosesAPane() {
        var split = RowLayout(root: h(a, b), active: "a")
        split.toggleZoom()
        split.split("a", axis: .horizontal, newPane: "c")
        XCTAssertNil(split.zoomed, "Cmd+D shows the new split")

        var closed = RowLayout(root: h(a, v(b, c)), active: "b")
        closed.toggleZoom()
        closed.close("a")
        XCTAssertNil(closed.zoomed)
        XCTAssertEqual(closed.active, "b")

        var arrived = RowLayout(root: h(a, b), active: "a")
        arrived.toggleZoom()
        arrived.reconcile(liveTabs: ["a", "b", "c"], preferredActive: "a", aspect: 1.6)
        XCTAssertNil(arrived.zoomed, "a tab from elsewhere")

        var unchanged = RowLayout(root: h(a, b), active: "a")
        unchanged.toggleZoom()
        unchanged.reconcile(liveTabs: ["a", "b"], preferredActive: "b", aspect: 1.6)
        XCTAssertEqual(unchanged.zoomed, "a", "the same tabs keep the zoom")
    }

    func testOtherWindowsAreSavedAndPruned() throws {
        var saved = SavedLayouts(current: "con-1")
        saved.rows["con-1"] = RowLayout(root: a)
        saved.windows = [.init(row: "con-2", frame: "{{10, 20}, {900, 600}}"), .init(row: "con-3", frame: nil)]
        let back = try XCTUnwrap(SavedLayouts.decode(XCTUnwrap(saved.encoded())))
        XCTAssertEqual(back, saved)
        XCTAssertEqual(back.windows?.map(\.row), ["con-2", "con-3"])
        var pruned = back
        pruned.prune(keeping: ["con-1", "con-3"])
        XCTAssertEqual(pruned.windows?.map(\.row), ["con-3"], "a window whose row is gone doesn't come back")
        let old = #"{"version":2,"current":"con-1","rows":{}}"#
        XCTAssertNil(try XCTUnwrap(SavedLayouts.decode(Data(old.utf8))).windows, "a file from one window")
    }

    func testZoomIsSavedAndOldFilesReadUnzoomed() throws {
        var row = RowLayout(root: h(a, b), active: "b")
        row.toggleZoom()
        var saved = SavedLayouts(current: "con-1")
        saved.rows["con-1"] = row
        let back = try XCTUnwrap(SavedLayouts.decode(XCTUnwrap(saved.encoded())))
        XCTAssertEqual(back.rows["con-1"]?.zoomed, "b")
        let old = #"{"version":2,"current":"con-1","rows":{"con-1":{"root":{"leaf":{"_0":"a"}},"active":"a"}}}"#
        let decoded = try XCTUnwrap(SavedLayouts.decode(Data(old.utf8)))
        XCTAssertNil(decoded.rows["con-1"]?.zoomed)
        XCTAssertEqual(decoded.rows["con-1"]?.active, "a")
    }

    // MARK: Persistence

    func testSavedLayoutsRoundTrip() throws {
        var saved = SavedLayouts(current: "con-2")
        saved.rows["con-1"] = RowLayout(root: h(a, v(b, c, 0.3), 0.65), active: "c")
        saved.rows["con-2"] = RowLayout(root: .leaf("bosun-x-1a2b"), active: "bosun-x-1a2b")
        saved.rows["con-3"] = RowLayout()
        let data = try XCTUnwrap(saved.encoded())
        let back = try XCTUnwrap(SavedLayouts.decode(data))
        XCTAssertEqual(back, saved)
        XCTAssertEqual(back.rows["con-1"]?.active, "c")
        XCTAssertEqual(back.current, "con-2")
        var pruned = back
        pruned.prune(keeping: ["con-1"])
        XCTAssertEqual(Array(pruned.rows.keys), ["con-1"])
        XCTAssertNil(pruned.current, "the shown row is gone")
    }

    func testOldSingleTreeFileIsNotReadAsRowsButNamesItsActiveSession() throws {
        // What the one-tree-per-window build wrote: Int tile ids, and sessions keyed by them.
        let old = #"{"active":2,"nextID":3,"root":{"split":{"ratio":0.5,"second":{"leaf":{"_0":2}},"first":{"leaf":{"_0":1}},"axis":"horizontal"}},"sessions":{"1":"bosun-api-1","2":"bosun-docs-2"}}"#
        let data = Data(old.utf8)
        XCTAssertNil(SavedLayouts.decode(data))
        XCTAssertEqual(SavedLayouts.legacyActiveSession(data), "bosun-docs-2")
        XCTAssertNil(SavedLayouts.legacyActiveSession(Data("{}".utf8)))
        // A file from a later version isn't misread either.
        XCTAssertNil(SavedLayouts.decode(Data(#"{"version":3,"rows":{}}"#.utf8)))
    }

    // MARK: Closing without asking

    func testShellsAtThePrompt() {
        for s in ["zsh", "-zsh", "bash", "-bash", "fish", "sh", "--sh", "dash", "nu", "pwsh"] { XCTAssertTrue(ShellCommand.isShell(s), s) }
        for s in ["python3", "2_1_220", "vim", "node", "", "zshx", "z-sh"] { XCTAssertFalse(ShellCommand.isShell(s), s) }
        XCTAssertFalse(ShellCommand.isShell(nil), "unknown: ask")
    }
}

final class TileMoveTests: XCTestCase {
    private func h(_ a: SplitNode, _ b: SplitNode, _ r: Double = 0.5) -> SplitNode { .split(axis: .horizontal, ratio: r, first: a, second: b) }
    private func v(_ a: SplitNode, _ b: SplitNode, _ r: Double = 0.5) -> SplitNode { .split(axis: .vertical, ratio: r, first: a, second: b) }
    private let l1 = SplitNode.leaf("1"), l2 = SplitNode.leaf("2"), l3 = SplitNode.leaf("3"), l4 = SplitNode.leaf("4")

    func testZones() {
        let r = CGRect(x: 100, y: 50, width: 400, height: 200)
        XCTAssertEqual(TileDropZone.at(CGPoint(x: 300, y: 150), in: r), .swap)
        XCTAssertEqual(TileDropZone.at(CGPoint(x: 110, y: 150), in: r), .edge(.left))
        XCTAssertEqual(TileDropZone.at(CGPoint(x: 490, y: 150), in: r), .edge(.right))
        XCTAssertEqual(TileDropZone.at(CGPoint(x: 300, y: 55), in: r), .edge(.up))
        XCTAssertEqual(TileDropZone.at(CGPoint(x: 300, y: 245), in: r), .edge(.down))
        // A corner goes to the nearer edge.
        XCTAssertEqual(TileDropZone.at(CGPoint(x: 105, y: 80), in: r), .edge(.left))
        XCTAssertEqual(TileDropZone.edge(.right).indicatorRect(in: r), CGRect(x: 300, y: 50, width: 200, height: 200))
        XCTAssertEqual(TileDropZone.edge(.down).indicatorRect(in: r), CGRect(x: 100, y: 150, width: 400, height: 100))
        XCTAssertEqual(TileDropZone.swap.indicatorRect(in: r), r)
    }

    func testMoveToEachEdge() {
        // 1 | (2 / 3): move 3 to each side of 1.
        let root = h(l1, v(l2, l3))
        XCTAssertEqual(root.moving("3", to: "1", zone: .edge(.left)), h(h(l3, l1), l2))
        XCTAssertEqual(root.moving("3", to: "1", zone: .edge(.right)), h(h(l1, l3), l2))
        XCTAssertEqual(root.moving("3", to: "1", zone: .edge(.up)), h(v(l3, l1), l2))
        XCTAssertEqual(root.moving("3", to: "1", zone: .edge(.down)), h(v(l1, l3), l2))
    }

    func testSwapKeepsRatios() {
        let root = h(l1, v(l2, l3, 0.3), 0.7)
        XCTAssertEqual(root.moving("1", to: "3", zone: .swap), h(l3, v(l2, l1, 0.3), 0.7))
    }

    func testNoOps() {
        let root = h(l1, l2, 0.7)
        XCTAssertNil(root.moving("1", to: "1", zone: .swap), "onto itself")
        XCTAssertNil(root.moving("1", to: "1", zone: .edge(.left)), "onto its own edge")
        XCTAssertNil(root.moving("2", to: "1", zone: .edge(.right)), "where it already is (ratio aside)")
        XCTAssertNil(root.moving("1", to: "2", zone: .edge(.left)))
        XCTAssertEqual(root.moving("2", to: "1", zone: .edge(.left)), h(l2, l1))
        XCTAssertEqual(root.moving("2", to: "1", zone: .edge(.down)), v(l1, l2))
        XCTAssertNil(root.moving("5", to: "1", zone: .swap), "a pane not in the tree")
    }

    func testMoveInGridKeepsOtherTilesAndTheirRatios() {
        // (1 / 2) | (3 / 4), move 1 below 4: the left column collapses to 2.
        let root = h(v(l1, l2, 0.4), v(l3, l4, 0.6), 0.3)
        let moved = root.moving("1", to: "4", zone: .edge(.down))
        XCTAssertEqual(moved, h(l2, v(l3, v(l4, l1), 0.6), 0.3))
        XCTAssertEqual(Set(moved!.leaves), ["1", "2", "3", "4"])
    }
}

final class KeyChordTests: XCTestCase {
    func testParse() throws {
        XCTAssertEqual(try KeyChord.parse("Shift+Up"), KeyChord(key: .up, mods: [.shift]))
        XCTAssertEqual(try KeyChord.parse("ctrl+V"), KeyChord(key: .letter("v"), mods: [.control]))
        XCTAssertEqual(try KeyChord.parse("Alt+Left"), KeyChord(key: .left, mods: [.option]))
        XCTAssertEqual(try KeyChord.parse("Option+Shift+Down"), KeyChord(key: .down, mods: [.option, .shift]))
        XCTAssertEqual(try KeyChord.parse("F5"), KeyChord(key: .function(5), mods: []))
        XCTAssertNil(try KeyChord.parse("none"))
        XCTAssertNil(try KeyChord.parse("  "))
        XCTAssertThrowsError(try KeyChord.parse("Hyper+Up"))
        XCTAssertThrowsError(try KeyChord.parse("F13"))
        XCTAssertThrowsError(try KeyChord.parse("v"))
        XCTAssertThrowsError(try KeyChord.parse("Ctrl+Shift+v"))
        XCTAssertThrowsError(try KeyChord.parse("Ctrl+m"))
        XCTAssertThrowsError(try KeyChord.parse("Ctrl+Enter"))
    }

    func testMatch() throws {
        let up = try XCTUnwrap(try KeyChord.parse("Shift+Up"))
        XCTAssertTrue(up.matches(keyCode: 126, charactersIgnoringModifiers: "\u{F700}", mods: [.shift], command: false))
        XCTAssertFalse(up.matches(keyCode: 126, charactersIgnoringModifiers: nil, mods: [.shift, .option], command: false))
        XCTAssertFalse(up.matches(keyCode: 126, charactersIgnoringModifiers: nil, mods: [.shift], command: true))
        XCTAssertFalse(up.matches(keyCode: 125, charactersIgnoringModifiers: nil, mods: [.shift], command: false))
        let v = try XCTUnwrap(try KeyChord.parse("Ctrl+v"))
        XCTAssertTrue(v.matches(keyCode: 9, charactersIgnoringModifiers: "v", mods: [.control], command: false))
        XCTAssertFalse(v.matches(keyCode: 9, charactersIgnoringModifiers: "v", mods: [], command: false))
        let f5 = try XCTUnwrap(try KeyChord.parse("F5"))
        XCTAssertTrue(f5.matches(keyCode: 96, charactersIgnoringModifiers: nil, mods: [], command: false))
    }

    func testDefaultsAndErrors() {
        let nav = NavBindings(nil)
        XCTAssertEqual(nav.chords.count, 5)
        XCTAssertEqual(nav.action(keyCode: 125, charactersIgnoringModifiers: nil, mods: [.shift], command: false), .nextSession)
        XCTAssertEqual(nav.action(keyCode: 123, charactersIgnoringModifiers: nil, mods: [.shift], command: false), .previousTab)
        XCTAssertEqual(nav.action(keyCode: 9, charactersIgnoringModifiers: "v", mods: [.control], command: false), .sendNextKey)
        XCTAssertNil(nav.action(keyCode: 125, charactersIgnoringModifiers: nil, mods: [], command: false))
        var w = KeyBindingsWire()
        w.nextTab = .chord("Shift+Up")
        let dup = NavBindings(w)
        XCTAssertEqual(dup.errors.count, 1)
        w.nextTab = .chord("Bogus+Q")
        XCTAssertEqual(NavBindings(w).errors.count, 1)
    }
}

final class ShellEscapeTests: XCTestCase {
    func testEscape() {
        XCTAssertEqual(ShellEscape.escape("/tmp/plain.png"), "/tmp/plain.png")
        XCTAssertEqual(ShellEscape.escape("/Users/a/My Shot (1).png"), #"/Users/a/My\ Shot\ \(1\).png"#)
        XCTAssertEqual(ShellEscape.escape(##"a'b"c$d&e;f|g*h?i!j#k`l"##), ##"a\'b\"c\$d\&e\;f\|g\*h\?i\!j\#k\`l"##)
        XCTAssertEqual(ShellEscape.escape(#"back\slash"#), #"back\\slash"#)
        XCTAssertEqual(ShellEscape.escape("[x]{y}<z>"), #"\[x\]\{y\}\<z\>"#)
        XCTAssertEqual(ShellEscape.escape("ünï cødé.txt"), #"ünï\ cødé.txt"#)
    }

    func testDropTextJoinsWithSpaces() {
        XCTAssertEqual(ShellEscape.dropText(paths: ["/a b", "/c"]), #"/a\ b /c"#)
    }

    func testQuote() {
        XCTAssertEqual(ShellEscape.quote("bosun-api-1a2b"), "bosun-api-1a2b")
        XCTAssertEqual(ShellEscape.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellEscape.quote(""), "''")
    }
}

final class SeenTrackerTests: XCTestCase {
    func testIdleAfterUnseenRunShowsDone() {
        var t = SeenTracker()
        t.observe("a", state: .idle, title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .idle) // first sight is a baseline
        t.observe("a", state: .running, title: "⠋ work")
        t.observe("a", state: .idle, title: "✳ work")
        XCTAssertEqual(t.display("a", state: .idle), .done)
        t.markSeen("a")
        XCTAssertEqual(t.display("a", state: .idle), .idle)
    }

    func testViewedSessionNeverTurnsDone() {
        var t = SeenTracker()
        t.observe("a", state: .idle, title: nil)
        t.setViewed(["a"])
        t.observe("a", state: .running, title: nil)
        t.observe("a", state: .idle, title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .idle)
        // Once it leaves the screen, a new turn counts again.
        t.setViewed([])
        t.observe("a", state: .running, title: nil)
        t.observe("a", state: .idle, title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .done)
        // Showing it clears done straight away.
        t.setViewed(["a"])
        XCTAssertEqual(t.display("a", state: .idle), .idle)
    }

    func testRedrawWithoutWorkIsNotDone() {
        var t = SeenTracker()
        t.observe("a", state: .idle, title: "one")
        t.observe("a", state: .idle, title: "two")
        XCTAssertEqual(t.display("a", state: .idle), .idle)
    }

    func testHookDoneCountsAsRan() {
        var t = SeenTracker()
        t.observe("a", state: .idle, title: nil)
        t.observe("a", state: .done, title: nil)
        t.observe("a", state: .idle, title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .done)
        XCTAssertEqual(t.display("a", state: .waiting), .waiting)
    }

    // Hook rule: done while the hook's done_at is newer than the user's last input.

    private func hookDone(_ at: UInt64) -> StatusInfo { StatusInfo(state: .idle, source: "hook", doneAt: at) }
    private let hookRunning = StatusInfo(state: .running, source: "hook")

    func testHookDoneAfterATurnWhileVisible() {
        var t = SeenTracker()
        t.setViewed(["a"])
        t.observe("a", status: hookRunning, title: "⠋ work")
        t.observe("a", status: hookDone(1_000), title: "✳ work")
        XCTAssertEqual(t.display("a", state: .idle), .done)
        // Looking at it, or it staying on screen, doesn't clear it.
        t.markSeen("a")
        t.setViewed(["a"])
        XCTAssertEqual(t.display("a", state: .idle), .done)
        // Off screen too.
        t.setViewed([])
        XCTAssertEqual(t.display("a", state: .idle), .done)
    }

    func testHookDoneClearedByInput() {
        var t = SeenTracker()
        t.setViewed(["a"])
        t.observe("a", status: hookDone(1_000), title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .done)
        // Input from before the turn finished doesn't count.
        t.noteInput("a", at: 900)
        XCTAssertEqual(t.display("a", state: .idle), .done)
        t.noteInput("a", at: 1_500)
        XCTAssertEqual(t.display("a", state: .idle), .idle)
        // Another session's input is its own.
        t.observe("b", status: hookDone(1_000), title: nil)
        XCTAssertEqual(t.display("b", state: .idle), .done)
    }

    func testHookDoneClearedByRunning() {
        var t = SeenTracker()
        t.observe("a", status: hookDone(1_000), title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .done)
        t.observe("a", status: hookRunning, title: nil)
        XCTAssertEqual(t.display("a", state: .running), .running)
        // A status arriving late with the old done_at doesn't bring it back.
        t.observe("a", status: hookDone(1_000), title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .idle)
        // A newer non-done hook state (idle without done_at) isn't done either.
        t.observe("b", status: hookDone(1_000), title: nil)
        t.observe("b", status: StatusInfo(state: .idle, source: "hook"), title: nil)
        XCTAssertEqual(t.display("b", state: .idle), .idle)
        // Nor a hook waiting state.
        t.observe("c", status: hookDone(1_000), title: nil)
        t.observe("c", status: StatusInfo(state: .waiting, source: "hook", detail: "permission: Bash"), title: nil)
        XCTAssertEqual(t.display("c", state: .waiting), .waiting)
    }

    func testSecondTurnAfterInputShowsDoneAgain() {
        var t = SeenTracker()
        t.setViewed(["a"])
        t.observe("a", status: hookDone(1_000), title: nil)
        t.noteInput("a", at: 1_200)
        XCTAssertEqual(t.display("a", state: .idle), .idle)
        t.observe("a", status: hookRunning, title: nil)
        t.observe("a", status: hookDone(2_000), title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .done)
        // Even when the poll missed the running state in between.
        t.noteInput("a", at: 2_100)
        t.observe("a", status: hookDone(3_000), title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .done)
        // Forgetting the session drops its input time.
        t.forget("a")
        t.observe("a", status: hookDone(3_000), title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .done)
    }

    func testDetectorSessionsKeepTheSeenRule() {
        var t = SeenTracker()
        let idle = StatusInfo(state: .idle, source: "detector")
        let running = StatusInfo(state: .running, source: "detector")
        // On screen: never done, whatever the input.
        t.setViewed(["a"])
        t.observe("a", status: idle, title: nil)
        t.observe("a", status: running, title: nil)
        t.observe("a", status: idle, title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .idle)
        // Off screen: ran and changed is done, and input doesn't clear it; looking does.
        t.setViewed([])
        t.observe("a", status: running, title: nil)
        t.observe("a", status: idle, title: nil)
        t.noteInput("a", at: UInt64.max)
        XCTAssertEqual(t.display("a", state: .idle), .done)
        t.setViewed(["a"])
        XCTAssertEqual(t.display("a", state: .idle), .idle)
        // A session that falls back from its hook to the detectors (the agent exited) goes back to this rule.
        t.observe("b", status: hookDone(1_000), title: nil)
        t.observe("b", status: idle, title: nil)
        XCTAssertEqual(t.display("b", state: .idle), .idle)
    }
}

final class FocusModelTests: XCTestCase {
    func testClickConsumesOnlyForInactiveTile() {
        var f = FocusModel(active: "1")
        f.setTiles(count: 2, active: "1")
        XCTAssertEqual(f.click(on: "1"), .passThrough)
        XCTAssertEqual(f.click(on: "2"), .activateAndConsume("2"))
    }

    func testHoverGuards() {
        var f = FocusModel(active: "1")
        f.setTiles(count: 2, active: "1")
        // First event only records the position.
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 10, y: 10), over: "2", buttonsDown: false))
        XCTAssertEqual(f.pointerMoved(to: CGPoint(x: 11, y: 10), over: "2", buttonsDown: false), "2")
        // Same point again (a layout moved a tile under a still pointer): nothing.
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 11, y: 10), over: "2", buttonsDown: false))
        // Button held.
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 12, y: 10), over: "2", buttonsDown: true))
        // Exceptions block hover.
        f.begin(.rename)
        XCTAssertFalse(f.terminalOwnsKeyboard)
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 13, y: 10), over: "2", buttonsDown: false))
        XCTAssertTrue(f.end(.rename))
        XCTAssertTrue(f.terminalOwnsKeyboard)
        XCTAssertFalse(f.end(.rename))
        // Window not key.
        f.setWindowKey(false)
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 14, y: 10), over: "2", buttonsDown: false))
        f.setWindowKey(true)
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 15, y: 10), over: "2", buttonsDown: false)) // re-baseline after key
        XCTAssertEqual(f.pointerMoved(to: CGPoint(x: 16, y: 10), over: "2", buttonsDown: false), "2")
        // Setting off.
        f.followsMouse = false
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 17, y: 10), over: "2", buttonsDown: false))
    }

    func testSingleTileNeverHoverActivatesOrShowsRing() {
        var f = FocusModel(active: "1")
        f.setTiles(count: 1, active: "1")
        XCTAssertFalse(f.showsRing)
        _ = f.pointerMoved(to: .zero, over: "1", buttonsDown: false)
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 5, y: 5), over: "1", buttonsDown: false))
        f.setTiles(count: 2, active: "1")
        XCTAssertTrue(f.showsRing)
    }

    func testExceptionHandOff() {
        var f = FocusModel(active: "1")
        f.begin(.palette)
        XCTAssertFalse(f.end(.sheet)) // closing something that isn't open hands nothing back
        XCTAssertFalse(f.terminalOwnsKeyboard)
        f.begin(.sheet)
        XCTAssertTrue(f.end(.sheet))
        XCTAssertTrue(f.terminalOwnsKeyboard)
    }
}

final class SidebarOpsTests: XCTestCase {
    func sample() -> Sidebar {
        func row(_ id: String, _ tabs: [String]) -> Container {
            Container(id: id, name: id, active: tabs[0], tabs: tabs.map { Tab(session: $0, display: $0, alive: true) })
        }
        return Sidebar(ungrouped: [row("u1", ["a"]), row("u2", ["b", "b2"])],
                       sections: [Section(id: "s1", name: "Work", members: [row("w1", ["c"]), row("w2", ["d"])]),
                                  Section(id: "s2", name: "Play", collapsed: true, members: [row("p1", ["e"])])])
    }

    func testCycleOrderMatchesTUI() {
        let sb = sample()
        let order = sb.cycleOrder { $0 != "d" }
        XCTAssertEqual(order, ["a", "b", "c", "e"]) // collapsed sections count, dead rows don't
        XCTAssertEqual(Sidebar.cycle(order, from: "e", forward: true), "a")
        XCTAssertEqual(Sidebar.cycle(order, from: "a", forward: false), "e")
        XCTAssertEqual(Sidebar.cycle(order, from: nil, forward: true), "a")
        XCTAssertEqual(sb.visibleRows.map(\.id), ["u1", "u2", "w1", "w2"])
    }

    func testTabs() {
        var sb = sample()
        XCTAssertEqual(sb.cycleTab(from: "b", forward: true) { _ in true }, "b2")
        XCTAssertEqual(sb.cycleTab(from: "b2", forward: true) { _ in true }, "b")
        XCTAssertNil(sb.cycleTab(from: "a", forward: true) { _ in true })
        XCTAssertTrue(sb.setActive("b2"))
        XCTAssertEqual(sb.container(id: "u2")?.active, "b2")
        XCTAssertFalse(sb.setActive("b2"))
        XCTAssertTrue(sb.moveTab(session: "b2", toIndex: 0))
        XCTAssertEqual(sb.container(id: "u2")?.tabs.map(\.session), ["b2", "b"])
    }

    func testRemoveTab() {
        var sb = sample()
        XCTAssertTrue(sb.setActive("b2"))
        XCTAssertTrue(sb.removeTab(session: "b2"))
        XCTAssertEqual(sb.container(id: "u2")?.tabs.map(\.session), ["b"])
        XCTAssertEqual(sb.container(id: "u2")?.active, "b", "the removed tab was active: its neighbour is")
        XCTAssertFalse(sb.removeTab(session: "b"), "a row's only tab stays")
        XCTAssertFalse(sb.removeTab(session: "zz"))
    }

    func testMoveRows() {
        var sb = sample()
        // Reorder within ungrouped (index in pre-removal coordinates).
        XCTAssertTrue(sb.moveRow(id: "u1", toSection: nil, index: 2))
        XCTAssertEqual(sb.ungrouped.map(\.id), ["u2", "u1"])
        // Into a section.
        XCTAssertTrue(sb.moveRow(id: "u1", toSection: "s1", index: 1))
        XCTAssertEqual(sb.sections[0].members.map(\.id), ["w1", "u1", "w2"])
        XCTAssertEqual(sb.location(ofRow: "u1"), RowLocation(section: "s1", index: 1))
        // Back out to ungrouped, first.
        XCTAssertTrue(sb.moveRow(id: "w2", toSection: nil, index: 0))
        XCTAssertEqual(sb.ungrouped.map(\.id), ["w2", "u2"])
        XCTAssertFalse(sb.moveRow(id: "w2", toSection: nil, index: 0))
        XCTAssertFalse(sb.moveRow(id: "nope", toSection: nil, index: 0))
        XCTAssertFalse(sb.moveRow(id: "u2", toSection: "missing", index: 0))
    }

    func testMoveSectionsAndCollapse() {
        var sb = sample()
        XCTAssertTrue(sb.moveSection(id: "s1", toIndex: 2))
        XCTAssertEqual(sb.sections.map(\.id), ["s2", "s1"])
        XCTAssertTrue(sb.setCollapsed(section: "s2", false))
        XCTAssertFalse(sb.setCollapsed(section: "s2", false))
        XCTAssertEqual(sb.removeRow(id: "p1")?.id, "p1")
        XCTAssertEqual(sb.container(holding: "c")?.id, "w1")
        XCTAssertEqual(sb.section(holdingRow: "w1")?.name, "Work")
    }
}

final class MiscCoreTests: XCTestCase {
    func testFuzzy() {
        XCTAssertNotNil(Fuzzy.score("api", "api server"))
        XCTAssertNil(Fuzzy.score("xyz", "api server"))
        XCTAssertGreaterThan(Fuzzy.score("as", "api server")!, Fuzzy.score("as", "bananas")!)
        XCTAssertEqual(Fuzzy.score("", "x"), 0)
    }

    func testSlug() {
        XCTAssertEqual(Slug.make("Fix the Parser!"), "fix-the-parser")
        XCTAssertEqual(Slug.make("--a--b--"), "a-b")
    }

    func testRGBAndThemeMap() {
        let c = RGB(hex: "#2e3440")!
        XCTAssertEqual(c.hex, "#2e3440")
        XCTAssertTrue(c.isDark)
        XCTAssertFalse(RGB(hex: "#fafafa")!.isDark)
        XCTAssertNil(RGB(hex: "nope"))
        var p = ThemePalette.fallback
        p.terminal = nil
        XCTAssertEqual(ThemeMap.configLines(for: p, available: ["TokyoNight"]).first, "background = #0b0d12")
        p.name = "tokyonight"
        // A counterpart's colours are written out, so they beat colours set in the user's Ghostty config.
        let file = "# TokyoNight\npalette = 0=#15161e\nbackground = #1a1b26\nforeground=#c0caf5\nfont-size = 14\n\n"
        XCTAssertEqual(ThemeMap.configLines(for: p, available: ["TokyoNight"]) { $0 == "TokyoNight" ? file : nil },
                       ["palette = 0=#15161e", "background = #1a1b26", "foreground = #c0caf5"])
        // Unreadable or not bundled: a generated palette.
        XCTAssertEqual(ThemeMap.configLines(for: p, available: ["TokyoNight"]) { _ in nil }.count, 21)
        XCTAssertEqual(ThemeMap.configLines(for: p, available: []).count, 21)
        XCTAssertEqual(ThemeMap.generated(p).filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    private func terminalTable(background: String = "#101010") -> TerminalPalette {
        TerminalPalette(ghostty: "Some Theme", background: background, foreground: "#eeeeee", cursor: "#ff00ff",
                        selectionBg: "#333333", selectionFg: "#fafafa",
                        palette: (0..<16).map { String(format: "#%02x%02x%02x", $0 * 10, $0 * 12, $0 * 14) })
    }

    func testThemeMapPrefersTheThemesOwnTable() {
        var p = ThemePalette.fallback
        p.name = "tokyonight"
        p.terminal = terminalTable()
        let ghosttyFile = "background = #1a1b26\npalette = 0=#15161e\n"
        // The table wins over the Ghostty counterpart in the name map, and over the generator.
        let lines = ThemeMap.configLines(for: p, available: ["TokyoNight"]) { _ in ghosttyFile }
        XCTAssertEqual(lines.count, 21)
        XCTAssertEqual(Array(lines.prefix(5)), ["background = #101010", "foreground = #eeeeee", "cursor-color = #ff00ff",
                                                "selection-background = #333333", "selection-foreground = #fafafa"])
        XCTAssertEqual(lines[5], "palette = 0=#000000")
        XCTAssertEqual(lines[20], "palette = 15=#96b4d2")
        // A name the map has never heard of still gets its table.
        p.name = "my-theme"
        XCTAssertEqual(ThemeMap.configLines(for: p, available: []).first, "background = #101010")
        // No table: the name map applies, as before the table existed.
        p.name = "tokyonight"
        p.terminal = nil
        XCTAssertEqual(ThemeMap.configLines(for: p, available: ["TokyoNight"]) { _ in ghosttyFile },
                       ["background = #1a1b26", "palette = 0=#15161e"])
        // No table and no counterpart: generated.
        p.name = "my-theme"
        XCTAssertEqual(ThemeMap.configLines(for: p, available: ["TokyoNight"]) { _ in ghosttyFile }, ThemeMap.generated(p))
    }

    func testThemeMapIgnoresATableItCannotUse() {
        var p = ThemePalette.fallback
        p.name = "tokyonight"
        let file = "background = #1a1b26\n"
        var short = terminalTable()
        short.palette.removeLast()
        var bad = terminalTable()
        bad.cursor = "magenta"
        for t in [short, bad] {
            p.terminal = t
            XCTAssertNil(ThemeMap.tableLines(t))
            XCTAssertEqual(ThemeMap.configLines(for: p, available: ["TokyoNight"]) { _ in file }, ["background = #1a1b26"])
        }
        p.terminal = terminalTable()
        XCTAssertEqual(ThemeMap.tableLines(p.terminal!)?.count, 21)
    }

    func testGeneratedPaletteIsLiftedToReadOnTheBackground() {
        // Status colours that mix to under 2:1 on a dark background.
        var p = ThemePalette.fallback
        p.terminal = nil
        p.name = "dim"
        p.bg = "#101418"; p.text = "#c8ccd4"; p.textMuted = "#7b818d"
        p.statusError = "#5a2a2e"; p.statusRunning = "#2a4a30"; p.statusWaiting = "#4a3a20"; p.statusDone = "#203a5a"
        let bg = RGB(hex: p.bg)!
        let lines = ThemeMap.generated(p)
        let palette = lines.filter { $0.hasPrefix("palette = ") }.map { String($0.split(separator: "=").last!.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(palette.count, 16)
        for i in Array(1...6) + Array(9...14) {
            XCTAssertGreaterThanOrEqual(RGB(hex: palette[i])!.contrast(with: bg), 3 - 0.02, "ANSI \(i) \(palette[i])")
        }
        // Black stays near the background and white stays the text colour.
        XCTAssertLessThan(RGB(hex: palette[0])!.contrast(with: bg), 2)
        XCTAssertEqual(palette[7], "#c8ccd4")
        // A palette that already reads is left as it was: the colour of a bright status stays within a hair.
        p.statusError = "#ff5d6b"
        let red = RGB(hex: ThemeMap.generated(p).filter { $0.hasPrefix("palette = 1=") }[0].split(separator: "=").last.map(String.init)!)!
        XCTAssertGreaterThanOrEqual(red.contrast(with: bg), 3)
        XCTAssertEqual(red.hex, "#ff5d6b")
    }

    func testTerminalSyncSwitchesEveryoneOnOnce() {
        XCTAssertTrue(TerminalSync.defaultOn)
        XCTAssertEqual(TerminalSync.note, "Terminals now follow the Bosun theme (Settings → Theme to change)")
        // First launch with sync: a stored off (the old default) is switched on and the user is told.
        XCTAssertEqual(TerminalSync.migrate(stored: false, alreadyMigrated: false, existingInstall: true).turnOn, true)
        XCTAssertEqual(TerminalSync.migrate(stored: false, alreadyMigrated: false, existingInstall: true).note, true)
        // Never stored: on by the default already, still worth a note for an existing install.
        XCTAssertEqual(TerminalSync.migrate(stored: nil, alreadyMigrated: false, existingInstall: true).turnOn, false)
        XCTAssertEqual(TerminalSync.migrate(stored: nil, alreadyMigrated: false, existingInstall: true).note, true)
        // Already following the theme: nothing changes, nothing to say.
        XCTAssertEqual(TerminalSync.migrate(stored: true, alreadyMigrated: false, existingInstall: true).note, false)
        // A brand-new install has nothing to announce.
        XCTAssertEqual(TerminalSync.migrate(stored: nil, alreadyMigrated: false, existingInstall: false).note, false)
        // After the first launch, an off chosen in Settings sticks.
        XCTAssertEqual(TerminalSync.migrate(stored: false, alreadyMigrated: true, existingInstall: true).turnOn, false)
        XCTAssertEqual(TerminalSync.migrate(stored: false, alreadyMigrated: true, existingInstall: true).note, false)
    }

    func testContrastRatio() {
        XCTAssertEqual(RGB(hex: "#000000")!.contrast(with: RGB(hex: "#ffffff")!), 21, accuracy: 0.001)
        XCTAssertEqual(RGB(hex: "#777777")!.contrast(with: RGB(hex: "#777777")!), 1, accuracy: 0.001)
    }

    func testPercentile() {
        XCTAssertEqual(Stats.percentile([5, 1, 3, 2, 4], 50), 3)
        XCTAssertEqual(Stats.percentile([5, 1, 3, 2, 4], 99), 5)
        XCTAssertTrue(Stats.percentile([], 50).isNaN)
    }
}

final class LinkTargetTests: XCTestCase {
    private let files: Set<String> = ["/proj/src/app.rs", "/proj/README.md", "/home/me/notes.txt", "/abs/file.swift", "/proj/dir"]
    private func resolve(_ s: String, cwd: String? = "/proj") -> LinkTarget? {
        LinkTarget.resolve(s, cwd: cwd, home: "/home/me", exists: { self.files.contains($0) })
    }

    func testURLs() {
        XCTAssertEqual(resolve("https://example.com/a?b=1"), .url(URL(string: "https://example.com/a?b=1")!))
        XCTAssertEqual(resolve("mailto:a@b.c"), .url(URL(string: "mailto:a@b.c")!))
        // Foundation would read `app.rs:42` as a URL with the scheme `app.rs`; libghostty means a path.
        XCTAssertFalse(LinkTarget.isURL("app.rs:42"))
        XCTAssertNil(resolve("app.rs:42"))
    }

    func testPaths() {
        XCTAssertEqual(resolve("/abs/file.swift"), .file("/abs/file.swift"))
        XCTAssertEqual(resolve("/abs/file.swift:12"), .file("/abs/file.swift", line: 12))
        XCTAssertEqual(resolve("src/app.rs:42"), .file("/proj/src/app.rs", line: 42))
        XCTAssertEqual(resolve("src/app.rs:42:7"), .file("/proj/src/app.rs", line: 42, column: 7))
        XCTAssertEqual(resolve("./README.md"), .file("/proj/README.md"))
        XCTAssertEqual(resolve("../proj/dir"), .file("/proj/dir"))
        XCTAssertEqual(resolve("~/notes.txt"), .file("/home/me/notes.txt"))
        XCTAssertEqual(resolve("$HOME/notes.txt:3", cwd: nil), .file("/home/me/notes.txt", line: 3))
    }

    func testEditorArguments() {
        func args(_ editor: String, _ line: Int? = 42, _ column: Int? = 7) -> [String]? {
            EditorCommand.arguments(editor: editor, path: "/p/a.rs", line: line, column: column).map { [$0.program] + $0.args }
        }
        XCTAssertEqual(args("zed"), ["zed", "/p/a.rs:42:7"])
        XCTAssertEqual(args("zed", 42, nil), ["zed", "/p/a.rs:42"])
        XCTAssertEqual(args("zed", nil, nil), ["zed", "/p/a.rs"])
        XCTAssertEqual(args("code"), ["code", "-g", "/p/a.rs:42:7"])
        XCTAssertEqual(args("code -n"), ["code", "-n", "-g", "/p/a.rs:42:7"])
        XCTAssertEqual(args("/usr/local/bin/cursor", nil, nil), ["/usr/local/bin/cursor", "/p/a.rs"])
        XCTAssertEqual(args("xed"), ["xed", "-l", "42", "/p/a.rs"])
        XCTAssertEqual(args("bbedit"), ["bbedit", "+42", "/p/a.rs"])
        XCTAssertEqual(args("nvim"), ["nvim", "/p/a.rs"])
        XCTAssertNil(args("  "))
    }

    func testEditorResolve() {
        let installed: Set<String> = ["/opt/homebrew/bin/zed", "/Users/me/bin/tool"]
        let exe = { installed.contains($0) }
        XCTAssertEqual(EditorCommand.resolve("zed", searchPath: "/usr/bin:/opt/homebrew/bin", isExecutable: exe), "/opt/homebrew/bin/zed")
        XCTAssertNil(EditorCommand.resolve("code", searchPath: "/usr/bin:/opt/homebrew/bin", isExecutable: exe))
        XCTAssertEqual(EditorCommand.resolve("/Users/me/bin/tool", searchPath: "", isExecutable: exe), "/Users/me/bin/tool")
    }

    func testMissingOrUnresolvable() {
        XCTAssertNil(resolve("src/missing.rs:1"))
        XCTAssertNil(resolve("src/app.rs", cwd: nil))
        XCTAssertNil(resolve("$PROJ/src/app.rs"))
        XCTAssertNil(resolve(""))
    }

    func testStripLineSuffix() {
        XCTAssertEqual(LinkTarget.stripLineSuffix("a.rs:1:2"), "a.rs")
        XCTAssertEqual(LinkTarget.stripLineSuffix("a.rs:12"), "a.rs")
        XCTAssertEqual(LinkTarget.stripLineSuffix("a.rs"), "a.rs")
        XCTAssertEqual(LinkTarget.stripLineSuffix("a:b"), "a:b")
        XCTAssertEqual(LinkTarget.stripLineSuffix(":12"), ":12")
    }
}
