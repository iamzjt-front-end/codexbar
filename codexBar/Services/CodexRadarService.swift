import Combine
import Foundation

@MainActor
final class CodexRadarService: ObservableObject {
    static let shared = CodexRadarService()

    @Published private(set) var snapshot: CodexRadarSnapshot?
    @Published private(set) var lastFetchAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    private let statusURL = URL(string: "https://codexradar.com/current.json")!
    private let websiteURL = URL(string: "https://codexradar.com/")!
    private let refreshInterval: TimeInterval = 15 * 60
    private let staleInterval: TimeInterval = 6 * 60 * 60
    private var timer: Timer?

    private init() {}

    var homepageURL: URL { websiteURL }

    var isStale: Bool {
        guard let lastFetchAt else { return snapshot == nil && lastError != nil }
        return Date().timeIntervalSince(lastFetchAt) > staleInterval
    }

    var needsVisibleRefresh: Bool {
        guard !isRefreshing else { return false }
        guard let lastFetchAt else { return true }
        return Date().timeIntervalSince(lastFetchAt) >= refreshInterval
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
            request.cachePolicy = .reloadIgnoringLocalCacheData
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
        } catch {
            lastError = error.localizedDescription
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
    let windowOpen: Bool?
    let status: String?
    let recommendedAction: String?
    let window: CodexRadarResetWindow?
    let modelIQ: CodexRadarModelIQ?

    enum CodingKeys: String, CodingKey {
        case monitoredAt = "monitored_at"
        case windowOpen = "window_open"
        case status
        case recommendedAction = "recommended_action"
        case window
        case modelIQ = "model_iq"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitoredAt = try container.decodeIfPresent(Date.self, forKey: .monitoredAt)
        monitoredAtRaw = try container.decodeIfPresent(String.self, forKey: .monitoredAt)
        windowOpen = try container.decodeIfPresent(Bool.self, forKey: .windowOpen)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        recommendedAction = try container.decodeIfPresent(String.self, forKey: .recommendedAction)
        window = try container.decodeIfPresent(CodexRadarResetWindow.self, forKey: .window)
        modelIQ = try container.decodeIfPresent(CodexRadarModelIQ.self, forKey: .modelIQ)
    }
}

struct CodexRadarResetWindow: Decodable {
    let open: Bool?
    let status: String?
    let action: String?
    let message: String?
    let title: String?
    let scope: String?
    let openedAt: Date?
    let closedAt: Date?
    let sourceURL: URL?

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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        open = try container.decodeIfPresent(Bool.self, forKey: .open)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        openedAt = try container.decodeIfPresent(Date.self, forKey: .openedAt)
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)

        if let rawSourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) {
            sourceURL = URL(string: rawSourceURL)
        } else {
            sourceURL = nil
        }
    }

    var isOpen: Bool {
        if let open { return open }
        return status?.lowercased() == "open"
    }

    var expectedResetAt: Date? {
        if let closedAt { return closedAt }
        return openedAt?.addingTimeInterval(24 * 60 * 60)
    }
}

struct CodexRadarModelIQ: Decodable {
    let latest: CodexRadarModelIQEntry?
    let comparisons: [String: CodexRadarModelIQComparison]

    enum CodingKeys: String, CodingKey {
        case latest
        case comparisons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = try container.decodeIfPresent(CodexRadarModelIQEntry.self, forKey: .latest)
        comparisons = try container.decodeIfPresent([String: CodexRadarModelIQComparison].self, forKey: .comparisons) ?? [:]
    }
}

struct CodexRadarModelIQComparison: Decodable {
    let label: String?
    let model: String?
    let reasoningEffort: String?
    let latest: CodexRadarModelIQEntry?

    enum CodingKeys: String, CodingKey {
        case label
        case model
        case reasoningEffort = "reasoning_effort"
        case latest
    }
}

struct CodexRadarModelIQEntry: Decodable {
    let date: String?
    let score: Double?
    let status: String?
    let passed: Int?
    let tasks: Int?
    let totalTokens: Int?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let wallSeconds: Int?
    let wallTimeHuman: String?
    let model: String?
    let reasoningEffort: String?
    let validTasks: Int?
    let costUSD: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case score
        case status
        case passed
        case tasks
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case wallSeconds = "wall_seconds"
        case wallTimeHuman = "wall_time_human"
        case model
        case reasoningEffort = "reasoning_effort"
        case validTasks = "valid_tasks"
        case costUSD = "cost_usd"
    }

    var cacheHitPercent: Double? {
        guard let cachedInputTokens, let inputTokens, inputTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(inputTokens) * 100
    }
}
