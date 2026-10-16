import XCTest
@testable import BosunCore

final class AttentionTests: XCTestCase {
    private let idle = StatusInfo(state: .idle, source: "hook")
    private let running = StatusInfo(state: .running, source: "hook")
    private func waiting(_ detail: String? = "permission: Bash") -> StatusInfo { StatusInfo(state: .waiting, source: "hook", detail: detail) }
    private func done(_ at: UInt64) -> StatusInfo { StatusInfo(state: .idle, source: "hook", doneAt: at) }

    private func posts(_ acts: [Attention.Action]) -> [Attention.Note] {
        acts.compactMap { if case .post(let n) = $0 { return n }; return nil }
    }

    private func removed(_ acts: [Attention.Action]) -> [String] {
        acts.flatMap { a -> [String] in if case .remove(let ids) = a { return ids }; return [] }
    }

    // MARK: When to notify

    func testWaitingNotifiesWithItsDetailWhenNotVisible() {
        var a = Attention()
        XCTAssertEqual(a.observe("s", status: running, done: false, visible: false), [])
        let acts = a.observe("s", status: waiting(), done: false, visible: false)
        XCTAssertEqual(posts(acts), [Attention.Note(session: "s", kind: .waiting, detail: "permission: Bash")])
        XCTAssertEqual(posts(acts).first?.id, "waiting:s")
        XCTAssertEqual(a.outstanding, ["s"])
    }

    func testVisibleSessionNeverNotifiesAndTheWaitStaysHandled() {
        var a = Attention()
        XCTAssertEqual(a.observe("s", status: waiting(), done: false, visible: true), [])
        // The same wait after you look away: still nothing.
        XCTAssertEqual(a.observe("s", status: waiting("permission: Edit"), done: false, visible: false), [])
        // A done turn you can see: nothing, and nothing later for the same done_at.
        XCTAssertEqual(a.observe("s", status: done(1_000), done: true, visible: true), [])
        XCTAssertEqual(a.observe("s", status: done(1_000), done: true, visible: false), [])
        XCTAssertTrue(a.delivered.isEmpty)
    }

    func testDoneNotifiesForANewDoneAtOnly() {
        var a = Attention()
        let acts = a.observe("s", status: done(1_000), done: true, visible: false)
        XCTAssertEqual(posts(acts), [Attention.Note(session: "s", kind: .done)])
        // The same done_at again (a resend, a pane title change): no repeat.
        XCTAssertEqual(posts(a.observe("s", status: done(1_000), done: true, visible: false)), [])
        // An older one (a late status) neither.
        XCTAssertEqual(posts(a.observe("s", status: done(900), done: true, visible: false)), [])
        // The next turn finishing does.
        _ = a.observe("s", status: running, done: false, visible: false)
        XCTAssertEqual(posts(a.observe("s", status: done(2_000), done: true, visible: false)).map(\.kind), [.done])
    }

    func testDoneThatDoesntShowAsDoneDoesntNotify() {
        // You typed into the session after the turn finished (SeenTracker says not done).
        var a = Attention()
        XCTAssertEqual(posts(a.observe("s", status: done(1_000), done: false, visible: false)), [])
        // A detector status never carries a done turn.
        XCTAssertEqual(posts(a.observe("d", status: StatusInfo(state: .idle, source: "detector", doneAt: 5), done: true, visible: false)), [])
    }

    func testSettingsTurnEachKindOff() {
        var a = Attention()
        let off = Attention.Enabled(waiting: false, done: true)
        XCTAssertEqual(posts(a.observe("s", status: waiting(), done: false, visible: false, enabled: off)), [])
        XCTAssertEqual(posts(a.observe("s", status: done(1_000), done: true, visible: false, enabled: off)).map(\.kind), [.done])
        var b = Attention()
        let noDone = Attention.Enabled(waiting: true, done: false)
        XCTAssertEqual(posts(b.observe("s", status: done(1_000), done: true, visible: false, enabled: noDone)), [])
        XCTAssertEqual(posts(b.observe("s", status: waiting(), done: false, visible: false, enabled: noDone)).map(\.kind), [.waiting])
    }

    func testBaselineNeverNotifiesForWhatWasAlreadyThere() {
        var a = Attention()
        a.baseline("w", status: waiting())
        a.baseline("d", status: done(1_000))
        XCTAssertTrue(a.isKnown("w"))
        XCTAssertEqual(a.observe("w", status: waiting(), done: false, visible: false), [])
        XCTAssertEqual(a.observe("d", status: done(1_000), done: true, visible: false), [])
        // What changes afterwards does.
        _ = a.observe("w", status: running, done: false, visible: false)
        XCTAssertEqual(posts(a.observe("w", status: waiting("question"), done: false, visible: false)).map(\.detail), ["question"])
        XCTAssertEqual(posts(a.observe("d", status: done(2_000), done: true, visible: false)).map(\.kind), [.done])
    }

    func testANewSessionsFirstStatusCounts() {
        // A session created after the app connected has no baseline: its first wait notifies.
        var a = Attention()
        XCTAssertEqual(posts(a.observe("new", status: waiting(), done: false, visible: false)).map(\.kind), [.waiting])
    }

    // MARK: Dedup and taking notifications back

