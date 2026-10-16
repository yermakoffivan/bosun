import XCTest
@testable import BosunCore

final class ProtocolTests: XCTestCase {
    private func decode(_ json: String) throws -> ServerMessage {
        try ServerMessage.decode(Data(json.utf8))
    }

    static let snapshotJSON = """
    {"t":"snapshot","seq":1,
     "server":{"version":"2.2.0","protocol":1,"tmux_socket":"bosun"},
     "sessions":[{"name":"bosun-api-1a2b3c4d","display":"api","agent":"claude","path":"/w/api",
                  "windows":1,"attached":true,"created":1792130862,
                  "container_id":"con-1","worktree_path":"/w/api/.worktrees/feat","branch":"feat",
                  "pane_title":"✳ Fix the flaky test","pane_command":"2_1_220"}],
     "statuses":{"bosun-api-1a2b3c4d":{"state":"waiting","source":"hook","detail":"permission: Bash"},
                 "bosun-docs-5e6f7a8b":{"state":"idle","source":"detector"}},
     "sidebar":{"ungrouped":[
        {"id":"con-1","name":"api","active":"bosun-api-1a2b3c4d",
         "tabs":[{"session":"bosun-api-1a2b3c4d","display":"api","alive":true},
                 {"session":"bosun-api-2-9f8e7d6c","display":"api 2","alive":false}]}],
       "sections":[{"id":"sec-1","name":"Work","collapsed":false,"banner_font":"metalix","members":[]}]},
     "recents":[{"id":42,"name":"api","path":"/w/api","agent":"claude","args":"","options":{"claude":{"session_mode":"continue","skip_permissions":false,"remote_control":false}},"last_used_at":1792130862123,"use_count":7}],
     "config":{"settings":[
        {"key":"theme","value":"opencode","choices":["opencode","tokyonight"],"read_only":false},
        {"key":"default_agent","value":"claude","choices":["claude","codex","kimi","opencode","qwen","terminal"],"pinned_by":"BOSUN_DEFAULT_AGENT","read_only":true},
        {"key":"remove_dead_sessions","value":false,"read_only":false},
        {"key":"tmux_socket","value":"bosun","read_only":true}]},
     "theme":{"name":"nord","bg":"#2e3440","panel":"#3b4252","panel_alt":"#434c5e","selection_bg":"#4c566a",
       "text":"#d8dee9","text_muted":"#6d7a90","accent":"#88c0d0","shadow":"#1a1f28","dim_fg":"#4c566a",
       "status_running":"#a3be8c","status_waiting":"#ebcb8b","status_idle":"#6d7a90","status_error":"#bf616a","status_done":"#8fbcbb"},
     "themes":[{"name":"opencode","source":"bundled"},{"name":"my-theme","source":"user"}],
     "some_future_field":{"x":1}}
    """

    func testSnapshotDecodes() throws {
        guard case .snapshot(let s) = try decode(Self.snapshotJSON) else { return XCTFail("not a snapshot") }
        XCTAssertEqual(s.seq, 1)
        XCTAssertEqual(s.server.tmuxSocket, "bosun")
        XCTAssertEqual(s.server.protocolMajor, 1)
        XCTAssertEqual(s.sessions.first?.containerID, "con-1")
        XCTAssertEqual(s.sessions.first?.paneCommand, "2_1_220")
        XCTAssertEqual(s.statuses["bosun-api-1a2b3c4d"]?.state, .waiting)
        XCTAssertEqual(s.statuses["bosun-api-1a2b3c4d"]?.detail, "permission: Bash")
        XCTAssertEqual(s.statuses["bosun-docs-5e6f7a8b"]?.source, "detector")
        XCTAssertEqual(s.sidebar.ungrouped.first?.tabs.count, 2)
        XCTAssertEqual(s.sidebar.ungrouped.first?.tabs[1].alive, false)
        XCTAssertEqual(s.sidebar.sections.first?.bannerFont, "metalix")
        XCTAssertEqual(s.recents.first?.options.claude.sessionMode, .continue)
        XCTAssertEqual(s.recents.first?.options.codex.sessionMode, .new)
        XCTAssertEqual(s.config.settings[1].pinnedBy, "BOSUN_DEFAULT_AGENT")
        XCTAssertEqual(s.config.value("remove_dead_sessions"), .bool(false))
        XCTAssertEqual(s.theme.panelAlt, "#434c5e")
        XCTAssertEqual(s.themes.last?.source, "user")
        XCTAssertNil(s.keybindings)
    }

