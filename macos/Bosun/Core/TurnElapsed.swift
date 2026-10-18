import Foundation

/// How long an agent's turn has been running, for the sidebar and the pane header. Minutes only, so the
/// label changes once a minute: "<1m", "4m", "1h", "1h 5m".
public enum TurnElapsed {
    public static func label(startedAt: UInt64, now: UInt64) -> String {
        let mins = now > startedAt ? (now - startedAt) / 60_000 : 0
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        let (h, m) = (mins / 60, mins % 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    public static func nowMs(_ date: Date = Date()) -> UInt64 { UInt64(date.timeIntervalSince1970 * 1000) }
}
