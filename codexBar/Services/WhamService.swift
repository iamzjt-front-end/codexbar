import Foundation

class WhamService {
    static let shared = WhamService()
    private init() {}

    private let baseURL = "https://chatgpt.com/backend-api/wham/usage"

    /// 查询单个账号的 wham usage
    func fetchUsage(account: TokenAccount) async throws -> WhamUsageResult {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.chatgptAccountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WhamError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw WhamError.unauthorized
        case 402: throw WhamError.forbidden  // deactivated_workspace
        case 403: throw WhamError.forbidden
        default: throw WhamError.httpError(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhamError.parseError
        }
        return parseUsage(json)
    }

    /// 查询账号所属组织名称
    func fetchOrgName(account: TokenAccount) async -> String? {
        let urlStr = "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27?timezone_offset_min=-480"
        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(account.chatgptAccountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [String: Any],
              let entry = accounts[account.chatgptAccountId] as? [String: Any],
              let acct = entry["account"] as? [String: Any],
              let name = acct["name"] as? String else { return nil }
        return name
    }

    /// 刷新单个账号的用量和组织名
    func refreshOne(account: TokenAccount, store: TokenStore) async {
        do {
            async let usageResult = self.fetchUsage(account: account)
            async let orgName = self.fetchOrgName(account: account)
            let (result, name) = try await (usageResult, orgName)
            await MainActor.run {
                let updated = Self.updatedAccount(account, with: result, orgName: name)
                store.addOrUpdate(updated)
            }
        } catch WhamError.forbidden {
            await MainActor.run {
                var updated = account
                updated.isSuspended = true
                store.addOrUpdate(updated)
            }
        } catch WhamError.unauthorized {
            await MainActor.run {
                var updated = account
                updated.tokenExpired = true
                store.addOrUpdate(updated)
            }
        } catch {
            // 静默失败，保留上次数据
        }
    }

    /// 批量刷新 store 中所有账号的用量和组织名
    func refreshAll(store: TokenStore) async {
        await withTaskGroup(of: Void.self) { group in
            for account in store.accounts {
                group.addTask {
                    do {
                        async let usageResult = self.fetchUsage(account: account)
                        async let orgName = self.fetchOrgName(account: account)
                        let (result, name) = try await (usageResult, orgName)
                        await MainActor.run {
                            let updated = Self.updatedAccount(account, with: result, orgName: name)
                            store.addOrUpdate(updated)
                        }
                    } catch WhamError.forbidden {
                        await MainActor.run {
                            var updated = account
                            updated.isSuspended = true
                            store.addOrUpdate(updated)
                        }
                    } catch WhamError.unauthorized {
                        await MainActor.run {
                            var updated = account
                            updated.tokenExpired = true
                            store.addOrUpdate(updated)
                        }
                    } catch {
                        // 静默失败，保留上次数据
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func parseUsage(_ json: [String: Any]) -> WhamUsageResult {
        let planType = json["plan_type"] as? String ?? "free"
        var primaryUsedPercent: Double = 0
        var secondaryUsedPercent: Double = 0
        var primaryResetAt: Date? = nil
        var secondaryResetAt: Date? = nil
        var rateLimitResetCreditsAvailableCount: Int?
        var rateLimitResetCreditsExpiresAt: Date?

        if let rateLimit = json["rate_limit"] as? [String: Any] {

            // primary_window = 5h 窗口，used_percent: 0=未用, 100=耗尽
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                primaryUsedPercent = primary["used_percent"] as? Double ?? 0
                if let ts = primary["reset_at"] as? TimeInterval {
                    primaryResetAt = Date(timeIntervalSince1970: ts)
                }
            }

            // secondary_window = 周额度，used_percent: 0=本周未用, 100=耗尽
            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                let used = secondary["used_percent"] as? Double ?? 0
                secondaryUsedPercent = used
                if let ts = secondary["reset_at"] as? TimeInterval {
                    secondaryResetAt = Date(timeIntervalSince1970: ts)
                }
            }
        }

        if let resetCredits = json["rate_limit_reset_credits"] as? [String: Any] {
            rateLimitResetCreditsAvailableCount = Self.intValue(resetCredits["available_count"])
            rateLimitResetCreditsExpiresAt = Self.resetCreditsExpirationDate(from: resetCredits)
        }

        return WhamUsageResult(
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            rateLimitResetCreditsAvailableCount: rateLimitResetCreditsAvailableCount,
            rateLimitResetCreditsExpiresAt: rateLimitResetCreditsExpiresAt
        )
    }

    @MainActor
    private static func updatedAccount(_ account: TokenAccount, with result: WhamUsageResult, orgName: String?) -> TokenAccount {
        let nextPrimaryResetAt = result.primaryResetAt ?? futureDate(account.primaryResetAt)
        let nextSecondaryResetAt = result.secondaryResetAt ?? futureDate(account.secondaryResetAt)

        var updated = account
        updated.tokenExpired = false
        updated.isSuspended = false
        updated.planType = result.planType
        updated.primaryUsedPercent = result.primaryUsedPercent
        updated.secondaryUsedPercent = result.secondaryUsedPercent
        updated.primaryResetAt = nextPrimaryResetAt
        updated.secondaryResetAt = nextSecondaryResetAt
        updated.rateLimitResetCreditsAvailableCount = result.rateLimitResetCreditsAvailableCount
        if let count = result.rateLimitResetCreditsAvailableCount, count > 0 {
            updated.rateLimitResetCreditsExpiresAt = result.rateLimitResetCreditsExpiresAt ?? futureDate(account.rateLimitResetCreditsExpiresAt)
        } else {
            updated.rateLimitResetCreditsExpiresAt = nil
        }
        updated.lastChecked = Date()
        if let orgName { updated.organizationName = orgName }
        return updated
    }

    private static func futureDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSinceNow > 0 else { return nil }
        return date
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
            "valid_until",
            "valid_through",
            "validUntil"
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
            "ttl_seconds"
        ]
        for key in relativeKeys {
            if let seconds = doubleValue(resetCredits[key]), seconds > 0 {
                return Date(timeIntervalSinceNow: seconds)
            }
        }

        return nil
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
            if let date = ISO8601DateFormatter().date(from: string) {
                return date
            }
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

struct WhamUsageResult {
    let planType: String
    let primaryUsedPercent: Double
    let secondaryUsedPercent: Double
    let primaryResetAt: Date?
    let secondaryResetAt: Date?
    let rateLimitResetCreditsAvailableCount: Int?
    let rateLimitResetCreditsExpiresAt: Date?
}

enum WhamError: LocalizedError {
    case invalidResponse, unauthorized, forbidden, parseError
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无效响应"
        case .unauthorized: return "Token 已过期"
        case .forbidden: return "账号被封禁"
        case .parseError: return "解析失败"
        case .httpError(let code): return "HTTP \(code)"
        }
    }
}
