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

            var decoded = try Self.decoder.decode(CodexRadarSnapshot.self, from: data)
            var fallbackError: Error?
            if decoded.modelIQ?.latest == nil {
                do {
                    decoded.modelIQ = try await fetchModelIQFromHomepage(referenceDate: decoded.monitoredAt ?? Date())
                } catch {
                    fallbackError = error
                }
            }

            snapshot = decoded
            lastFetchAt = Date()
            lastError = decoded.modelIQ?.latest == nil ? fallbackError?.localizedDescription : nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fetchModelIQFromHomepage(referenceDate: Date) async throws -> CodexRadarModelIQ {
        var request = URLRequest(url: websiteURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        request.setValue("CodexAppBar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw CodexRadarError.invalidResponse
        }

        return try CodexRadarHTMLParser.parseModelIQ(from: html, referenceDate: referenceDate)
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
    case modelQualityUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L.zh ? "CodexRadar 响应无效" : "Invalid CodexRadar response"
        case .modelQualityUnavailable:
            return L.zh ? "CodexRadar 模型质量页面无可解析数据" : "CodexRadar model quality is unavailable"
        }
    }
}

enum CodexRadarHTMLParser {
    static func parseModelIQ(from html: String, referenceDate: Date = Date()) throws -> CodexRadarModelIQ {
        let chips = parseScoreChips(from: html)
        guard let primary = chips.first(where: \.isPrimary) ?? chips.first else {
            throw CodexRadarError.modelQualityUnavailable
        }

        let metrics = parseMetricRows(from: html)
        let date = parseDisplayDate(from: html, referenceDate: referenceDate)
        var entries: [String: CodexRadarModelIQEntry] = [:]
        for chip in chips {
            entries[chip.key] = entry(for: chip, metrics: metrics, date: date)
        }
        guard let latest = entries[primary.key] else {
            throw CodexRadarError.modelQualityUnavailable
        }

        var comparisons: [String: CodexRadarModelIQComparison] = [:]
        for chip in chips where chip.key != primary.key {
            guard let latest = entries[chip.key] else { continue }
            let parts = modelParts(from: chip.label)
            comparisons[chip.key] = CodexRadarModelIQComparison(
                label: chip.label,
                model: parts.model,
                reasoningEffort: parts.effort,
                latest: latest
            )
        }

        return CodexRadarModelIQ(latest: latest, comparisons: comparisons)
    }

    private static func parseScoreChips(from html: String) -> [ScoreChip] {
        matches(
            in: html,
            pattern: #"<div\s+class="([^"]*\bmodel-iq-score-chip\b[^"]*)"[^>]*\bdata-model-key="([^"]+)"[^>]*>\s*<span[^>]*>(.*?)</span>\s*<strong[^>]*>(.*?)</strong>"#
        ).compactMap { match in
            guard match.count >= 5 else { return nil }
            let classes = match[1]
            let key = decodedHTMLText(match[2])
            let label = decodedHTMLText(match[3])
            let score = Double(decodedHTMLText(match[4]).replacingOccurrences(of: ",", with: ""))
            guard !key.isEmpty, !label.isEmpty, let score else { return nil }
            return ScoreChip(
                key: key,
                label: label,
                score: score,
                isPrimary: classes.contains("model-iq-score-chip-primary")
            )
        }
    }

    private static func parseMetricRows(from html: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        let rowMatches = matches(
            in: html,
            pattern: #"<div\s+class="[^"]*\bmodel-iq-compare-row\b[^"]*"[^>]*>(.*?)</div>"#
        )

        for rowMatch in rowMatches {
            guard let row = rowMatch.last,
                  let rawMetric = firstMatch(in: row, pattern: #"<span[^>]*>(.*?)</span>"#) else {
                continue
            }

            let metric = decodedHTMLText(rawMetric)
            var values: [String: String] = [:]
            for valueMatch in matches(
                in: row,
                pattern: #"<strong\s+class="[^"]*\bmodel-iq-column-([A-Za-z0-9_-]+)\b[^"]*"[^>]*>(.*?)</strong>"#
            ) {
                guard valueMatch.count >= 3 else { continue }
                values[decodedHTMLText(valueMatch[1])] = decodedHTMLText(valueMatch[2])
            }

            if !metric.isEmpty, !values.isEmpty {
                result[metric] = values
            }
        }

        return result
    }

