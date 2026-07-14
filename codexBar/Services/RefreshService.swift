import Foundation

enum CredentialRefreshResult: Equatable, Sendable {
    case refreshed
    case superseded
    case needsReauthorization
    case transientFailure
    case missing
}

/// Rotates rolling refresh credentials and commits them with credential-generation CAS.
@MainActor
final class RefreshService {
    static let shared = RefreshService()

    private let tokenURL = "https://auth.openai.com/oauth/token"
    private let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let renewThreshold: TimeInterval = 2 * 24 * 3600
    private let httpClient: HTTPDataClient
    private var flights: [FlightKey: Task<CredentialRefreshResult, Never>] = [:]

    private struct FlightKey: Hashable {
        let accountKey: AccountKey
        let revision: CredentialRevision
    }

    struct RefreshedTokens {
        let accessToken: String
        let refreshToken: String
        let idToken: String
        let expiresAt: Date?
    }

    enum RefreshError: LocalizedError {
        case noRefreshToken
        case invalidRefreshCredential
        case invalidResponse
        case serverError(String)
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .noRefreshToken: return "缺少 refresh_token"
            case .invalidRefreshCredential: return "refresh_token 已失效，请重新授权"
            case .invalidResponse: return "续期响应无效"
            case .serverError(let message): return "续期失败: \(message)"
            case .network(let error): return error.localizedDescription
            }
        }
    }

    convenience init() {
        self.init(httpClient: URLSessionHTTPDataClient())
    }

    init(httpClient: HTTPDataClient) {
        self.httpClient = httpClient
    }

    /// Active credentials are rotated by Codex and synchronized from auth.json instead.
    func canRefreshWithoutUserInteraction(_ account: TokenAccount) -> Bool {
        !account.isActive && !account.refreshToken.isEmpty
    }

    func needsRefresh(_ account: TokenAccount) -> Bool {
        guard canRefreshWithoutUserInteraction(account) else { return false }
        guard let expiration = account.expiresAt else { return true }
        return expiration.timeIntervalSinceNow < renewThreshold
    }

    func refreshAndPersist(key: AccountKey, store: TokenStore) async -> CredentialRefreshResult {
        guard let snapshot = store.snapshot(for: key) else { return .missing }
        let flightKey = FlightKey(accountKey: key, revision: snapshot.revision)
        if let existing = flights[flightKey] {
            return await existing.value
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
        let result = await task.value
        flights[flightKey] = nil
        return result
    }

    /// Scans current accounts. All callers converge on refreshAndPersist's per-generation flight.
    func refreshExpiring(store: TokenStore) async {
        syncActiveFromAuthJson(store: store)
        let targets = store.accounts.filter { needsRefresh($0) }
        for account in targets {
            guard let key = store.key(for: account) else { continue }
            _ = await refreshAndPersist(key: key, store: store)
        }
    }

    @discardableResult
    func syncActiveFromAuthJson(store: TokenStore) -> Bool {
        store.syncActiveCredentialsFromAuthFile()
    }

    // MARK: - Private

    private func performRefresh(
        snapshot: CredentialSnapshot,
        store: TokenStore
    ) async -> CredentialRefreshResult {
        do {
            let fresh = try await refresh(snapshot: snapshot)
            if Task.isCancelled { return .superseded }
            let credentials = AccountCredentials(
                accessToken: fresh.accessToken,
                refreshToken: fresh.refreshToken,
                idToken: fresh.idToken,
                expiresAt: fresh.expiresAt
            )
            switch try store.commitRefreshedCredentials(
                credentials,
                to: snapshot.key,
                ifCurrent: snapshot.revision
            ) {
            case .applied:
                return .refreshed
            case .stale:
                return .superseded
            case .missing:
                return .missing
            }
        } catch RefreshError.invalidRefreshCredential {
            if Task.isCancelled { return .superseded }
            switch store.markRefreshCredentialInvalid(
                snapshot.key,
                ifCurrent: snapshot.revision
            ) {
            case .applied:
                return .needsReauthorization
            case .stale:
                return .superseded
            case .missing:
                return .missing
            }
        } catch RefreshError.noRefreshToken {
            return .needsReauthorization
        } catch {
            return Task.isCancelled ? .superseded : .transientFailure
        }
    }

    private func refresh(snapshot: CredentialSnapshot) async throws -> RefreshedTokens {
        guard !snapshot.refreshToken.isEmpty else { throw RefreshError.noRefreshToken }
        guard let url = URL(string: tokenURL) else { throw RefreshError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": snapshot.refreshToken,
            "client_id": clientId,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw RefreshError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.invalidResponse
        }
        // An HTTP 401 from the token endpoint is definitive even when the body is empty or
        // malformed. Other failures stay transient unless the OAuth error code says the
        // refresh credential itself is invalid.
        if http.statusCode == 401 {
            throw RefreshError.invalidRefreshCredential
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.invalidResponse
        }
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? String ?? ""
            let message = error["message"] as? String ?? "unknown"
            if Self.isInvalidRefreshCredential(code: code, description: message) {
                throw RefreshError.invalidRefreshCredential
            }
            throw RefreshError.serverError(message)
        }
        if let error = json["error"] as? String {
            let description = json["error_description"] as? String ?? ""
            if Self.isInvalidRefreshCredential(code: error, description: description) {
                throw RefreshError.invalidRefreshCredential
            }
            throw RefreshError.serverError("\(error): \(description)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RefreshError.serverError("HTTP \(http.statusCode)")
        }
        guard let accessToken = json["access_token"] as? String,
              let idToken = json["id_token"] as? String,
              !accessToken.isEmpty,
              !idToken.isEmpty else {
            throw RefreshError.invalidResponse
        }
        let refreshToken = json["refresh_token"] as? String ?? snapshot.refreshToken
        guard !refreshToken.isEmpty else { throw RefreshError.invalidResponse }
        let expiration = (AccountBuilder.decodeJWT(accessToken)["exp"] as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        return RefreshedTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiration
        )
    }

    private static func isInvalidRefreshCredential(code: String, description: String) -> Bool {
        let permanentCodes: Set<String> = [
            "invalid_grant",
            "invalid_refresh_token",
            "refresh_token_expired",
            "refresh_token_invalid",
            "refresh_token_reused",
            "refresh_token_revoked",
        ]
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDescription = description.lowercased()
        return permanentCodes.contains(normalizedCode)
            || permanentCodes.contains(where: normalizedDescription.contains)
    }
}
