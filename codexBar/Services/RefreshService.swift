import Foundation

/// 用 refresh_token 续期 access_token。
/// 端点：POST https://auth.openai.com/oauth/token  (JSON body, grant_type=refresh_token)
/// 注意：refresh_token 是 rolling 的 —— 每次响应都会返回**新的** refresh_token，
/// 必须写回，否则旧的失效后再也续不了。
final class RefreshService {
    static let shared = RefreshService()
    private init() {}

    private let tokenURL = "https://auth.openai.com/oauth/token"
    private let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// access_token 剩余有效期低于此值就续期（默认 2 天）
    private let renewThreshold: TimeInterval = 2 * 24 * 3600

    struct RefreshedTokens {
        let accessToken: String
        let refreshToken: String
        let idToken: String
        let expiresAt: Date?
    }

    enum RefreshError: LocalizedError {
        case noRefreshToken
        case refreshTokenReused
        case invalidResponse
        case serverError(String)
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .noRefreshToken: return "缺少 refresh_token"
            case .refreshTokenReused: return "refresh_token 已失效，请重新授权"
            case .invalidResponse: return "续期响应无效"
            case .serverError(let m): return "续期失败: \(m)"
            case .network(let e): return e.localizedDescription
            }
        }
    }

    /// 判断账号是否需要续期：有 refresh_token 且（已过期 或 临近过期阈值）。
    /// 注意：active 账号的 token 由 Codex CLI 管理（Codex 运行时会轮换 auth.json 里的
    /// refresh_token），我们主动续会和 Codex 抢，导致 refresh_token_reused。
    /// 所以 active 账号交给 syncActiveFromAuthJson 同步，不在这里续。
    func needsRefresh(_ account: TokenAccount) -> Bool {
        guard !account.refreshToken.isEmpty else { return false }
        guard !account.isActive else { return false }
        guard let exp = account.expiresAt else { return true } // 不知道过期时间，保守续
        return exp.timeIntervalSinceNow < renewThreshold
    }

    /// 调端点续期。成功返回新三件套（含新 refresh_token）。
    func refresh(_ account: TokenAccount) async throws -> RefreshedTokens {
        guard !account.refreshToken.isEmpty else { throw RefreshError.noRefreshToken }

        guard let url = URL(string: tokenURL) else { throw RefreshError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": account.refreshToken,
            "client_id": clientId,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw RefreshError.network(error)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.invalidResponse
        }
        // 错误结构有两种：扁平 {"error":"x","error_description":"y"}
        // 或嵌套 {"error":{"message":..,"code":"refresh_token_reused"}}
        if let errObj = json["error"] as? [String: Any] {
            let code = errObj["code"] as? String ?? ""
            let msg = errObj["message"] as? String ?? "unknown"
            if code == "refresh_token_reused" {
                throw RefreshError.refreshTokenReused
            }
            throw RefreshError.serverError(msg)
        }
        if let errMsg = json["error"] as? String {
            let desc = json["error_description"] as? String ?? ""
            throw RefreshError.serverError("\(errMsg): \(desc)")
        }
        guard let accessToken = json["access_token"] as? String,
              let idToken = json["id_token"] as? String else {
            throw RefreshError.invalidResponse
        }
        // refresh_token 通常会返回新的；万一没返回就沿用旧的
        let newRefresh = (json["refresh_token"] as? String) ?? account.refreshToken

        let exp = AccountBuilder.decodeJWT(accessToken)["exp"] as? Double
        let expiresAt = exp.map { Date(timeIntervalSince1970: $0) }

        return RefreshedTokens(
            accessToken: accessToken,
            refreshToken: newRefresh,
            idToken: idToken,
            expiresAt: expiresAt
        )
    }

    /// 续期单个账号并写回 store。若是当前激活账号，同步重写 auth.json。
    /// 返回是否成功续期。
    @discardableResult
    @MainActor
    func refreshAndPersist(_ account: TokenAccount, store: TokenStore) async -> Bool {
        do {
            let fresh = try await refresh(account)
            var updated = account
            updated.accessToken = fresh.accessToken
            updated.refreshToken = fresh.refreshToken
            updated.idToken = fresh.idToken
            updated.expiresAt = fresh.expiresAt
            updated.tokenExpired = false
            store.addOrUpdate(updated)
            // 当前激活账号 → 同步写 auth.json，让 Codex 立即拿到新 token
            if updated.isActive {
                try? store.activate(updated)
            }
            return true
        } catch RefreshError.refreshTokenReused {
            // RT 已被消费且我们没拿到轮换后的新值 → 标记需重新授权，清掉死 RT 防止反复重试
            var updated = account
            updated.refreshToken = ""
            updated.tokenExpired = true
            store.addOrUpdate(updated)
            return false
        } catch {
            return false
        }
    }

    /// 扫描 store 所有账号，对临近/已过期的批量续期。
    /// active 账号不主动续（交给 Codex），但会从 auth.json 同步最新 token。
    @MainActor
    func refreshExpiring(store: TokenStore) async {
        syncActiveFromAuthJson(store: store)
        let targets = store.accounts.filter { needsRefresh($0) }
        for acc in targets {
            await refreshAndPersist(acc, store: store)
        }
    }

    /// 把 ~/.codex/auth.json 里（Codex 持续轮换的）最新 token 同步进 pool 的 active 账号，
    /// 让 pool 始终持有 active 账号的最新 refresh_token，不与 Codex 抢着续。
    @MainActor
    func syncActiveFromAuthJson(store: TokenStore) {
        let home: URL
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: pwDir))
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        let authURL = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accountId = tokens["account_id"] as? String,
              let access = tokens["access_token"] as? String,
              let refresh = tokens["refresh_token"] as? String,
              let id = tokens["id_token"] as? String else { return }

        guard let idx = store.accounts.firstIndex(where: { $0.accountId == accountId }) else { return }
        var acc = store.accounts[idx]
        // 只在 token 确实变化时写，避免无谓 save
        guard acc.accessToken != access || acc.refreshToken != refresh else { return }
        acc.accessToken = access
        acc.refreshToken = refresh
        acc.idToken = id
        if let exp = AccountBuilder.decodeJWT(access)["exp"] as? Double {
            acc.expiresAt = Date(timeIntervalSince1970: exp)
        }
        acc.tokenExpired = false
        store.addOrUpdate(acc)
    }
}
