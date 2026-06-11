import Combine
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class CodexRadarService: ObservableObject {
    static let shared = CodexRadarService()

    @Published private(set) var snapshot: CodexRadarSnapshot?
    @Published private(set) var lastFetchAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    private let statusURL = URL(string: "https://codexradar.com/current.json")!
    private let websiteURL = URL(string: "https://codexradar.com/")!
    private let refreshInterval: TimeInterval = 180
    private let staleInterval: TimeInterval = 30 * 60
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    private enum DefaultsKey {
        static let lastWindowNotification = "codexRadar.lastWindowNotification"
        static let lastPredictionLevel = "codexRadar.lastPredictionLevel"
    }

    private init() {}

    var homepageURL: URL { websiteURL }

    var isStale: Bool {
        guard let lastFetchAt else { return snapshot == nil && lastError != nil }
        return Date().timeIntervalSince(lastFetchAt) > staleInterval
    }

    func start(runImmediately: Bool = true) {
        guard timer == nil else { return }
        if runImmediately {
            Task { await refresh() }
        }
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: statusURL)
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw CodexRadarError.invalidResponse
            }

            let decoded = try Self.decoder.decode(CodexRadarSnapshot.self, from: data)
            snapshot = decoded
            lastFetchAt = Date()
            lastError = nil
            notifyIfNeeded(decoded)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func notifyIfNeeded(_ snapshot: CodexRadarSnapshot) {
        if snapshot.windowOpen {
            let notificationKey = snapshot.window.openedAtRaw
                ?? snapshot.window.title
                ?? snapshot.monitoredAtRaw
                ?? "open"
            if defaults.string(forKey: DefaultsKey.lastWindowNotification) != notificationKey {
                defaults.set(notificationKey, forKey: DefaultsKey.lastWindowNotification)
                sendNotification(
                    title: L.zh ? "Codex 速蹬窗口开启" : "Codex reset window open",
                    body: snapshot.window.message ?? snapshot.window.title ?? snapshot.window.scope ?? "CodexRadar"
                )
            }
        }

        let level = snapshot.prediction?.level?.lowercased() ?? "none"
        let previousLevel = defaults.string(forKey: DefaultsKey.lastPredictionLevel)
        if level == "high", previousLevel != "high" {
            sendNotification(
                title: L.zh ? "Codex 重置概率升高" : "Codex reset probability high",
                body: snapshot.prediction?.probabilitySummary ?? (L.zh ? "预测已升至高概率" : "Prediction moved to high")
            )
        }
        defaults.set(level, forKey: DefaultsKey.lastPredictionLevel)
    }

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "codexradar-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = DateFormatters.iso8601WithFractionalSeconds.date(from: value)
                ?? DateFormatters.iso8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid CodexRadar date: \(value)"
            )
        }
        return decoder
    }()
}

private enum CodexRadarError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        L.zh ? "CodexRadar 响应无效" : "Invalid CodexRadar response"
    }
}

private enum DateFormatters {
    static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct CodexRadarSnapshot: Decodable {
    let monitoredAt: Date?
    let monitoredAtRaw: String?
    let windowOpen: Bool
    let status: String?
    let recommendedAction: String?
    let window: CodexRadarWindow
    let prediction: CodexRadarPrediction?
    let modelIQ: CodexRadarModelIQ?

    enum CodingKeys: String, CodingKey {
        case monitoredAt = "monitored_at"
        case windowOpen = "window_open"
        case status
        case recommendedAction = "recommended_action"
        case window
        case prediction
        case modelIQ = "model_iq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitoredAt = try container.decodeIfPresent(Date.self, forKey: .monitoredAt)
        monitoredAtRaw = try container.decodeIfPresent(String.self, forKey: .monitoredAt)
        windowOpen = try container.decodeIfPresent(Bool.self, forKey: .windowOpen) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status)
        recommendedAction = try container.decodeIfPresent(String.self, forKey: .recommendedAction)
        window = try container.decodeIfPresent(CodexRadarWindow.self, forKey: .window) ?? CodexRadarWindow()
        prediction = try container.decodeIfPresent(CodexRadarPrediction.self, forKey: .prediction)
        modelIQ = try container.decodeIfPresent(CodexRadarModelIQ.self, forKey: .modelIQ)
    }
}

struct CodexRadarWindow: Decodable {
    var open: Bool = false
    var status: String?
    var action: String?
    var message: String?
    var title: String?
    var scope: String?
    var openedAt: Date?
    var openedAtRaw: String?
    var closedAt: Date?
    var sourceURL: URL?

    enum CodingKeys: String, CodingKey {
        case open
        case status
        case action
        case message
        case title
        case scope
        case openedAt = "opened_at"
        case closedAt = "closed_at"
        case sourceURL = "source_url"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        open = try container.decodeIfPresent(Bool.self, forKey: .open) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        openedAt = try container.decodeIfPresent(Date.self, forKey: .openedAt)
        openedAtRaw = try container.decodeIfPresent(String.self, forKey: .openedAt)
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
    }
}

struct CodexRadarPrediction: Decodable {
    let level: String?
    let probability24h: Double?
    let probability48h: Double?
    let expectedWindow: String?
    let summary: String?
    let summaryEN: String?
    let updatedAt: Date?

    var probabilitySummary: String {
        let p24 = Int((probability24h ?? 0) * 100)
        let p48 = Int((probability48h ?? 0) * 100)
        return "24h \(p24)% · 48h \(p48)%"
    }

    enum CodingKeys: String, CodingKey {
        case level
        case probability24h = "probability_24h"
        case probability48h = "probability_48h"
        case expectedWindow = "expected_window"
        case summary
        case summaryEN = "summary_en"
        case updatedAt = "updated_at"
    }
}

struct CodexRadarModelIQ: Decodable {
    let latest: CodexRadarModelIQEntry?

    enum CodingKeys: String, CodingKey {
        case latest
    }
}

struct CodexRadarModelIQEntry: Decodable {
    let date: String?
    let score: Double?
    let status: String?
    let passed: Int?
    let tasks: Int?
    let model: String?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case date
        case score
        case status
        case passed
        case tasks
        case model
        case reasoningEffort = "reasoning_effort"
    }
}
