import XCTest
@testable import BosunCore

final class SplitTreeTests: XCTestCase {
    func testSplitAndLayout() {
        var t = TileLayout()
        XCTAssertEqual(t.tiles, [1])
        let right = t.splitActive(.horizontal)
        XCTAssertEqual(right, 2)
        XCTAssertEqual(t.active, 2)
        let below = t.splitActive(.vertical)
        XCTAssertEqual(below, 3)
        XCTAssertEqual(t.tiles, [1, 2, 3])
        let l = t.root.layout(in: CGRect(x: 0, y: 0, width: 1001, height: 601), gap: 1)
        XCTAssertEqual(l.tiles[1], CGRect(x: 0, y: 0, width: 500, height: 601))
        XCTAssertEqual(l.tiles[2], CGRect(x: 501, y: 0, width: 500, height: 300))
        XCTAssertEqual(l.tiles[3], CGRect(x: 501, y: 301, width: 500, height: 300))
        XCTAssertEqual(l.dividers.count, 2)
        // Tiles and dividers never overlap and fill the rect.
        let area = l.tiles.values.reduce(0) { $0 + $1.width * $1.height } + l.dividers.reduce(0) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(area, 1001 * 601)
    }

    func testRatioAndClamp() {
        var t = TileLayout()
        t.splitActive(.horizontal)
        t.setRatio(at: [], 0.25)
        let l = t.root.layout(in: CGRect(x: 0, y: 0, width: 401, height: 100), gap: 1)
        XCTAssertEqual(l.tiles[1]?.width, 100)
        t.setRatio(at: [], 0.01)
        if case .split(_, let r, _, _) = t.root { XCTAssertEqual(r, 0.1) } else { XCTFail() }
        let d = l.dividers[0]
        XCTAssertEqual(SplitNode.ratio(for: d, at: CGPoint(x: 200.5, y: 0), gap: 1), 0.5, accuracy: 0.001)
    }

    func testCloseKeepsSiblingAndPicksActive() {
        var t = TileLayout()
        t.assign("a", to: 1)
        t.splitActive(.horizontal)
        t.assign("b", to: 2)
        t.splitActive(.vertical)
        t.assign("c", to: 3)
        XCTAssertEqual(t.close(3), "c")
        XCTAssertEqual(t.tiles, [1, 2])
        XCTAssertEqual(t.active, 2)
        XCTAssertEqual(t.close(1), "a")
        XCTAssertEqual(t.root, .leaf(2))
        // The last tile empties instead of closing.
        XCTAssertEqual(t.close(2), "b")
        XCTAssertEqual(t.tiles, [2])
        XCTAssertNil(t.activeSession)
    }

    func testOneSessionPerTile() {
        var t = TileLayout()
        t.assign("a", to: 1)
        t.splitActive(.horizontal)
        t.assign("a", to: 2)
        XCTAssertNil(t.session(in: 1))
        XCTAssertEqual(t.tile(showing: "a"), 2)
        XCTAssertEqual(t.assign("b", to: 2), "a")
    }

    func testTileCap() {
        var t = TileLayout()
        for _ in 0..<20 { t.splitActive(.horizontal) }
        XCTAssertEqual(t.count, TileLayout.maxTiles)
    }

    func testNeighbors() {
        // 2x2 grid: 1 | 2 over 3 | 4
        var t = TileLayout()
        t.splitActive(.horizontal) // 2 right of 1
        t.activate(1)
        t.splitActive(.vertical) // 3 below 1
        t.activate(2)
        t.splitActive(.vertical) // 4 below 2
        let l = t.root.layout(in: CGRect(x: 0, y: 0, width: 800, height: 600), gap: 1)
        XCTAssertEqual(SplitNode.neighbor(of: 1, .right, in: l), 2)
        XCTAssertEqual(SplitNode.neighbor(of: 1, .down, in: l), 3)
        XCTAssertEqual(SplitNode.neighbor(of: 4, .left, in: l), 3)
        XCTAssertEqual(SplitNode.neighbor(of: 4, .up, in: l), 2)
        XCTAssertNil(SplitNode.neighbor(of: 1, .left, in: l))
        XCTAssertNil(SplitNode.neighbor(of: 1, .up, in: l))
    }

    func testCodableRoundTrip() throws {
        var t = TileLayout()
        t.assign("a", to: 1)
        t.splitActive(.vertical)
        t.assign("b", to: 2)
        let back = try JSONDecoder().decode(TileLayout.self, from: try JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
        var b2 = back
        XCTAssertEqual(b2.splitActive(.horizontal), 3)
    }
}

final class TileMoveTests: XCTestCase {
    private func h(_ a: SplitNode, _ b: SplitNode, _ r: Double = 0.5) -> SplitNode { .split(axis: .horizontal, ratio: r, first: a, second: b) }
    private func v(_ a: SplitNode, _ b: SplitNode, _ r: Double = 0.5) -> SplitNode { .split(axis: .vertical, ratio: r, first: a, second: b) }
    private let l1 = SplitNode.leaf(1), l2 = SplitNode.leaf(2), l3 = SplitNode.leaf(3), l4 = SplitNode.leaf(4)

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
        XCTAssertEqual(root.moving(3, to: 1, zone: .edge(.left)), h(h(l3, l1), l2))
        XCTAssertEqual(root.moving(3, to: 1, zone: .edge(.right)), h(h(l1, l3), l2))
        XCTAssertEqual(root.moving(3, to: 1, zone: .edge(.up)), h(v(l3, l1), l2))
        XCTAssertEqual(root.moving(3, to: 1, zone: .edge(.down)), h(v(l1, l3), l2))
    }

