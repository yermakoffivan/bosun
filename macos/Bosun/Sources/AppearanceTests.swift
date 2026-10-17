import AppKit
import BosunCore

// Focus-test section for the Light/Dark theme pair (design 7a): with `theme_light` and `theme_dark` set, the chrome
// (window background and titlebar, sidebar, title band, the active pane's ring) follows the app's appearance, and
// so do the terminals when "match terminal to Bosun theme" is on. The test switches `NSApp.appearance` between
// aqua and darkAqua inside the app; it never touches the system appearance. `theme` (the TUI's) never changes.

extension FocusTest {
    func appearancePair(_ f: Fixture) async {
        r.say("")
        r.say("# Light and dark themes")
        let light = "github-light", dark = "tokyonight"
        let originalAppearance = NSApp.appearance
        let originalMatch = AppSettings.shared.matchTerminalTheme
        let theme = app.daemon.state.theme.name
        guard app.daemon.state.config.settings.contains(where: { $0.key == "theme_light" }) else {
            r.check("the daemon knows theme_light and theme_dark", false, "rebuild bosun from this checkout")
            return
        }
        r.check("terminals follow the Bosun theme by default, for installs that never chose",
                TerminalSync.defaultOn
                    && UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)["matchTerminalTheme"] as? Bool == true)
        AppSettings.shared.matchTerminalTheme = false
        await showRow(f.web)

        // No pair: both appearances show `theme`.
        _ = await setPair(nil, nil)
        await setAppearance(.aqua)
        r.check("no pair, Light appearance: the chrome shows the theme (\(theme))", chromeShows(theme), chromeDetail())
        await setAppearance(.darkAqua)
        r.check("no pair, Dark appearance: the chrome still shows the theme", chromeShows(theme), chromeDetail())

