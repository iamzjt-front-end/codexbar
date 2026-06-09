import Foundation

/// 从 OAuth tokens 解析账号信息，构建 TokenAccount
struct AccountBuilder {
    static func build(from tokens: OAuthTokens) -> TokenAccount {
        let claims = decodeJWT(tokens.accessToken)
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]

        let chatgptAccountId = authClaims["chatgpt_account_id"] as? String ?? ""
        let userId = authClaims["user_id"] as? String ?? ""
        let planType = authClaims["chatgpt_plan_type"] as? String ?? "free"

        // 取 email：优先 id_token，缺失/解析失败时从 access_token 的 profile 兜底
        // （team/SSO 账号导入时可能没有 id_token，但 access_token 一定带 profile.email）
        let idClaims = decodeJWT(tokens.idToken)
        var email = idClaims["email"] as? String ?? ""
        if email.isEmpty {
            let profile = claims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
            email = profile["email"] as? String ?? ""
        }

        // accountId 唯一性优先级：chatgpt_account_id(workspace 级唯一) > email(账号级唯一)
        // > user_id(仅标识人，同一人多账号会撞，最后兜底)。
        // 用 email 兜底避免：同一 OpenAI 用户的不同账号/workspace 共享 user_id 时互相覆盖。
        let accountId: String
        if !chatgptAccountId.isEmpty {
            accountId = chatgptAccountId
        } else if !email.isEmpty {
            accountId = "email:\(email)"
        } else if !userId.isEmpty {
            accountId = userId
        } else {
            accountId = ""
        }

        // 订阅到期时间（从 id_token 的 auth claim 取）
        let idAuthClaims = idClaims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        var expiresAt: Date? = nil
        if let untilStr = idAuthClaims["chatgpt_subscription_active_until"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = formatter.date(from: untilStr)
                ?? ISO8601DateFormatter().date(from: untilStr)
        }

        // access_token 自身过期
        let tokenExp = claims["exp"] as? Double
        let tokenExpiresAt = tokenExp.map { Date(timeIntervalSince1970: $0) }

        return TokenAccount(
            email: email,
            accountId: accountId,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            expiresAt: expiresAt ?? tokenExpiresAt,
            planType: planType
        )
    }

    /// 解码 JWT payload（不验签）
    static func decodeJWT(_ token: String) -> [String: Any] {
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return [:] }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
}
