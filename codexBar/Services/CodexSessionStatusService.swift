import AppKit
import Combine
import Foundation

enum CodexSessionLight: String, Codable {
    case offline
    case ready
    case running
    case needsAttention = "needs_attention"
}

struct CodexSessionStatusPayload: Decodable {
    var threadId: String?
    var state: String?
    var phase: String?
    var title: String?
    var updatedAt: String?
    var source: String?
    var detail: String?

    var light: CodexSessionLight {
        guard let state else { return .offline }
        return CodexSessionLight(rawValue: state) ?? .offline
    }
}

struct CodexSessionStatus {
    var threadId: String?
    var light: CodexSessionLight = .offline
    var phase: String?
    var title: String?
    var updatedAt: Date?
    var source: String?
    var detail: String?
    var isStale = false
}

@MainActor
final class CodexSessionStatusService: ObservableObject {
    static let shared = CodexSessionStatusService()

    @Published private(set) var status = CodexSessionStatus()

    // Codex can spend several minutes reasoning or running one long tool without
    // emitting another hook event, so a short heartbeat timeout hides real work.
    private let staleRunningInterval: TimeInterval = 30 * 60
    private let staleCompactInterval: TimeInterval = 10 * 60
    private let staleReadyInterval: TimeInterval = 600
    private let statusURL: URL
    private var timer: AnyCancellable?
    private var lastFileModifiedAt: Date?

    private init() {
        let home: URL
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: pwDir))
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        statusURL = home.appendingPathComponent(".codex/codexbar/session_status.json")
    }

    func start() {
        refresh(force: true)
        guard timer == nil else { return }
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh(force: false)
            }
    }

    var helpText: String {
        let label: String
        switch status.light {
        case .offline:
            label = L.codexSessionOffline
        case .ready:
            label = L.codexSessionReady
        case .running:
            label = status.phase.map { L.codexSessionRunning($0) } ?? L.codexSessionRunningGeneric
        case .needsAttention:
            label = status.detail ?? L.codexSessionNeedsAttention
        }

        if let title = status.title, !title.isEmpty {
            return "\(label) · \(title)"
        }
        return label
    }

    private func refresh(force: Bool) {
        guard FileManager.default.fileExists(atPath: statusURL.path) else {
            status = fallbackStatus()
            lastFileModifiedAt = nil
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: statusURL.path)
        let modifiedAt = attrs?[.modificationDate] as? Date
        if !force, modifiedAt == lastFileModifiedAt {
            updateStaleness()
            return
        }

        lastFileModifiedAt = modifiedAt
        guard let data = try? Data(contentsOf: statusURL),
              let payload = try? JSONDecoder().decode(CodexSessionStatusPayload.self, from: data) else {
            status = CodexSessionStatus(light: .offline, detail: L.codexSessionStatusUnreadable)
            return
        }

        status = CodexSessionStatus(
            threadId: payload.threadId,
            light: payload.light,
            phase: payload.phase,
            title: payload.title,
            updatedAt: Self.parseDate(payload.updatedAt) ?? modifiedAt,
            source: payload.source,
            detail: payload.detail,
            isStale: false
        )
        updateStaleness()
    }

    private func updateStaleness() {
        guard let updatedAt = status.updatedAt else { return }
        let age = Date().timeIntervalSince(updatedAt)
        let shouldExpire: Bool
        switch status.light {
        case .running:
            let interval = status.source == "SessionStart:compact" ? staleCompactInterval : staleRunningInterval
            shouldExpire = age > interval
        case .ready:
            shouldExpire = age > staleReadyInterval
        case .offline, .needsAttention:
            shouldExpire = false
        }

        guard shouldExpire else {
            if status.isStale {
                status.isStale = false
            }
            return
        }

        status.light = .offline
        status.isStale = true
        status.detail = L.codexSessionStatusStale
    }

    private func fallbackStatus() -> CodexSessionStatus {
        let codexIsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.openai.codex"
        }
        guard codexIsRunning else { return CodexSessionStatus() }
        return CodexSessionStatus(light: .ready, updatedAt: Date(), source: "CodexAppFallback")
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) {
            return date
        }

        if let seconds = TimeInterval(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