        // The pair, set the way the Settings pickers set it.
        await setAppearance(.aqua)
        r.check("setting the pair through apply_setting reaches the app", await setPair(light, dark))
        r.check("Light appearance: the chrome shows theme_light (\(light))", await waitChrome(light), chromeDetail())
        r.check("…the window and titlebar are light", w.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        r.check("…a light chrome isn't the dark one", !app.theme.isDark)
        let lightHeader = headerShowsTheme()
        r.check("…the sidebar header follows it: accent tile, its ink, the accent-to-done gradient (lighter)", lightHeader.ok, lightHeader.detail)
        let lightInk = app.sidebar.view.header.anchor.strokeColor
        shot("30-appearance-light")
        await setAppearance(.darkAqua)
        r.check("switching NSApp to darkAqua: the chrome shows theme_dark (\(dark)) live", await waitChrome(dark), chromeDetail())
        r.check("…the window and titlebar are dark", w.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let darkHeader = headerShowsTheme()
        r.check("…and the header recolours live", darkHeader.ok, darkHeader.detail)
        r.check("…its anchor's ink flips with the accent's lightness (\(light) → \(dark))", lightInk != app.sidebar.view.header.anchor.strokeColor)
        shot("31-appearance-dark")
        r.check("the pair never changes theme (the TUI's)", app.daemon.state.theme.name == theme
                && app.daemon.state.config.value("theme")?.stringValue == theme)

        // View → Theme says what's going on.
        app.menuNeedsUpdate(app.themeMenu)
        let items = app.themeMenu.items
        let note = "Following macOS appearance (Light: \(light), Dark: \(dark))"
        r.check("View → Theme: a disabled note says the chrome follows the appearance", items.first?.title == note && items.first?.isEnabled == false,
                items.first?.title ?? "no items")
        r.check("…names the theme showing now", items.contains { $0.title.hasPrefix("Showing \(dark)") && !$0.isEnabled })
        r.check("…and the list still checks theme", items.filter { $0.state == .on }.map(\.title) == [theme])
        if let shots {
            let ok = MenuPicture.write(app.themeMenu, to: URL(fileURLWithPath: "\(shots)/32-theme-menu-pair.png"))
            r.say("      screenshot 32-theme-menu-pair.png \(ok ? "(drawn from the live menu items)" : "FAILED")")
        }

        // Terminals follow too when they match the Bosun theme.
        AppSettings.shared.matchTerminalTheme = true
        r.check("match terminal on, Dark: terminals take theme_dark's colours, over the user's Ghostty config",
                await waitUntil(3) { app.appliedTerminalTheme?.name == dark && terminalMatches(dark) && terminalIsDark() == true },
                terminalDetail())
        await setAppearance(.aqua)
        r.check("…switching to Light recolours them with theme_light's",
                await waitUntil(3) { app.appliedTerminalTheme?.name == light && terminalMatches(light) && terminalIsDark() == false },
                terminalDetail())
        shot("33-appearance-light-terminals")
        AppSettings.shared.matchTerminalTheme = false
        r.check("…and turning it off gives the terminals back their Ghostty theme",
                await waitUntil(3) { app.appliedTerminalTheme == nil })
        await coalescedTerminalUpdates()

        // "Same as Theme" on one side.
        r.check("dark side set to Same as Theme", await setPair(light, nil))
        r.check("…Light still shows theme_light", await waitChrome(light), chromeDetail())
        await setAppearance(.darkAqua)
        r.check("…Dark shows the theme (\(theme))", await waitChrome(theme), chromeDetail())
        app.menuNeedsUpdate(app.themeMenu)
        r.check("…and the menu says the list sets Dark mode too",
                app.themeMenu.items.contains { $0.title == "Theme for the TUI and Dark mode" })

        // The Settings group, with both set.
        _ = await setPair(light, dark)
        r.check("the Settings pickers show the pair", await waitUntil(3) {
            app.themePairModel.light == light && app.themePairModel.dark == dark && app.themePairModel.supported
        })
        await themePreview(light: light, dark: dark)
        if let shots {
            app.showSettings()
            if let sw = app.settingsWindow {
                var ok = false
                for _ in 0..<10 where !ok {
                    await sleep(200)
                    sw.contentView?.layoutSubtreeIfNeeded()
                    sw.displayIfNeeded()
                    ok = WindowSnapshot.write(sw, to: URL(fileURLWithPath: "\(shots)/34-settings-theme.png"))
                }
                r.say("      screenshot 34-settings-theme.png \(ok ? "" : "FAILED")")
                sw.close()
            }
        }

        // Back to how it was.
        r.check("unsetting both sides", await setPair(nil, nil))
        r.check("…the chrome shows the theme again", await waitChrome(theme), chromeDetail())
        NSApp.appearance = originalAppearance
        AppSettings.shared.matchTerminalTheme = originalMatch
        await waitUntil(3) { app.appearance == AppController.systemAppearance() }
        ws.focusActiveTerminal()
        await waitUntil(2) { firstResponderIsActiveTerminal }
        r.check("the keyboard is still in the active terminal", firstResponderIsActiveTerminal)
    }

    /// With terminals following the theme, a run of theme changes through every theme, dark and light mixed,
    /// recolours what the active terminal draws each time (its pixels, not just Ghostty's config).
    func terminalColoursFollowEveryTheme() async {
        let originalMatch = AppSettings.shared.matchTerminalTheme
        AppSettings.shared.matchTerminalTheme = true
        defer { AppSettings.shared.matchTerminalTheme = originalMatch; app.previewTheme(nil) }
        await showRow(session("api") ?? ws.activeSession ?? "")
        var bad: [String] = []
        for name in app.themePairModel.names {
            app.previewTheme(name)
            guard await waitUntil(2, { app.theme.palette.name == name }) else { bad.append("\(name): no palette"); continue }
            let want = ThemeMap.configLines(for: app.theme.palette, available: GhosttyRuntime.shared.availableThemes)
                .first { $0.hasPrefix("background = ") }.map { String($0.dropFirst("background = ".count)).lowercased() } ?? "?"
            var drawn = "-"
            let ok = await waitUntil(2) {
                guard let t = ws.activeTerminal, let img = WindowSnapshot.image(of: t), let px = Self.pixel(img, x: img.width - 4, y: img.height - 4) else { return false }
                drawn = px.hex
                return px.close(to: RGB(hex: want))
            }
            if !ok { bad.append("\(name): drew \(drawn), wanted \(want), config \(terminalDetail())") }
        }
        r.check("terminal colours: the active terminal draws each theme's background, through all \(app.themePairModel.names.count) themes",
                bad.isEmpty, bad.prefix(6).joined(separator: "; "))

        // Inside an open menu (a Settings popup), AppKit runs the run loop in event-tracking mode: two highlights in
        // quick succession must both reach the terminals while it's open, not only once it closes.
        let names = app.themePairModel.names.filter { $0 != app.theme.palette.name }
        guard names.count >= 2 else { return }
        func drawnMatches(_ name: String) -> Bool {
            guard app.theme.palette.name == name, let t = ws.activeTerminal, let img = WindowSnapshot.image(of: t),
                  let px = Self.pixel(img, x: img.width - 4, y: img.height - 4) else { return false }
            let want = ThemeMap.configLines(for: app.theme.palette, available: GhosttyRuntime.shared.availableThemes)
                .first { $0.hasPrefix("background = ") }.map { String($0.dropFirst("background = ".count)) }
            return px.close(to: want.flatMap { RGB(hex: $0) })
        }
        app.previewTheme(names[0])
        await waitUntil(2) { drawnMatches(names[0]) }
        app.previewTheme(names[1])
        let end = Date().addingTimeInterval(1.0)
        var reached = false
        while Date() < end, !reached {
            Self.spinEventTracking(0.02)
            reached = drawnMatches(names[1])
        }
        r.check("terminal colours: a second highlight within 80 ms recolours the terminals while a menu is open", reached, terminalDetail())
    }

    /// Run the main run loop in event-tracking mode for a moment, as AppKit does while a menu is open.
    static func spinEventTracking(_ seconds: TimeInterval) {
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(seconds))
    }

