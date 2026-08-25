import Foundation

struct TokenAccount: Codable, Identifiable {
    var id: String { accountId }
    var email: String
    var accountId: String            // 去重唯一键：team 下用 chatgpt_account_user_id（含成员），保证不同成员不撞
    var chatgptAccountId: String     // workspace 级 id：API header / auth.json / Codex 对齐用
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date?              // 订阅到期时间（兼容已有 expires_at 数据）
    var accessTokenExpiresAt: Date?   // access token 自身的 JWT exp
    var planType: String
    var fiveHourUsedPercent: Double? // Plus 5h 窗口已使用%；其他计划为 nil
    var fiveHourResetAt: Date?        // Plus 5h 窗口重置绝对时间
    var weeklyUsedPercent: Double    // 7d 窗口已使用%
    var weeklyResetAt: Date?         // 7d 窗口重置绝对时间
    var rateLimitResetCreditsAvailableCount: Int? // 官方 banked Codex 重置次数
    var rateLimitResetCreditsExpiresAt: Date? // 官方 banked Codex 重置次数过期时间
    var lastChecked: Date?
    var isActive: Bool
    var isSuspended: Bool       // 403 = 账号被封禁/停用
    var tokenExpired: Bool       // 授权失效，需重新授权
    var authorizationInvalidConfirmed: Bool // 新版多次确认或刷新凭据被明确拒绝
    var organizationName: String?

    enum CodingKeys: String, CodingKey {
        case email
        case accountId = "account_id"
        case chatgptAccountId = "chatgpt_account_id"
        case organizationName = "organization_name"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresAt = "expires_at"
        case accessTokenExpiresAt = "access_token_expires_at"
        case planType = "plan_type"
        case fiveHourUsedPercent = "five_hour_used_percent"
        case fiveHourResetAt = "five_hour_reset_at"
        case weeklyUsedPercent = "weekly_used_percent"
        case weeklyResetAt = "weekly_reset_at"
        case rateLimitResetCreditsAvailableCount = "rate_limit_reset_credits_available_count"
        case rateLimitResetCreditsExpiresAt = "rate_limit_reset_credits_expires_at"
        case lastChecked = "last_checked"
        case isActive = "is_active"
        case isSuspended = "is_suspended"
        case tokenExpired = "token_expired"
        case authorizationInvalidConfirmed = "authorization_invalid_confirmed"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case primaryUsedPercent = "primary_used_percent"
        case secondaryUsedPercent = "secondary_used_percent"
        case primaryResetAt = "primary_reset_at"
        case secondaryResetAt = "secondary_reset_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        accountId = try c.decode(String.self, forKey: .accountId)
        // 旧 pool 没这字段 → 兜底用 accountId（旧 accountId 就是 chatgpt_account_id）
        chatgptAccountId = try c.decodeIfPresent(String.self, forKey: .chatgptAccountId) ?? accountId
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        idToken = try c.decode(String.self, forKey: .idToken)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        accessTokenExpiresAt = try c.decodeIfPresent(Date.self, forKey: .accessTokenExpiresAt)
        planType = try c.decodeIfPresent(String.self, forKey: .planType) ?? "free"
        lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked)

        let decodedFiveHourUsedPercent = try c.decodeIfPresent(Double.self, forKey: .fiveHourUsedPercent)
        let decodedFiveHourResetAt = try c.decodeIfPresent(Date.self, forKey: .fiveHourResetAt)

