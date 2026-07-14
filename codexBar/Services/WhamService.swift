import Foundation

@MainActor
final class WhamService {
    static let shared = WhamService()

    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let resetCreditsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    private let httpClient: HTTPDataClient
    private let now: () -> Date
    private var flights: [FlightKey: Task<Void, Never>] = [:]

    private struct FlightKey: Hashable {
        let accountKey: AccountKey
        let revision: CredentialRevision
    }

    convenience init() {
        self.init(httpClient: URLSessionHTTPDataClient())
    }

    init(httpClient: HTTPDataClient, now: @escaping () -> Date = Date.init) {
        self.httpClient = httpClient
        self.now = now
    }

    /// 查询单个账号的 wham usage
    func fetchUsage(snapshot: CredentialSnapshot) async throws -> WhamUsageResult {
        var request = URLRequest(url: URL(string: usageURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(snapshot.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(snapshot.chatgptAccountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "Referer")

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WhamError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw WhamError.unauthorized
        case 402: throw WhamError.deactivatedWorkspace
        case 403: throw WhamError.forbidden
        default: throw WhamError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhamError.parseError
        }
        return try parseUsage(json)
    }

    /// 查询官方 banked reset 次数和到期时间
    func fetchResetCredits(snapshot: CredentialSnapshot) async throws -> WhamResetCreditsResult {
        var request = URLRequest(url: URL(string: resetCreditsURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(snapshot.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue(snapshot.chatgptAccountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "Referer")

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WhamError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw WhamError.unauthorized
        case 402: throw WhamError.deactivatedWorkspace
        case 403: throw WhamError.forbidden
        default: throw WhamError.httpError(http.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw WhamError.parseError
        }

        if let json = object as? [String: Any] {
            return parseResetCredits(json)
        }
        if let array = object as? [[String: Any]] {
            return Self.resetCreditsResult(from: array)
        }

        throw WhamError.parseError
    }

    /// 查询账号所属组织名称
    func fetchOrgName(snapshot: CredentialSnapshot) async -> String? {
        let urlStr = "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27?timezone_offset_min=-480"
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(snapshot.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(snapshot.chatgptAccountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await httpClient.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [String: Any],
              let entry = accounts[snapshot.chatgptAccountId] as? [String: Any],
              let acct = entry["account"] as? [String: Any],
              let name = acct["name"] as? String else { return nil }
        return name
    }

    /// 刷新单个账号的用量、组织名和重置机会
    func refreshOne(key: AccountKey, store: TokenStore) async {
        guard let snapshot = store.snapshot(for: key) else { return }
        let flightKey = FlightKey(accountKey: key, revision: snapshot.revision)
        if let existing = flights[flightKey] {
            await existing.value
            return
        }

        let staleKeys = flights.keys.filter {
            $0.accountKey == key && $0.revision != snapshot.revision
        }
        for staleKey in staleKeys {
            flights.removeValue(forKey: staleKey)?.cancel()
        }

        let task = Task { [self] in
            await performRefresh(snapshot: snapshot, store: store)
        }
        flights[flightKey] = task
        await task.value
        flights[flightKey] = nil
    }

    private func performRefresh(snapshot: CredentialSnapshot, store: TokenStore) async {
        do {
            async let usageResult = self.fetchUsage(snapshot: snapshot)
            async let orgName = self.fetchOrgName(snapshot: snapshot)
            async let resetCredits = self.fetchResetCreditsIfAvailable(snapshot: snapshot)
            let (result, name, credits) = try await (usageResult, orgName, resetCredits)
            let merged = result.merging(resetCredits: credits)
            let patch = AccountUsagePatch(
                planType: merged.planType,
                weeklyUsedPercent: merged.weeklyUsedPercent,
                weeklyResetAt: merged.weeklyResetAt,
                resetCreditsAvailableCount: merged.rateLimitResetCreditsAvailableCount,
                resetCreditsExpiresAt: merged.rateLimitResetCreditsExpiresAt,
                organizationName: name,
                checkedAt: now()
            )
            _ = store.applyUsagePatch(patch, to: snapshot.key, ifCurrent: snapshot.revision)
        } catch WhamError.deactivatedWorkspace {
            // 402 is a workspace-level state. Preserve the last known account/quota state.
        } catch WhamError.forbidden {
            _ = store.markSuspended(snapshot.key, ifCurrent: snapshot.revision)
        } catch WhamError.unauthorized {
            _ = store.markTokenExpired(snapshot.key, ifCurrent: snapshot.revision)
        } catch {
            // 静默失败，保留上次数据
        }
    }

    /// 批量刷新 store 中所有账号的用量、组织名和重置机会
    func refreshAll(store: TokenStore) async {
        await withTaskGroup(of: Void.self) { group in
            for key in store.accountKeys() {
                group.addTask {
                    await self.refreshOne(key: key, store: store)
                }
            }
        }
    }

    // MARK: - Private

    private func fetchResetCreditsIfAvailable(snapshot: CredentialSnapshot) async -> WhamResetCreditsResult? {
        try? await fetchResetCredits(snapshot: snapshot)
    }

    func parseUsage(_ json: [String: Any]) throws -> WhamUsageResult {
        let planType = json["plan_type"] as? String ?? "free"
        var rateLimitResetCreditsAvailableCount: Int?
        var rateLimitResetCreditsExpiresAt: Date?

        guard let rateLimit = json["rate_limit"] as? [String: Any],
              let weeklyWindow = try Self.weeklyWindow(from: rateLimit) else {
            throw WhamError.parseError
        }

        if let resetCredits = json["rate_limit_reset_credits"] as? [String: Any] {
            rateLimitResetCreditsAvailableCount = Self.intValue(resetCredits["available_count"])
            rateLimitResetCreditsExpiresAt = Self.resetCreditsExpirationDate(from: resetCredits)
        }

        return WhamUsageResult(
            planType: planType,
            weeklyUsedPercent: weeklyWindow.usedPercent,
            weeklyResetAt: weeklyWindow.resetAt,
            rateLimitResetCreditsAvailableCount: rateLimitResetCreditsAvailableCount,
            rateLimitResetCreditsExpiresAt: rateLimitResetCreditsExpiresAt
        )
    }

    private static func weeklyWindow(from rateLimit: [String: Any]) throws -> RateLimitWindow? {
        let primary = try rateLimitWindow(from: rateLimit["primary_window"])
        let secondary = try rateLimitWindow(from: rateLimit["secondary_window"])
        let candidates = [primary, secondary].compactMap { $0 }

        if let exactWeekly = candidates.first(where: { $0.limitWindowSeconds == RateLimitWindow.weeklySeconds }) {
            return exactWeekly
        }

        // 兼容旧响应未携带 limit_window_seconds 的情况：旧双窗口的 secondary 是周额度；
        // 单窗口响应则只能使用唯一窗口。只要服务端提供了其他明确时长，就拒绝猜测。
        guard candidates.allSatisfy({ $0.limitWindowSeconds == nil }) else {
            return nil
        }
        return secondary ?? (candidates.count == 1 ? primary : nil)
    }

    private static func rateLimitWindow(from value: Any?) throws -> RateLimitWindow? {
        guard let json = value as? [String: Any] else { return nil }
        guard let usedPercent = doubleValue(json["used_percent"]), usedPercent.isFinite else {
            throw WhamError.parseError
        }
        let resetAt = dateValue(json["reset_at"])
        let limitWindowSeconds = intValue(json["limit_window_seconds"])
        return RateLimitWindow(
            usedPercent: min(max(usedPercent, 0), 100),
            resetAt: resetAt,
            limitWindowSeconds: limitWindowSeconds
        )
    }

    private func parseResetCredits(_ json: [String: Any]) -> WhamResetCreditsResult {
        let topLevel = Self.resetCreditsResult(from: json)
        if topLevel.availableCount != nil, topLevel.expiresAt != nil {
            return topLevel
        }

        let objectKeys = [
            "rate_limit_reset_credits",
            "reset_credits",
            "credits",
            "data"
        ]
        for key in objectKeys {
            if let nested = json[key] as? [String: Any] {
                return topLevel.merging(Self.resetCreditsResult(from: nested))
            }
        }

        let arrayKeys = [
            "rate_limit_reset_credits",
            "reset_credits",
            "credits",
            "items",
            "data"
        ]
        for key in arrayKeys {
            if let array = json[key] as? [[String: Any]] {
                return topLevel.merging(Self.resetCreditsResult(from: array))
            }
        }

        return Self.resetCreditsResult(from: json)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func resetCreditsExpirationDate(from resetCredits: [String: Any]) -> Date? {
        let absoluteKeys = [
            "expires_at",
            "expire_at",
            "expiration_at",
            "expiresAt",
            "expirationAt",
            "valid_until",
            "valid_through",
            "validUntil",
            "validThrough",
            "expires",
            "expiry",
            "expiry_at",
            "expired_at"
        ]
        for key in absoluteKeys {
            if let date = dateValue(resetCredits[key]) {
                return date
            }
        }

        let relativeKeys = [
            "expires_after_seconds",
            "expire_after_seconds",
            "seconds_until_expiration",
            "expiresAfterSeconds",
            "expireAfterSeconds",
            "secondsUntilExpiration",
            "ttl_seconds",
            "ttlSeconds"
        ]
        for key in relativeKeys {
            if let seconds = doubleValue(resetCredits[key]), seconds > 0 {
                return Date(timeIntervalSinceNow: seconds)
            }
        }

        return nil
    }

    private static func resetCreditsResult(from resetCredits: [String: Any]) -> WhamResetCreditsResult {
        let countKeys = [
            "available_count",
            "availableCount",
            "available",
            "remaining_count",
            "remainingCount",
            "count",
            "total",
            "credits"
        ]
        let availableCount = countKeys.compactMap { intValue(resetCredits[$0]) }.first
        return WhamResetCreditsResult(
            availableCount: availableCount,
            expiresAt: resetCreditsExpirationDate(from: resetCredits)
        )
    }

    private static func resetCreditsResult(from resetCredits: [[String: Any]]) -> WhamResetCreditsResult {
        let now = Date()
        let availableCredits = resetCredits.filter { credit in
            if let used = boolValue(credit["used"]), used { return false }
            if let redeemed = boolValue(credit["redeemed"]), redeemed { return false }
            if let status = credit["status"] as? String, status.lowercased() != "available" { return false }
            if let expiresAt = resetCreditsExpirationDate(from: credit), expiresAt <= now { return false }
            return true
        }
        let source = availableCredits.isEmpty ? resetCredits : availableCredits
        let expiresAt = source
            .compactMap { resetCreditsExpirationDate(from: $0) }
            .filter { $0 > now }
            .min()

        return WhamResetCreditsResult(
            availableCount: availableCredits.count,
            expiresAt: expiresAt
        )
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let timeInterval = doubleValue(value) {
            let seconds = timeInterval > 10_000_000_000 ? timeInterval / 1000 : timeInterval
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String {
            if let numeric = Double(string) {
                let seconds = numeric > 10_000_000_000 ? numeric / 1000 : numeric
                return Date(timeIntervalSince1970: seconds)
            }
            for formatter in iso8601DateFormatters {
                if let date = formatter.date(from: string) {
                    return date
                }
            }
        }
        return nil
    }

    private static var iso8601DateFormatters: [ISO8601DateFormatter] {
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return [standard, fractional]
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

struct WhamUsageResult {
    let planType: String
    let weeklyUsedPercent: Double
    let weeklyResetAt: Date?
    let rateLimitResetCreditsAvailableCount: Int?
    let rateLimitResetCreditsExpiresAt: Date?

    func merging(resetCredits: WhamResetCreditsResult?) -> WhamUsageResult {
        guard let resetCredits else { return self }
        return WhamUsageResult(
            planType: planType,
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyResetAt: weeklyResetAt,
            rateLimitResetCreditsAvailableCount: resetCredits.availableCount ?? rateLimitResetCreditsAvailableCount,
            rateLimitResetCreditsExpiresAt: resetCredits.expiresAt ?? rateLimitResetCreditsExpiresAt
        )
    }
}

private struct RateLimitWindow {
    static let weeklySeconds = 7 * 24 * 60 * 60

    let usedPercent: Double
    let resetAt: Date?
    let limitWindowSeconds: Int?
}

struct WhamResetCreditsResult {
    let availableCount: Int?
    let expiresAt: Date?

    func merging(_ other: WhamResetCreditsResult) -> WhamResetCreditsResult {
        WhamResetCreditsResult(
            availableCount: availableCount ?? other.availableCount,
            expiresAt: expiresAt ?? other.expiresAt
        )
    }
}

enum WhamError: LocalizedError, Equatable {
    case invalidResponse, unauthorized, deactivatedWorkspace, forbidden, parseError
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无效响应"
        case .unauthorized: return "Token 已过期"
        case .deactivatedWorkspace: return "工作区已停用"
        case .forbidden: return "账号被封禁"
        case .parseError: return "解析失败"
        case .httpError(let code): return "HTTP \(code)"
        }
    }
}
