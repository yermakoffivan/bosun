import AppKit
import BosunCore

// Focus-test section for several windows: New Window, one window per row (selecting a row another
// window shows brings that window forward), the sidebar's mark for those rows, stepping past them,
// a row dragged out of the sidebar and a pane dragged out of its window (each opening in a new
// window with the same terminal views), the saved windows, a torn-off pane's row merged back, and
// closing windows with their views kept warm.

extension FocusTest {
    /// The sidebar cell's text on the right for a row, in `bw`'s sidebar.
    func trailing(_ bw: BosunWindow, row id: String) -> String? {
        let o = bw.sidebar.outline
        for i in 0..<o.numberOfRows {
            guard let it = o.item(atRow: i) as? SidebarItem, it.kind == .row(id) else { continue }
            return (o.view(atColumn: 0, row: i, makeIfNecessary: true) as? SidebarCellView)?.trailingText
        }
        return nil
    }

    func views(of sessions: [String]) -> [String: ObjectIdentifier] {
        var out: [String: ObjectIdentifier] = [:]
        for s in sessions { if let v = ws.pool.view(for: s) { out[s] = ObjectIdentifier(v) } }
        return out
    }

    func windows(_ f: Fixture) async {
        guard let apiRow = rowID(f.api), let webRow = rowID(f.web) else { return }
        let first = app.windows[0]
        await showRow(f.api)
        r.check("windows: one window to start with", app.windows.count == 1)

        // New Window (Cmd+N): the first row no window shows, with the keyboard.
        await cmd("n")
        await waitUntil(3) { app.windows.count == 2 }
        guard app.windows.count == 2 else { r.check("windows: Cmd+N opens a second window", false); return }
        let second = app.windows[1]
        await waitUntil(3) { ws.activeTerminal?.hasPaintedContent == true }
        r.check("windows: Cmd+N opens a second window, the one menus and keys now act on", app.current === second && second.window.isVisible)
        let secondRow = second.workspace.currentRow
        r.check("…showing a row the first window doesn't (\(secondRow.flatMap { app.daemon.state.sidebar.container(id: $0) }.map(app.rowLabel) ?? "none"))",
                secondRow != nil && secondRow != apiRow && first.workspace.currentRow == apiRow)
        if let s = second.workspace.activeSession {
            r.check("…with the keyboard in its terminal", firstResponderIsActiveTerminal && w === second.window)
            r.check("…typing reaches it", await keysLandIn(s, "win2"))
        }
        r.check("…its sidebar marks api's row as shown in another window", trailing(second, row: apiRow)?.hasPrefix("⧉") == true,
                trailing(second, row: apiRow) ?? "no cell")
        r.check("…and the first window's sidebar marks the second's row", secondRow.flatMap { trailing(first, row: $0)?.hasPrefix("⧉") } == true)

        // One window per row: selecting api's row in the second window brings the first forward.
        let secondViews = views(of: second.workspace.layout.panes)
        second.workspace.selectRow(apiRow)
        await sleep(150)
        r.check("windows: selecting a row another window shows brings that window forward", app.current === first && first.workspace.currentRow == apiRow)
        r.check("…and the second window keeps its row", second.workspace.currentRow == secondRow && views(of: second.workspace.layout.panes) == secondViews)
        r.check("…with the keyboard in the first window's terminal", firstResponderIsActiveTerminal && w === first.window && ws.activeSession == f.api)
        let canSee = { [app] (s: String) in app.userCanSee(s) }
        let realSeen = app.windowSeen
        app.windowSeen = { _ in true }
        r.check("windows: notifications count a pane on screen in either window as seen",
                second.workspace.activeSession.map(canSee) == true && canSee(f.api))
        app.windowSeen = realSeen

        // Stepping rows in the first window skips the one the second shows.
        var stepped: [String] = []
        for _ in 0..<app.daemon.state.sidebar.allRows.count {
            await arrow(125, [.shift])
            stepped.append(ws.currentRow ?? "-")
        }
        r.check("windows: Shift+Down never lands on the other window's row", !stepped.contains { $0 == secondRow } && app.current === first,
                stepped.compactMap { app.daemon.state.sidebar.container(id: $0) }.map(app.rowLabel).joined(separator: " → "))

        // Close Window: the row goes back to the sidebar, its terminal views stay warm.
        app.bringForward(second)
        let closedPanes = second.workspace.layout.panes
        await cmd("w", [.shift])
        await waitUntil(3) { app.windows.count == 1 }
        r.check("windows: Close Window (Cmd+Shift+W) closes the second window", app.windows.count == 1 && app.current === first)
        r.check("…its terminals stay attached, hidden in the first window", closedPanes.allSatisfy { s in
            ws.pool.view(for: s).map { !$0.exited && $0.isHidden && $0.superview === first.workspace.area } ?? false })
        r.check("…and no sidebar marks a row any more", trailing(first, row: secondRow ?? "")?.hasPrefix("⧉") != true)

        // A row dragged out of the sidebar opens in a new window; the first window moves on.
        await showRow(f.web)
        await waitUntil(3) { ws.layout.count == 3 }
        let webPanes = ws.layout.panes
        let webViews = views(of: webPanes)
        let outside = NSPoint(x: w.frame.maxX + 240, y: w.frame.midY)
        if let from = rowPoint(rowItem(f.web), 0.5) {
            let o = app.sidebar.outline
            var captured: NSDraggingSession?
            o.dragCapture = { s, _, _ in captured = s }
            post(.leftMouseDown, from)
            for i in 1...6 { post(.leftMouseDragged, NSPoint(x: from.x + CGFloat(i), y: from.y + CGFloat(i) * 2)) }
            await waitUntil(2) { captured != nil }
            o.dragCapture = nil
            if let session = captured {
                o.draggingSession(session, endedAt: outside, operation: [])
            } else {
                post(.leftMouseUp, from)
            }
            await waitUntil(3) { app.windows.count == 2 }
            await sleep(200)
        }
        let torn = app.windows.count == 2 ? app.windows[1] : nil
        r.check("windows: a row dragged out of the sidebar opens in a new window", torn?.workspace.currentRow == webRow && app.current === torn,
                "\(app.windows.count) windows")
        if let torn {
            r.check("…with its three panes, the same terminal views (no reattach)", torn.workspace.layout.panes.count == 3 && views(of: webPanes) == webViews
                    && webPanes.allSatisfy { ws.pool.view(for: $0)?.superview === torn.workspace.area && ws.pool.view(for: $0)?.isHidden == false })
            r.check("…placed where it was let go", torn.window.frame.minX > first.window.frame.minX + 100, "\(torn.window.frame)")
            r.check("…and the first window shows another row", first.workspace.currentRow != nil && first.workspace.currentRow != webRow)
            r.check("…the keyboard is in the new window's active pane", firstResponderIsActiveTerminal && w === torn.window)
            shot("40-torn-off-row")
        }

        // A pane dragged out of its window by its header: a row of its own, in a new window.
        if let torn, let from = headerPoint(f.webTests) {
            let tornView = ws.pool.view(for: f.webTests)
            let away = NSPoint(x: w.frame.width + 300, y: from.y - 40)
            var previewShown = false
            var indicator: CGRect? = .zero
            await drag(from: from, to: away) { [self] in
                previewShown = ws.tearOffPreviewShown
                indicator = ws.dropIndicator.shownRect
            }
            r.check("windows: dragging a pane outside the window shows the new-window card and no drop indicator", previewShown && indicator == nil)
            await waitUntil(5) { app.windows.count == 3 }
            await sleep(200)
            let paneWin = app.windows.count == 3 ? app.windows[2] : nil
            let ownRow = rowID(f.webTests)
            r.check("…letting go there moves the tab out into a row of its own (in the daemon's sidebar)",
                    ownRow != nil && ownRow != webRow && !tabs(webRow).contains(f.webTests), "tabs \(tabs(webRow).map(app.displayName))")
            r.check("…shown in a third window, the same terminal view", paneWin?.workspace.currentRow == ownRow && ws.pool.view(for: f.webTests) === tornView
                    && tornView?.superview === paneWin?.workspace.area && app.current === paneWin)
            r.check("…the web window keeps its other two panes", torn.workspace.layout.panes.count == 2 && !torn.workspace.layout.contains(f.webTests))
            r.check("…the card is gone", !torn.workspace.tearOffPreviewShown)
            r.check("…typing reaches the torn-off pane", await keysLandIn(f.webTests, "torn"))

            // Saved: the other windows and their rows.
            app.saveLayouts()
            let file = Paths.supportDir.appendingPathComponent("rows-\(Paths.key(for: app.daemon.socketPath)).json")
            let saved = (try? Data(contentsOf: file)).flatMap(SavedLayouts.decode)
            r.check("windows: the layouts file keeps the other windows, each on its row", saved?.current == first.workspace.currentRow
                    && saved?.windows?.map(\.row) == [webRow, ownRow ?? "-"], "\(saved?.windows?.map(\.row) ?? [])")

            // Back into the web row (where it was): the third window has no row of its own left and
            // moves on to a free one; the web window gets the pane back, still the same view.
            _ = await app.daemon.request(.moveTab(session: f.webTests, container: webRow, index: 1))
            await waitUntil(4) { torn.workspace.layout.count == 3 }
            await sleep(200)
            r.check("windows: a torn-off tab moved back into its row is a pane of that row's window again, the same view",
                    torn.workspace.layout.contains(f.webTests) && ws.pool.view(for: f.webTests) === tornView && tornView?.superview === torn.workspace.area
                    && tornView?.isHidden == false)
            r.check("…and the third window shows another row no window shows", paneWin.map { pw in
                pw.workspace.currentRow.map { $0 != webRow && $0 != first.workspace.currentRow } ?? !app.windows.contains { $0 === pw } } ?? false)
        }

        // Close the extra windows (the red button, not a key): their views stay warm.
        for bw in app.windows.dropFirst().reversed() {
            bw.window.performClose(nil)
            await sleep(150)
        }
        await waitUntil(3) { app.windows.count == 1 }
        r.check("windows: closing the other windows leaves the first, with the keyboard", app.windows.count == 1 && app.current === first)
        await showRow(f.web)
        r.check("…and the web row shows its three panes there again, in tab order", ws.layout.count == 3 && tabs(webRow) == [f.web, f.webTests, f.webShell],
                "\(tabs(webRow).map(app.displayName))")
        app.saveLayouts()
    }
}