    func testSwapKeepsRatios() {
        let root = h(l1, v(l2, l3, 0.3), 0.7)
        XCTAssertEqual(root.moving(1, to: 3, zone: .swap), h(l3, v(l2, l1, 0.3), 0.7))
    }

    func testNoOps() {
        let root = h(l1, l2, 0.7)
        XCTAssertNil(root.moving(1, to: 1, zone: .swap), "onto itself")
        XCTAssertNil(root.moving(1, to: 1, zone: .edge(.left)), "onto its own edge")
        XCTAssertNil(root.moving(2, to: 1, zone: .edge(.right)), "where it already is (ratio aside)")
        XCTAssertNil(root.moving(1, to: 2, zone: .edge(.left)))
        XCTAssertEqual(root.moving(2, to: 1, zone: .edge(.left)), h(l2, l1))
        XCTAssertEqual(root.moving(2, to: 1, zone: .edge(.down)), v(l1, l2))
        XCTAssertNil(root.moving(5, to: 1, zone: .swap), "a tile not in the tree")
    }

    func testMoveInGridKeepsOtherTilesAndTheirRatios() {
        // (1 / 2) | (3 / 4), move 1 below 4: the left column collapses to 2.
        let root = h(v(l1, l2, 0.4), v(l3, l4, 0.6), 0.3)
        let moved = root.moving(1, to: 4, zone: .edge(.down))
        XCTAssertEqual(moved, h(l2, v(l3, v(l4, l1), 0.6), 0.3))
        XCTAssertEqual(Set(moved!.leaves), [1, 2, 3, 4])
    }

    func testLayoutMoveKeepsSessionsAndActivatesMovedTile() {
        var t = TileLayout()
        t.assign("a", to: 1)
        let two = t.splitActive(.horizontal)!
        t.assign("b", to: two)
        let three = t.splitActive(.vertical)!
        t.assign("c", to: three)
        t.activate(1)
        XCTAssertTrue(t.move(three, to: 1, zone: .edge(.left)))
        XCTAssertEqual(t.active, three)
        XCTAssertEqual(t.session(in: three), "c")
        XCTAssertEqual(t.session(in: 1), "a")
        XCTAssertEqual(t.tiles, [three, 1, two])
        let before = t
        XCTAssertFalse(t.move(three, to: 1, zone: .edge(.left)), "same place again is a no-op")
        XCTAssertEqual(t, before)
        XCTAssertTrue(t.move(two, to: three, zone: .swap))
        XCTAssertEqual(t.tiles, [two, 1, three])
        XCTAssertEqual(t.active, two)
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
}

final class FocusModelTests: XCTestCase {
    func testClickConsumesOnlyForInactiveTile() {
        var f = FocusModel(active: 1)
        f.setTiles(count: 2, active: 1)
        XCTAssertEqual(f.click(on: 1), .passThrough)
        XCTAssertEqual(f.click(on: 2), .activateAndConsume(2))
    }

    func testHoverGuards() {
        var f = FocusModel(active: 1)
        f.setTiles(count: 2, active: 1)
        // First event only records the position.
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 10, y: 10), over: 2, buttonsDown: false))
        XCTAssertEqual(f.pointerMoved(to: CGPoint(x: 11, y: 10), over: 2, buttonsDown: false), 2)
        // Same point again (a layout moved a tile under a still pointer): nothing.
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 11, y: 10), over: 2, buttonsDown: false))
        // Button held.
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 12, y: 10), over: 2, buttonsDown: true))
        // Exceptions block hover.
        f.begin(.rename)
        XCTAssertFalse(f.terminalOwnsKeyboard)
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 13, y: 10), over: 2, buttonsDown: false))
        XCTAssertTrue(f.end(.rename))
        XCTAssertTrue(f.terminalOwnsKeyboard)
        XCTAssertFalse(f.end(.rename))
        // Window not key.
        f.setWindowKey(false)
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 14, y: 10), over: 2, buttonsDown: false))
        f.setWindowKey(true)
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 15, y: 10), over: 2, buttonsDown: false)) // re-baseline after key
        XCTAssertEqual(f.pointerMoved(to: CGPoint(x: 16, y: 10), over: 2, buttonsDown: false), 2)
        // Setting off.
        f.followsMouse = false
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 17, y: 10), over: 2, buttonsDown: false))
    }

    func testSingleTileNeverHoverActivatesOrShowsRing() {
        var f = FocusModel(active: 1)
        f.setTiles(count: 1, active: 1)
        XCTAssertFalse(f.showsRing)
        _ = f.pointerMoved(to: .zero, over: 1, buttonsDown: false)
        XCTAssertNil(f.pointerMoved(to: CGPoint(x: 5, y: 5), over: 1, buttonsDown: false))
        f.setTiles(count: 2, active: 1)
        XCTAssertTrue(f.showsRing)
    }

    func testExceptionHandOff() {
        var f = FocusModel(active: 1)
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
        XCTAssertEqual(ThemeMap.configLines(for: p, available: ["TokyoNight"]).first, "background = #0a0a0a")
        p.name = "tokyonight"
        XCTAssertEqual(ThemeMap.configLines(for: p, available: ["TokyoNight"]), ["theme = TokyoNight"])
        XCTAssertEqual(ThemeMap.configLines(for: p, available: []).count, 21)
        XCTAssertEqual(ThemeMap.generated(p).filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    func testPercentile() {
        XCTAssertEqual(Stats.percentile([5, 1, 3, 2, 4], 50), 3)
        XCTAssertEqual(Stats.percentile([5, 1, 3, 2, 4], 99), 5)
        XCTAssertTrue(Stats.percentile([], 50).isNaN)
    }
}