        if c.contains(.weeklyUsedPercent) || c.contains(.weeklyResetAt) {
            weeklyUsedPercent = try c.decodeIfPresent(Double.self, forKey: .weeklyUsedPercent) ?? 0
            weeklyResetAt = try c.decodeIfPresent(Date.self, forKey: .weeklyResetAt)
            fiveHourUsedPercent = decodedFiveHourUsedPercent
            fiveHourResetAt = decodedFiveHourResetAt
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let primaryUsed = try legacy.decodeIfPresent(Double.self, forKey: .primaryUsedPercent) ?? 0
            let secondaryUsed = try legacy.decodeIfPresent(Double.self, forKey: .secondaryUsedPercent) ?? 0
            let primaryReset = try legacy.decodeIfPresent(Date.self, forKey: .primaryResetAt)
            let secondaryReset = try legacy.decodeIfPresent(Date.self, forKey: .secondaryResetAt)

            if secondaryReset != nil || secondaryUsed > 0 {
                // 旧双窗口结构：secondary 承载 7d。
                weeklyUsedPercent = secondaryUsed
                weeklyResetAt = secondaryReset
                fiveHourUsedPercent = primaryUsed
                fiveHourResetAt = primaryReset
            } else if Self.looksLikeWeeklyReset(primaryReset, checkedAt: lastChecked) {
                // 新接口被旧版本保存过：primary 实际已变成 7d，secondary 被写成 0。
                weeklyUsedPercent = primaryUsed
                weeklyResetAt = primaryReset
                fiveHourUsedPercent = nil
                fiveHourResetAt = nil
            } else {
                weeklyUsedPercent = secondaryUsed
                weeklyResetAt = secondaryReset
                fiveHourUsedPercent = nil
                fiveHourResetAt = nil
            }
        }
        if !CodexQuotaPlan.supportsFiveHourQuota(planType) {
            fiveHourUsedPercent = nil
            fiveHourResetAt = nil
        }
        rateLimitResetCreditsAvailableCount = try c.decodeIfPresent(Int.self, forKey: .rateLimitResetCreditsAvailableCount)
        rateLimitResetCreditsExpiresAt = try c.decodeIfPresent(Date.self, forKey: .rateLimitResetCreditsExpiresAt)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        isSuspended = try c.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false
        tokenExpired = try c.decodeIfPresent(Bool.self, forKey: .tokenExpired) ?? false
        authorizationInvalidConfirmed = try c.decodeIfPresent(
            Bool.self,
            forKey: .authorizationInvalidConfirmed
        ) ?? false
        organizationName = try c.decodeIfPresent(String.self, forKey: .organizationName)
    }

    init(email: String = "", accountId: String = "", chatgptAccountId: String = "", accessToken: String = "",
         refreshToken: String = "", idToken: String = "", expiresAt: Date? = nil,
         accessTokenExpiresAt: Date? = nil,
         planType: String = "free", fiveHourUsedPercent: Double? = nil,
         fiveHourResetAt: Date? = nil, weeklyUsedPercent: Double = 0,
         weeklyResetAt: Date? = nil,
         rateLimitResetCreditsAvailableCount: Int? = nil,
         rateLimitResetCreditsExpiresAt: Date? = nil,
         lastChecked: Date? = nil, isActive: Bool = false, isSuspended: Bool = false, tokenExpired: Bool = false,
         authorizationInvalidConfirmed: Bool = false,
         organizationName: String? = nil) {
        self.email = email
        self.accountId = accountId
        self.chatgptAccountId = chatgptAccountId.isEmpty ? accountId : chatgptAccountId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.planType = planType
        self.fiveHourUsedPercent = CodexQuotaPlan.supportsFiveHourQuota(planType)
            ? fiveHourUsedPercent
            : nil
        self.fiveHourResetAt = CodexQuotaPlan.supportsFiveHourQuota(planType)
            ? fiveHourResetAt
            : nil
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetAt = weeklyResetAt
        self.rateLimitResetCreditsAvailableCount = rateLimitResetCreditsAvailableCount
        self.rateLimitResetCreditsExpiresAt = rateLimitResetCreditsExpiresAt
        self.lastChecked = lastChecked
        self.isActive = isActive
        self.isSuspended = isSuspended
        self.tokenExpired = tokenExpired
        self.authorizationInvalidConfirmed = authorizationInvalidConfirmed
        self.organizationName = organizationName
    }

    // MARK: - Computed

    var isBanned: Bool { isSuspended }
    var hasFiveHourQuota: Bool {
        CodexQuotaPlan.supportsFiveHourQuota(planType) && fiveHourUsedPercent != nil
    }
    var fiveHourExhausted: Bool { hasFiveHourQuota && (fiveHourUsedPercent ?? 0) >= 100 }
    var weeklyExhausted: Bool { weeklyUsedPercent >= 100 }
    var quotaExhausted: Bool { fiveHourExhausted || weeklyExhausted }
    var isAvailable: Bool { !tokenExpired && !isBanned && !quotaExhausted }

    var usageStatus: UsageStatus {
        if isBanned { return .banned }
        if quotaExhausted { return .exceeded }
        if (hasFiveHourQuota && (fiveHourUsedPercent ?? 0) >= 80) || weeklyUsedPercent >= 80 {
            return .warning
        }
        return .ok
    }

    /// Plus 5h 窗口重置时间点文字
    var fiveHourResetDescription: String {
        guard hasFiveHourQuota else { return "" }
        return resetLabel(from: fiveHourResetAt)
    }

    /// 7d 窗口重置时间点文字
    var weeklyResetDescription: String {
        resetLabel(from: weeklyResetAt)
    }

    private func resetLabel(from date: Date?) -> String {
        guard let date = date else { return "" }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return L.resetSoon }

        return L.resetAtDate(formattedResetDateTime(date))
    }

    private func formattedResetDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.zh ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func looksLikeWeeklyReset(_ resetAt: Date?, checkedAt: Date?) -> Bool {
        guard let resetAt else { return false }
        let reference = checkedAt ?? Date()
        return resetAt.timeIntervalSince(reference) >= 24 * 60 * 60
    }
}

enum CodexQuotaPlan {
    static func supportsFiveHourQuota(_ planType: String) -> Bool {
        let normalized = planType
            .lowercased()
            .replacingOccurrences(of: "[_\\-\\s]", with: "", options: .regularExpression)
        return normalized == "plus" || normalized == "chatgptplus"
    }
}

enum UsageStatus: Equatable {
    case ok, warning, exceeded, banned
}

struct TokenPool: Codable {
    var accounts: [TokenAccount]

    init(accounts: [TokenAccount] = []) {
        self.accounts = accounts
    }
}
