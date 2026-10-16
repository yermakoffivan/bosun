import AppKit
import BosunCore
import UserNotifications

/// A notification as the app posts it: who it's about, and what it says.
struct AppNotification: Equatable {
    var id: String
    var session: String
    var kind: Attention.Kind
    var title: String
    var subtitle: String
    var body: String

    /// What a click hands back (`AppController.notificationClicked`).
    var userInfo: [String: String] { ["session": session, "kind": kind.rawValue] }
}

/// Posts and takes back notifications. The system one in a normal run; a recorder in the test modes,
/// so tests never post to Notification Center.
@MainActor
protocol Notifier: AnyObject {
    /// A click on a notification: its `userInfo`.
    var onOpen: (([AnyHashable: Any]) -> Void)? { get set }
    func post(_ n: AppNotification)
    func remove(_ ids: [String])
    /// The app became active: a denial may have been lifted in System Settings since.
    func recheck()
}

/// UNUserNotificationCenter. Authorization is asked for the first time something is posted, not at launch;
/// "denied" just means nothing is posted (and it's looked at again when the app next becomes active).
@MainActor
final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    var onOpen: (([AnyHashable: Any]) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private enum Auth { case unknown, checking, allowed, denied }
    private var auth = Auth.unknown
    private var queued: [AppNotification] = []

    override init() {
        super.init()
        // Set before launch finishes, so a click that launched the app is delivered too.
        center.delegate = self
    }

    func post(_ n: AppNotification) {
        switch auth {
        case .allowed: add(n)
        case .denied: return
        case .checking: queued.append(n)
        case .unknown:
            queued.append(n)
            auth = .checking
            Task { await authorize() }
        }
    }

    private func authorize() async {
        var ok: Bool
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            ok = true
        case .notDetermined:
            do {
                ok = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                log.error("notifications: authorization failed: \(error.localizedDescription, privacy: .public)")
                ok = false
            }
        default:
            ok = false
        }
        auth = ok ? .allowed : .denied
        if !ok { log.info("notifications: not allowed; nothing is posted") }
        let q = queued
        queued = []
        if ok { q.forEach(add) }
    }

    private func add(_ n: AppNotification) {
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.subtitle = n.subtitle
        c.body = n.body
        c.sound = .default
        c.threadIdentifier = n.session
        c.userInfo = n.userInfo
        // The same id replaces an earlier notification of this kind for the session.
        let req = UNNotificationRequest(identifier: n.id, content: c, trigger: nil)
        Task {
            do {
                try await center.add(req)
            } catch {
                log.error("notifications: posting failed: \(error.localizedDescription, privacy: .public)")
                auth = .denied
            }
        }
    }

    func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        queued.removeAll { ids.contains($0.id) }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func recheck() {
        if auth == .denied { auth = .unknown }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let info = response.notification.request.content.userInfo
        let session = info["session"] as? String
        let kind = info["kind"] as? String
        await MainActor.run {
            var u: [AnyHashable: Any] = [:]
            if let session { u["session"] = session }
            if let kind { u["kind"] = kind }
            onOpen?(u)
        }
    }

    /// Posted while the app is active (the session is in another row): show it anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// The test modes' notifier: records what would be posted and taken back.
@MainActor
final class RecordingNotifier: Notifier {
    var onOpen: (([AnyHashable: Any]) -> Void)?
    private(set) var posted: [AppNotification] = []
    private(set) var removed: [String] = []
    /// What is still "delivered" (posted and not taken back).
    private(set) var delivered: [String: AppNotification] = [:]

    func post(_ n: AppNotification) {
        posted.append(n)
        delivered[n.id] = n
    }

    func remove(_ ids: [String]) {
        removed += ids
        for id in ids { delivered[id] = nil }
    }

    func recheck() {}

    func reset() {
        posted = []
        removed = []
        delivered = [:]
    }

    func posts(for session: String) -> [AppNotification] { posted.filter { $0.session == session } }
}