    private static func entry(
        for chip: ScoreChip,
        metrics: [String: [String: String]],
        date: String?
    ) -> CodexRadarModelIQEntry {
        let passParts = passCount(from: metrics["通过数"]?[chip.key])
        let parts = modelParts(from: chip.label)

        return CodexRadarModelIQEntry(
            date: date,
            score: chip.score,
            status: status(for: chip.score),
            passed: passParts.passed,
            tasks: passParts.tasks,
            totalTokens: tokenCount(from: metrics["总tokens"]?[chip.key]),
            wallSeconds: seconds(from: metrics["耗时"]?[chip.key]),
            wallTimeHuman: metrics["耗时"]?[chip.key],
            model: parts.model,
            reasoningEffort: parts.effort,
            validTasks: passParts.tasks,
            costUSD: cost(from: metrics["费用"]?[chip.key])
        )
    }

    private static func passCount(from value: String?) -> (passed: Int?, tasks: Int?) {
        guard let value else { return (nil, nil) }
        let parts = value.split(separator: "/", maxSplits: 1).map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 2 else { return (nil, nil) }
        return (parts[0], parts[1])
    }

    private static func tokenCount(from value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let multiplier: Double
        let numeric: String
        if trimmed.uppercased().hasSuffix("M") {
            multiplier = 1_000_000
            numeric = String(trimmed.dropLast())
        } else if trimmed.uppercased().hasSuffix("K") {
            multiplier = 1_000
            numeric = String(trimmed.dropLast())
        } else {
            multiplier = 1
            numeric = trimmed
        }
        guard let number = Double(numeric.replacingOccurrences(of: ",", with: "")) else { return nil }
        return Int((number * multiplier).rounded())
    }

    private static func seconds(from value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix("h"),
           let hours = Double(trimmed.dropLast()) {
            return Int((hours * 60 * 60).rounded())
        }
        if trimmed.lowercased().hasSuffix("m"),
           let minutes = Double(trimmed.dropLast()) {
            return Int((minutes * 60).rounded())
        }
        return nil
    }

    private static func cost(from value: String?) -> Double? {
        guard let value else { return nil }
        return Double(
            value
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func status(for score: Double) -> String {
        if score >= 90 { return "green" }
        if score >= 80 { return "yellow" }
        return "red"
    }

    private static func modelParts(from label: String) -> (model: String?, effort: String?) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for effort in ["xhigh", "high", "medium", "low", "max"] {
            if lower.hasSuffix("-\(effort)") {
                return (String(trimmed.dropLast(effort.count + 1)), effort)
            }
            if lower.hasSuffix(" \(effort)") {
                return (String(trimmed.dropLast(effort.count + 1)), effort)
            }
        }
        return (trimmed, nil)
    }

    private static func parseDisplayDate(from html: String, referenceDate: Date) -> String? {
        guard let raw = firstMatch(in: html, pattern: #"降智雷达\s*<span[^>]*>([^<]+)</span>"#),
              let monthText = firstMatch(in: raw, pattern: #"(\d{1,2})月\d{1,2}日"#),
              let dayText = firstMatch(in: raw, pattern: #"\d{1,2}月(\d{1,2})日"#),
              let month = Int(monthText),
              let day = Int(dayText) else {
            return nil
        }

        let calendar = Calendar(identifier: .gregorian)
        let referenceYear = calendar.component(.year, from: referenceDate)
        let candidates = [referenceYear, referenceYear - 1, referenceYear + 1].compactMap { year -> Date? in
            DateComponents(calendar: calendar, year: year, month: month, day: day).date
        }
        guard let date = candidates.min(by: {
            abs($0.timeIntervalSince(referenceDate)) < abs($1.timeIntervalSince(referenceDate))
        }) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func firstMatch(in string: String, pattern: String) -> String? {
        matches(in: string, pattern: pattern).first?.dropFirst().first
    }

    private static func matches(in string: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: string) else { return "" }
                return String(string[range])
            }
        }
    }

    private static func decodedHTMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ScoreChip {
        let key: String
        let label: String
        let score: Double
        let isPrimary: Bool
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
    var modelIQ: CodexRadarModelIQ?

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

    init(latest: CodexRadarModelIQEntry?, comparisons: [String: CodexRadarModelIQComparison]) {
        self.latest = latest
        self.comparisons = comparisons
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

    init(label: String?, model: String?, reasoningEffort: String?, latest: CodexRadarModelIQEntry?) {
        self.label = label
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.latest = latest
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

    init(
        date: String? = nil,
        score: Double? = nil,
        status: String? = nil,
        passed: Int? = nil,
        tasks: Int? = nil,
        totalTokens: Int? = nil,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        wallSeconds: Int? = nil,
        wallTimeHuman: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        validTasks: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.date = date
        self.score = score
        self.status = status
        self.passed = passed
        self.tasks = tasks
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.wallSeconds = wallSeconds
        self.wallTimeHuman = wallTimeHuman
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.validTasks = validTasks
        self.costUSD = costUSD
    }

    var cacheHitPercent: Double? {
        guard let cachedInputTokens, let inputTokens, inputTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(inputTokens) * 100
    }
}