    func testDeltasDecode() throws {
        XCTAssertEqual(try decode(#"{"t":"status","seq":2,"session":"bosun-api-1a2b3c4d","state":"running","source":"hook"}"#),
                       .status(seq: 2, session: "bosun-api-1a2b3c4d", info: StatusInfo(state: .running, source: "hook")))
        XCTAssertEqual(try decode(#"{"t":"status","seq":4,"session":"s","state":"waiting","source":"hook","detail":"permission: Bash"}"#),
                       .status(seq: 4, session: "s", info: StatusInfo(state: .waiting, source: "hook", detail: "permission: Bash")))
        XCTAssertEqual(try decode(#"{"t":"sessions","seq":3,"removed":["bosun-old-0f0f0f0f"]}"#),
                       .sessions(seq: 3, upsert: [], removed: ["bosun-old-0f0f0f0f"]))
        XCTAssertEqual(try decode(#"{"t":"notice","seq":10,"message":"created bosun-api-1a2b3c4d"}"#),
                       .notice(seq: 10, "created bosun-api-1a2b3c4d"))
        XCTAssertEqual(try decode(#"{"t":"client_session","seq":11,"tty":"/dev/ttys026","session":"bosun-api-1a2b3c4d"}"#),
                       .client(seq: 11, tty: "/dev/ttys026", session: "bosun-api-1a2b3c4d"))
        XCTAssertEqual(try decode(#"{"t":"client_detached","seq":12,"tty":"/dev/ttys026"}"#),
                       .client(seq: 12, tty: "/dev/ttys026", session: nil))
        if case .themes(let q, let t) = try decode(#"{"t":"themes","seq":9,"themes":[{"name":"nord","source":"bundled"}]}"#) {
            XCTAssertEqual(q, 9)
            XCTAssertEqual(t.first?.name, "nord")
        } else { XCTFail() }
        if case .sidebar(let q, let sb) = try decode(#"{"t":"sidebar","seq":5,"sidebar":{"ungrouped":[],"sections":[{"id":"sec-1","name":"Work","members":[]}]}}"#) {
            XCTAssertEqual(q, 5)
            XCTAssertEqual(sb.sections.first?.collapsed, false)
        } else { XCTFail() }
        // A future state word decodes as unknown rather than failing.
        if case .status(_, _, let info) = try decode(#"{"t":"status","seq":6,"session":"s","state":"thinking","source":"hook"}"#) {
            XCTAssertEqual(info.state, .unknown)
        } else { XCTFail() }
    }

    func testAckAndError() throws {
        let ack = try decode(#"{"t":"ack","id":1,"ok":true,"session":"bosun-api-1a2b3c4d","pending_launch":{"session":"bosun-api-1a2b3c4d","resume":null},"messages":["created bosun-api-1a2b3c4d"]}"#)
        guard case .ack(let a) = ack else { return XCTFail() }
        XCTAssertTrue(a.ok)
        XCTAssertEqual(a.pendingLaunch?.session, "bosun-api-1a2b3c4d")
        XCTAssertNil(a.pendingLaunch?.resume)
        XCTAssertNil(ack.seq)
        guard case .ack(let bad) = try decode(#"{"t":"ack","id":7,"ok":false,"error":"worktree has uncommitted changes; not removed"}"#) else { return XCTFail() }
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.messages, [])
        XCTAssertEqual(try decode(#"{"t":"error","code":"protocol_mismatch","message":"update bosun"}"#),
                       .error(code: "protocol_mismatch", message: "update bosun"))
    }

    func testUnknownKindKeepsSeq() throws {
        XCTAssertEqual(try decode(#"{"t":"wobble","seq":12,"x":1}"#), .unknown(kind: "wobble", seq: 12))
    }

    func testKeybindingsFieldAndDelta() throws {
        let json = #"{"t":"keybindings","seq":3,"keybindings":{"previous_tab":"Shift+Left","next_tab":null,"previous_session":"Alt+Up","send_next_key":"Ctrl+v"}}"#
        guard case .keybindings(let q, let k) = try decode(json) else { return XCTFail() }
        XCTAssertEqual(q, 3)
        XCTAssertEqual(k.previousTab, .chord("Shift+Left"))
        XCTAssertEqual(k.nextTab, .disabled)
        XCTAssertEqual(k.previousSession, .chord("Alt+Up"))
        XCTAssertEqual(k.nextSession, .unset)
        let nav = NavBindings(k)
        XCTAssertNil(nav.chords[.nextTab])
        XCTAssertEqual(nav.chords[.nextSession], KeyChord(key: .down, mods: [.shift]))
        XCTAssertEqual(nav.chords[.previousSession], KeyChord(key: .up, mods: [.option]))
    }

    func testCommandEncoding() throws {
        func json(_ m: ClientMessage) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: try m.encoded()) as! [String: Any]
        }
        let hello = try json(.hello(client: "bosun-mac/0.2"))
        XCTAssertEqual(hello["t"] as? String, "hello")
        XCTAssertEqual(hello["protocol"] as? Int, 1)

        let restart = try json(.cmd(id: 7, .restart(session: "s", resume: true, deferLaunch: false)))
        XCTAssertEqual(restart["t"] as? String, "cmd")
        XCTAssertEqual(restart["op"] as? String, "restart")
        XCTAssertEqual(restart["id"] as? Int, 7)
        XCTAssertEqual(restart["resume"] as? Bool, true)

        let launch = try json(.cmd(id: 8, .launchAgent(session: "s", resume: nil)))
        XCTAssertTrue(launch["resume"] is NSNull)

        var spec = Spec(name: "api", path: "~/work/api", agent: "claude", args: "--model opus")
        spec.options.claude.sessionMode = .continue
        let create = try json(.cmd(id: 1, .create(spec: spec, deferLaunch: true)))
        XCTAssertEqual(create["defer_launch"] as? Bool, true)
        let s = create["spec"] as! [String: Any]
        XCTAssertEqual(s["agent"] as? String, "claude")
        XCTAssertEqual(((s["options"] as! [String: Any])["claude"] as! [String: Any])["session_mode"] as? String, "continue")

        let sb = Sidebar(ungrouped: [Container(id: "con-1", name: "api", active: "a", tabs: [Tab(session: "a", display: "api", alive: true)])],
                         sections: [Section(id: "sec-1", name: "Work")])
        let save = try json(.cmd(id: 11, .sidebarSave(sb)))
        let tabs = ((save["sidebar"] as! [String: Any])["ungrouped"] as! [[String: Any]])[0]["tabs"] as! [[String: Any]]
        XCTAssertEqual(tabs[0].keys.sorted(), ["session"])

        let flags = try json(.cmd(id: 16, .clientFlags(tty: "/dev/ttys026", ignoreSize: true)))
        XCTAssertEqual(flags["op"] as? String, "client_flags")
        XCTAssertEqual(flags["ignore_size"] as? Bool, true)
    }

    func testFrameRoundTrip() throws {
        var r = FrameReader()
        let a = Frame.encode(Data(#"{"t":"hello"}"#.utf8))
        let b = Frame.encode(Data(#"{"t":"resync"}"#.utf8))
        let all = a + b
        // Feed one byte at a time: frames must come out whole and in order.
        var out: [String] = []
        for byte in all {
            r.append(Data([byte]))
            while let f = try r.next() { out.append(String(decoding: f, as: UTF8.self)) }
        }
        XCTAssertEqual(out, [#"{"t":"hello"}"#, #"{"t":"resync"}"#])
        XCTAssertEqual(Array(a.prefix(4)), [0, 0, 0, 13])

        var big = FrameReader()
        big.append(Data([0x02, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try big.next())
    }

    func testStateAppliesDeltasAndDetectsGaps() throws {
        var st = BosunState()
        XCTAssertEqual(st.apply(try decode(Self.snapshotJSON)), .applied([.snapshot]))
        XCTAssertTrue(st.live)
        _ = st.apply(try decode(#"{"t":"status","seq":2,"session":"bosun-api-1a2b3c4d","state":"running","source":"hook"}"#))
        XCTAssertEqual(st.state(of: "bosun-api-1a2b3c4d"), .running)
        let up = #"{"t":"sessions","seq":3,"upsert":[{"name":"bosun-new-1","display":"new","windows":1,"attached":false}],"removed":["bosun-api-1a2b3c4d"]}"#
        XCTAssertEqual(st.apply(try decode(up)), .applied([.sessions(changed: ["bosun-new-1"], removed: ["bosun-api-1a2b3c4d"])]))
        XCTAssertNil(st.statuses["bosun-api-1a2b3c4d"])
        XCTAssertEqual(st.sessionOrder, ["bosun-new-1"])
        // seq 5 after 3: a gap.
        XCTAssertEqual(st.apply(try decode(#"{"t":"notice","seq":5,"message":"x"}"#)), .gap(expected: 4, got: 5))
        // An unknown kind still advances seq.
        XCTAssertEqual(st.apply(try decode(#"{"t":"wobble","seq":4}"#)), .applied([]))
        XCTAssertEqual(st.apply(try decode(#"{"t":"client_session","seq":5,"tty":"/dev/ttys026","session":"bosun-new-1"}"#)),
                       .applied([.client(tty: "/dev/ttys026", session: "bosun-new-1")]))
        XCTAssertEqual(st.apply(try decode(#"{"t":"client_detached","seq":6,"tty":"/dev/ttys026"}"#)),
                       .applied([.client(tty: "/dev/ttys026", session: nil)]))
        XCTAssertEqual(st.apply(try decode(##"{"t":"theme","seq":7,"theme":{"name":"nord","bg":"#000000","panel":"#111111","panel_alt":"#222222","selection_bg":"#333333","text":"#ffffff","text_muted":"#888888","accent":"#88c0d0","shadow":"#000000","dim_fg":"#444444","status_running":"#00ff00","status_waiting":"#ffff00","status_idle":"#888888","status_error":"#ff0000","status_done":"#0000ff"}}"##)), .applied([.theme]))
        XCTAssertEqual(st.theme.bg, "#000000")
        // The cache round-trips, and a cached snapshot is never live.
        let snap = try XCTUnwrap(st.snapshot())
        let data = try JSONEncoder().encode(snap)
        var cached = BosunState()
        cached.loadCached(try JSONDecoder().decode(Snapshot.self, from: data))
        XCTAssertFalse(cached.live)
        XCTAssertEqual(cached.sessionOrder, ["bosun-new-1"])
        XCTAssertEqual(cached.apply(try decode(#"{"t":"notice","seq":1,"message":"x"}"#)), .gap(expected: 0, got: 1))
    }
}