    static func pixel(_ img: CGImage, x: Int, y: Int) -> RGB? {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return RGB(r: Double(d[0]) / 255, g: Double(d[1]) / 255, b: Double(d[2]) / 255)
    }

    /// Moving through a Settings theme popup previews each theme on the chrome before anything is chosen (driven
    /// through the popup's own menu delegate, as AppKit calls it). macOS is in Dark mode here, so `dark` shows.
    private func themePreview(light: String, dark: String) async {
        app.showSettings()
        await sleep(300)
        func popUps(_ v: NSView?) -> [NSPopUpButton] {
            guard let v else { return [] }
            return (v as? NSPopUpButton).map { [$0] } ?? v.subviews.flatMap(popUps)
        }
        let found = popUps(app.settingsWindow?.contentView).filter { $0.menu?.delegate is ThemePopUp.Coordinator }
        guard found.count == 2, let target = app.themePairModel.names.first(where: { ![light, dark, app.daemon.state.theme.name].contains($0) }) else {
            r.check("preview: the Settings window has a Light and a Dark theme popup", false, "\(found.count) popups")
            app.settingsWindow?.close()
            return
        }
        let themeBefore = app.daemon.state.theme.name
        for (i, side) in ["Light", "Dark"].enumerated() {
            let popup = found[i]
            guard let menu = popup.menu, let delegate = menu.delegate,
                  let item = menu.items.first(where: { ($0.representedObject as? String) == target }) else { continue }
            delegate.menuWillOpen?(menu)
            delegate.menu?(menu, willHighlight: item)
            r.check("preview: highlighting \(target) in the \(side) popup shows it on the chrome", await waitChrome(target), chromeDetail())
            r.check("…without changing the daemon's theme or the pair", app.daemon.state.theme.name == themeBefore
                    && app.themePairModel.light == light && app.themePairModel.dark == dark)
            if side == "Light" {
                // Closed without a choice: back to the real theme.
                delegate.menuDidClose?(menu)
                r.check("…closing the popup without choosing shows \(dark) again", await waitChrome(dark), chromeDetail())
            } else {
                // Chosen: the preview stays until the daemon confirms, so the chrome never flashes back.
                delegate.menuDidClose?(menu)
                popup.select(item)
                _ = popup.target?.perform(popup.action, with: popup)
                var steady = true
                for _ in 0..<40 {
                    if !chromeShows(target) { steady = false }
                    await sleep(20)
                }
                r.check("…choosing it keeps it on screen with no flash back to \(dark)", steady && app.themePairModel.dark == target, chromeDetail())
                r.check("…and it's the Dark theme now", await waitUntil(3) { app.daemon.state.themePair.dark == target && app.previewPalette == nil })
                _ = await setPair(light, dark)
            }
        }
        app.settingsWindow?.close()
    }

