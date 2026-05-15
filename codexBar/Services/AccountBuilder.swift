import Foundation

/// 从 OAuth tokens 解析账号信息，构建 TokenAccount
struct AccountBuilder {
    static func build(from tokens: OAuthTokens) -> TokenAccount {
        let claims = decodeJWT(tokens.accessToken)
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]

        let chatgptAccountId = authClaims["chatgpt_account_id"] as? String ?? ""
        let userId = authClaims["user_id"] as? String ?? ""
        let accountId = !chatgptAccountId.isEmpty ? chatgptAccountId : userId
        let planType = authClaims["chatgpt_plan_type"] as? String ?? "free"

        // 从 id_token 取 email
        let idClaims = decodeJWT(tokens.idToken)
        let email = idClaims["email"] as? String ?? ""

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
