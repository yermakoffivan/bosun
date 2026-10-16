import XCTest
@testable import BosunCore

/// The Light/Dark theme pair (design 7a): which palette the chrome shows, and the wire form.
final class ThemeChoiceTests: XCTestCase {
    private func palette(_ name: String, bg: String) -> ThemePalette {
        var p = ThemePalette.fallback
        p.name = name
        p.bg = bg
        return p
    }

    private func paletteJSON(_ name: String, bg: String) -> String {
        """
        {"name":"\(name)","bg":"\(bg)","panel":"#111111","panel_alt":"#222222","selection_bg":"#333333","text":"#ffffff",\
        "text_muted":"#888888","accent":"#88c0d0","shadow":"#000000","dim_fg":"#444444","status_running":"#00ff00",\
        "status_waiting":"#ffff00","status_idle":"#888888","status_error":"#ff0000","status_done":"#0000ff"}
        """
    }

    func testNoPairUsesThemeInBothAppearances() {
        let theme = palette("nord", bg: "#2e3440")
        XCTAssertEqual(ThemeChoice.palette(for: .light, theme: theme, light: nil, dark: nil), theme)
        XCTAssertEqual(ThemeChoice.palette(for: .dark, theme: theme, light: nil, dark: nil), theme)
    }

    func testPairPicksTheSideForTheAppearance() {
        let theme = palette("nord", bg: "#2e3440")
        let light = palette("github-light", bg: "#ffffff")
        let dark = palette("tokyonight", bg: "#1a1b26")
        XCTAssertEqual(ThemeChoice.palette(for: .light, theme: theme, light: light, dark: dark), light)
        XCTAssertEqual(ThemeChoice.palette(for: .dark, theme: theme, light: light, dark: dark), dark)
    }

    func testAnUnsetSideFallsBackToTheme() {
        let theme = palette("nord", bg: "#2e3440")
        let light = palette("github-light", bg: "#ffffff")
        XCTAssertEqual(ThemeChoice.palette(for: .light, theme: theme, light: light, dark: nil), light)
        XCTAssertEqual(ThemeChoice.palette(for: .dark, theme: theme, light: light, dark: nil), theme)
        let dark = palette("tokyonight", bg: "#1a1b26")
        XCTAssertEqual(ThemeChoice.palette(for: .light, theme: theme, light: nil, dark: dark), theme)
        XCTAssertEqual(ThemeChoice.palette(for: .dark, theme: theme, light: nil, dark: dark), dark)
    }

    func testPairNamesNoteAndHeader() {
        let none = ThemeChoice.Pair(light: nil, dark: nil)
        XCTAssertFalse(none.isActive)
        XCTAssertNil(none.note(theme: "nord"))
        XCTAssertEqual(none.name(for: .dark, theme: "nord"), "nord")

        let both = ThemeChoice.Pair(light: "github-light", dark: "tokyonight")
        XCTAssertTrue(both.isActive)
        XCTAssertEqual(both.note(theme: "nord"), "Following macOS appearance (Light: github-light, Dark: tokyonight)")
        XCTAssertEqual(both.name(for: .light, theme: "nord"), "github-light")
        XCTAssertEqual(both.listHeader, "Theme for the TUI")

        let darkOnly = ThemeChoice.Pair(light: nil, dark: "tokyonight")
        XCTAssertTrue(darkOnly.isActive)
        XCTAssertEqual(darkOnly.note(theme: "nord"), "Following macOS appearance (Light: nord, Dark: tokyonight)")
        XCTAssertEqual(darkOnly.name(for: .light, theme: "nord"), "nord")
        XCTAssertEqual(darkOnly.listHeader, "Theme for the TUI and Light mode")
        XCTAssertEqual(ThemeChoice.Pair(light: "one-light", dark: nil).listHeader, "Theme for the TUI and Dark mode")
    }

    func testSnapshotAndDeltaCarryThePair() throws {
        let snap = """
        {"t":"snapshot","seq":1,"server":{"version":"2.2.1","protocol":1},"theme":\(paletteJSON("nord", bg: "#2e3440")),
         "theme_light":\(paletteJSON("github-light", bg: "#ffffff")),"themes":[]}
        """
        var st = BosunState()
        XCTAssertEqual(st.apply(try ServerMessage.decode(Data(snap.utf8))), .applied([.snapshot]))
        XCTAssertEqual(st.themeLight?.name, "github-light")
        XCTAssertNil(st.themeDark)
        XCTAssertEqual(st.themePair, ThemeChoice.Pair(light: "github-light", dark: nil))
        XCTAssertEqual(st.palette(for: .light).bg, "#ffffff")
        XCTAssertEqual(st.palette(for: .dark).name, "nord")

        // A theme_pair delta replaces both sides; an absent or null side is unset.
        let delta = #"{"t":"theme_pair","seq":2,"theme_light":null,"theme_dark":"# + paletteJSON("tokyonight", bg: "#1a1b26") + "}"
        let msg = try ServerMessage.decode(Data(delta.utf8))
        guard case .themePair(2, nil, let dark?) = msg else { return XCTFail("\(msg)") }
        XCTAssertEqual(dark.name, "tokyonight")
        XCTAssertEqual(st.apply(msg), .applied([.themePair]))
        XCTAssertNil(st.themeLight)
        XCTAssertEqual(st.palette(for: .light).name, "nord")
        XCTAssertEqual(st.palette(for: .dark).name, "tokyonight")

        // The on-disk cache keeps the pair, so the first frame after a launch in Dark mode is right.
        let data = try JSONEncoder().encode(try XCTUnwrap(st.snapshot()))
        var cached = BosunState()
        cached.loadCached(try JSONDecoder().decode(Snapshot.self, from: data))
        XCTAssertEqual(cached.themeDark?.name, "tokyonight")
        XCTAssertNil(cached.themeLight)
        XCTAssertEqual(cached.palette(for: .dark).bg, "#1a1b26")

        // An older daemon sends no pair: both appearances use theme.
        let old = try ServerMessage.decode(Data(ProtocolTests.snapshotJSON.utf8))
        var o = BosunState()
        _ = o.apply(old)
        XCTAssertFalse(o.themePair.isActive)
        XCTAssertEqual(o.palette(for: .light).name, "nord")
    }

    func testApplySettingEncodesNullToUnset() throws {
        let set = try JSONSerialization.jsonObject(with: ClientMessage.cmd(id: 3, .applySetting(key: "theme_dark", value: .string("nord"))).encoded())
            as? [String: Any]
        XCTAssertEqual(set?["key"] as? String, "theme_dark")
        XCTAssertEqual(set?["value"] as? String, "nord")
        let unset = try JSONSerialization.jsonObject(with: ClientMessage.cmd(id: 4, .applySetting(key: "theme_light", value: .null)).encoded())
            as? [String: Any]
        XCTAssertTrue(unset?["value"] is NSNull, "\(String(describing: unset))")
    }
}