    /// A burst of theme previews (the TUI sends one per keystroke) reaches Ghostty as at most two config updates:
    /// the first at once, and one more with the latest colours.
    private func coalescedTerminalUpdates() async {
        let runtime = GhosttyRuntime.shared
        guard var table = app.theme.palette.terminal else {
            r.check("the theme has a terminal table to preview", false, "rebuild bosun from this checkout")
            return
        }
        // Whatever the steps before changed has gone through, so the burst's first preview can too.
        await waitUntil(3) { runtime.configUpdatesSettled }
        let before = runtime.configUpdates
        var last = ""
        for i in 0..<12 {
            last = String(format: "#%02x1018", 16 + i * 8)
            table.background = last
            var p = app.theme.palette
            p.terminal = table
            runtime.setTerminalTheme(p)
        }
        r.check("a burst of 12 terminal previews rebuilds the config at once", runtime.configUpdates - before == 1,
                "\(runtime.configUpdates - before) updates straight away")
        await sleep(300)
        let updates = runtime.configUpdates - before
        r.check("…and once more with the last colours, nothing in between", updates == 2, "\(updates) updates")
        let c = runtime.configColor("background")?.usingColorSpace(.sRGB)
        let bg = c.map { RGB(r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent)).hex }
        r.check("…the terminals end on the last preview's background", bg == last, "\(bg ?? "-") wanted \(last)")
        runtime.setTerminalTheme(nil)
        await sleep(300)
    }

    /// Set the pair the way the Settings pickers do; true once the daemon's palettes say so.
    private func setPair(_ light: String?, _ dark: String?) async -> Bool {
        app.themePairModel.set(.light, light)
        app.themePairModel.set(.dark, dark)
        return await waitUntil(5) {
            app.daemon.state.themeLight?.name == light && app.daemon.state.themeDark?.name == dark
        }
    }

    private func setAppearance(_ name: NSAppearance.Name) async {
        NSApp.appearance = NSAppearance(named: name)
        await waitUntil(3) { app.appearance == (name == .darkAqua ? .dark : .light) }
        await sleep(150)
    }

    private func waitChrome(_ name: String) async -> Bool {
        await waitUntil(3) { chromeShows(name) }
    }

    /// The window background, sidebar, title band and the active pane's ring all use the palette of `name`.
    private func chromeShows(_ name: String) -> Bool {
        let p = app.theme.palette
        guard p.name == name else { return false }
        let c = chromeColors()
        return c.window == p.bg.lowercased() && c.sidebar == p.panel.lowercased() && c.band == p.bg.lowercased()
            && c.ring == p.accent.lowercased()
    }

    private func chromeDetail() -> String {
        let c = chromeColors()
        return "theme \(app.theme.palette.name): window \(c.window ?? "-") sidebar \(c.sidebar ?? "-") band \(c.band ?? "-") ring \(c.ring ?? "-")"
    }

    private func chromeColors() -> (window: String?, sidebar: String?, band: String?, ring: String?) {
        func hex(_ c: NSColor?) -> String? {
            guard let s = c?.usingColorSpace(.sRGB) else { return nil }
            return RGB(r: Double(s.redComponent), g: Double(s.greenComponent), b: Double(s.blueComponent)).hex.lowercased()
        }
        func hex(_ c: CGColor?) -> String? { c.flatMap { NSColor(cgColor: $0) }.flatMap(hex) }
        // The active pane's ring: the 2 px border layer drawn inside the pane. Hidden views and layers don't count:
        // the area keeps spare pane chrome hidden for the next row (recoloured when it's used), and each tile's drop
        // highlight is a hidden 2 px border too.
        var ring: CGColor?
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            for l in v.layer?.sublayers ?? [] where !l.isHidden && l.borderWidth == 2 && ring == nil { ring = l.borderColor }
            for s in v.subviews where ring == nil { walk(s) }
        }
        walk(ws.area)
        let band = (w.contentView as? RootView)?.band.layer?.backgroundColor
        return (hex(w.backgroundColor), hex(app.sidebar.view.layer?.backgroundColor), hex(band), hex(ring))
    }

    /// The terminals' background is the one "match terminal" gives the theme `name`.
    private func terminalMatches(_ name: String) -> Bool {
        guard let p = app.theme.palette.name == name ? app.theme.palette : nil,
              let want = ThemeMap.configLines(for: p, available: GhosttyRuntime.shared.availableThemes)
                .first(where: { $0.hasPrefix("background = ") })?.dropFirst("background = ".count),
              let c = GhosttyRuntime.shared.configColor("background")?.usingColorSpace(.sRGB) else { return false }
        return RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)).hex == want.lowercased()
    }

    private func terminalDetail() -> String {
        let c = GhosttyRuntime.shared.configColor("background")?.usingColorSpace(.sRGB)
        let bg = c.map { RGB(r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent)).hex } ?? "-"
        return "applied \(app.appliedTerminalTheme?.name ?? "none"), terminal background \(bg)"
    }

    /// Whether the terminals' background (from the app's Ghostty config) is dark; nil when unknown.
    private func terminalIsDark() -> Bool? {
        guard let c = GhosttyRuntime.shared.configColor("background")?.usingColorSpace(.sRGB) else { return nil }
        return RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)).isDark
    }
}
