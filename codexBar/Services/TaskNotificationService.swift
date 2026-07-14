import CryptoKit
import Combine
import Foundation
import UserNotifications

protocol TaskNotificationClient: AnyObject {
    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void)
    func requestAuthorization(completion: @escaping (Bool) -> Void)
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
    func setResponseHandler(_ handler: @escaping (String?) -> Void)
}

final class SystemTaskNotificationClient: NSObject, TaskNotificationClient, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var responseHandler: ((String?) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    func authorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        center.add(request, withCompletionHandler: completion)
    }

    func setResponseHandler(_ handler: @escaping (String?) -> Void) {
        responseHandler = handler
        center.delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.identifier.hasPrefix(Self.identifierPrefix) else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.notification.request.identifier.hasPrefix(Self.identifierPrefix) else {
            completionHandler()
            return
        }
        responseHandler?(response.notification.request.content.userInfo[Self.taskKeyUserInfoKey] as? String)
        completionHandler()
    }

    static let identifierPrefix = "codexbar-task-attention-"
    static let taskKeyUserInfoKey = "taskKey"
}

@MainActor
final class TaskNotificationService: ObservableObject {
    static let shared = TaskNotificationService()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var onOpenTaskCenter: ((String?) -> Void)?

    private static let enabledDefaultsKey = "codexbar.taskAttentionNotificationsEnabled"
    private static let notifiedEventKeysDefaultsKey = "codexbar.taskAttentionNotifiedEventKeys"
    private static let maximumRememberedEvents = 512

    private let notificationClient: TaskNotificationClient
    private let defaults: UserDefaults
    private var notifiedEventKeys: [String]
    private var notifiedEventKeySet: Set<String>
    private var latestSnapshot: TaskCenterSnapshot?

    convenience init() {
        self.init(notificationClient: SystemTaskNotificationClient(), defaults: .standard)
    }

    init(notificationClient: TaskNotificationClient, defaults: UserDefaults) {
        self.notificationClient = notificationClient
        self.defaults = defaults
        let savedKeys = defaults.stringArray(forKey: Self.notifiedEventKeysDefaultsKey) ?? []
        notifiedEventKeys = savedKeys
        notifiedEventKeySet = Set(savedKeys)
        // A persisted opt-in is not enough: wait until the current system
        // authorization status is known before sending anything.
        isEnabled = false

        notificationClient.setResponseHandler { [weak self] taskKey in
            Task { @MainActor in
                self?.onOpenTaskCenter?(taskKey)
            }
        }
    }

    func refreshAuthorizationStatus() {
        notificationClient.authorizationStatus { [weak self] status in
            Task { @MainActor in
                self?.applyAuthorizationStatus(status)
            }
        }
    }

    @discardableResult
    func enable() async -> Bool {
        defaults.set(true, forKey: Self.enabledDefaultsKey)
        let granted = await withCheckedContinuation { continuation in
            notificationClient.requestAuthorization { granted in
                continuation.resume(returning: granted)
            }
        }
        let status = await currentAuthorizationStatus()
        applyAuthorizationStatus(status)
        return granted && Self.isAuthorized(status)
    }

    func disable() {
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        isEnabled = false
    }

    func process(snapshot: TaskCenterSnapshot) {
        latestSnapshot = snapshot
        guard isEnabled else { return }

        for record in snapshot.needsAttentionRecords {
            let dedupeKey = Self.digest(record.eventKey)
            guard !notifiedEventKeySet.contains(dedupeKey) else { continue }

            // Persist before handing the request to the notification center.
            // This provides at-most-once scheduling even if the app exits
            // between system acceptance and the completion callback.
            remember(dedupeKey)
            let request = notificationRequest(for: record, dedupeKey: dedupeKey)
            notificationClient.add(request) { _ in }
        }
    }

    private func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            notificationClient.authorizationStatus { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func applyAuthorizationStatus(_ status: UNAuthorizationStatus) {
        let wasEnabled = isEnabled
        authorizationStatus = status
        isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey) && Self.isAuthorized(status)
        if !wasEnabled, isEnabled, let latestSnapshot {
            process(snapshot: latestSnapshot)
        }
    }

    private func notificationRequest(for record: TaskActivityRecord, dedupeKey: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = L.taskAttentionNotificationTitle
        content.body = L.taskAttentionNotificationBody
        content.sound = .default
        content.userInfo = [SystemTaskNotificationClient.taskKeyUserInfoKey: record.taskKey]
        return UNNotificationRequest(
            identifier: SystemTaskNotificationClient.identifierPrefix + dedupeKey,
            content: content,
            trigger: nil
        )
    }

    private func remember(_ key: String) {
        guard notifiedEventKeySet.insert(key).inserted else { return }
        notifiedEventKeys.append(key)
        if notifiedEventKeys.count > Self.maximumRememberedEvents {
            let overflow = notifiedEventKeys.count - Self.maximumRememberedEvents
            let removed = notifiedEventKeys.prefix(overflow)
            notifiedEventKeys.removeFirst(overflow)
            for key in removed {
                notifiedEventKeySet.remove(key)
            }
        }
        defaults.set(notifiedEventKeys, forKey: Self.notifiedEventKeysDefaultsKey)
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