    func testOneNotificationPerWaitingStretch() {
        var a = Attention()
        XCTAssertEqual(posts(a.observe("s", status: waiting(), done: false, visible: false)).count, 1)
        // Claude's PermissionRequest and its permission_prompt Notification: the same wait.
        XCTAssertEqual(a.observe("s", status: waiting(), done: false, visible: false), [])
        XCTAssertEqual(a.observe("s", status: waiting("permission"), done: false, visible: false), [])
        // The wait ends: its notification goes.
        XCTAssertEqual(removed(a.observe("s", status: running, done: false, visible: false)), ["waiting:s"])
        XCTAssertTrue(a.delivered.isEmpty)
        // The next wait is a new one.
        XCTAssertEqual(posts(a.observe("s", status: waiting(), done: false, visible: false)).count, 1)
    }

    func testDoneNotificationGoesWhenTheStateMovesOnOrItsRead() {
        var a = Attention()
        _ = a.observe("s", status: done(1_000), done: true, visible: false)
        XCTAssertEqual(removed(a.observe("s", status: running, done: false, visible: false)), ["done:s"])

        _ = a.observe("s", status: done(2_000), done: true, visible: false)
        // A wait after a done turn takes the done notification back and posts the wait.
        let acts = a.observe("s", status: waiting(), done: false, visible: false)
        XCTAssertEqual(removed(acts), ["done:s"])
        XCTAssertEqual(posts(acts).map(\.kind), [.waiting])

        // Typed into: done is read.
        var b = Attention()
        _ = b.observe("t", status: done(1_000), done: true, visible: false)
        XCTAssertEqual(removed(b.doneRead("t")), ["done:t"])
        XCTAssertEqual(b.doneRead("t"), [])
        // The same status re-observed once it no longer shows done also takes it back (and never reposts).
        _ = b.observe("u", status: done(1_000), done: true, visible: false)
        XCTAssertEqual(removed(b.observe("u", status: done(1_000), done: false, visible: false)), ["done:u"])
        XCTAssertEqual(posts(b.observe("u", status: done(1_000), done: true, visible: false)), [])
    }

    func testSeenTakesBothBackAndForgetDropsTheSession() {
        var a = Attention()
        _ = a.observe("s", status: waiting(), done: false, visible: false)
        _ = a.observe("t", status: done(1_000), done: true, visible: false)
        XCTAssertEqual(a.outstanding, ["s", "t"])
        XCTAssertEqual(removed(a.seen("s")), ["waiting:s"])
        // Seen doesn't end the wait: no second notification for it.
        XCTAssertEqual(a.observe("s", status: waiting(), done: false, visible: false), [])
        XCTAssertEqual(a.seen("s"), [])
        XCTAssertEqual(removed(a.forget("t")), ["done:t"])
        XCTAssertFalse(a.isKnown("t"))
        XCTAssertTrue(a.delivered.isEmpty)
    }

    func testSessionsAreIndependent() {
        var a = Attention()
        XCTAssertEqual(posts(a.observe("a", status: waiting(), done: false, visible: false)).map(\.session), ["a"])
        XCTAssertEqual(posts(a.observe("b", status: waiting(), done: false, visible: false)).map(\.session), ["b"])
        XCTAssertEqual(removed(a.observe("a", status: running, done: false, visible: false)), ["waiting:a"])
        XCTAssertEqual(a.outstanding, ["b"])
    }

    // MARK: Badge

    func testBadgeCountsLiveWaitingSessionsOnly() {
        let statuses: [String: StatusInfo] = [
            "a": waiting(), "b": waiting("question"), "c": done(1_000), "d": running, "gone": waiting(),
            "det": StatusInfo(state: .waiting, source: "detector"),
        ]
        let n = Attention.badgeCount(statuses: statuses) { $0 != "gone" }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(Attention.badgeLabel(n), "3")
        XCTAssertNil(Attention.badgeLabel(0))
        XCTAssertEqual(Attention.badgeCount(statuses: [:]) { _ in true }, 0)
    }
}

final class SavedInputsTests: XCTestCase {
    func testRoundTripAndRestoreKeepsTheNewerTime() throws {
        let data = try XCTUnwrap(SavedInputs(["a": 1_500, "b": 20]).encoded())
        let back = try XCTUnwrap(SavedInputs.decode(data))
        XCTAssertEqual(back.inputs, ["a": 1_500, "b": 20])
        XCTAssertNil(SavedInputs.decode(Data("{\"version\":2,\"inputs\":{}}".utf8)))
        XCTAssertNil(SavedInputs.decode(Data("nope".utf8)))

        // A relaunch: the saved input from after the turn keeps a finished session from showing done again.
        var t = SeenTracker()
        t.restoreInputs(back.inputs)
        t.observe("a", status: StatusInfo(state: .idle, source: "hook", doneAt: 1_000), title: nil)
        XCTAssertEqual(t.display("a", state: .idle), .idle)
        // A turn that finished after it still shows done.
        t.observe("b", status: StatusInfo(state: .idle, source: "hook", doneAt: 1_000), title: nil)
        XCTAssertEqual(t.display("b", state: .idle), .done)
        // Input noted this run beats an older saved time.
        t.noteInput("b", at: 2_000)
        t.restoreInputs(["b": 30])
        XCTAssertEqual(t.inputTimes["b"], 2_000)
        // Sessions that went away are dropped.
        t.pruneInputs(keeping: ["b"])
        XCTAssertEqual(t.inputTimes, ["b": 2_000])
    }
}
