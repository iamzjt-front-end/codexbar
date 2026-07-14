import Combine
import Foundation

struct AccountKey: Hashable, Sendable {
    fileprivate let rawValue: String

    fileprivate init?(account: TokenAccount) {
        if !account.accountId.isEmpty {
            rawValue = "account:\(account.accountId)"
        } else if !account.email.isEmpty {
            rawValue = "email:\(account.email.lowercased())"
        } else {
            return nil
        }
    }
}

struct CredentialRevision: Hashable, Sendable {
    fileprivate let value: UInt64
}

struct CredentialSnapshot: Sendable {
    let key: AccountKey
    let revision: CredentialRevision
    let chatgptAccountId: String
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Date?
    let isActive: Bool
}

struct AccountCredentials: Sendable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Date?
}

struct AccountUsagePatch: Sendable {
    let planType: String
    let weeklyUsedPercent: Double
    let weeklyResetAt: Date?
    let resetCreditsAvailableCount: Int?
    let resetCreditsExpiresAt: Date?
    let organizationName: String?
    let checkedAt: Date
}

enum ConditionalCommit: Equatable, Sendable {
    case applied
    case stale
    case missing
}

private struct ActiveAuthCredentials {
    let accountId: String
    let accessToken: String
    let refreshToken: String
    let idToken: String
}

@MainActor
final class TokenStore: ObservableObject {
    static let shared = TokenStore()

    @Published private(set) var accounts: [TokenAccount] = []

    private let poolURL: URL
    private let authURL: URL
    private var revisions: [AccountKey: CredentialRevision] = [:]
    private var nextRevisionValue: UInt64 = 1

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private convenience init() {
        let sandboxHome = FileManager.default.homeDirectoryForCurrentUser
        let realHome: URL
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            realHome = URL(fileURLWithPath: String(cString: pwDir))
        } else {
            realHome = sandboxHome
        }
        let codexURL = realHome.appendingPathComponent(".codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: codexURL, withIntermediateDirectories: true)
        self.init(
            poolURL: codexURL.appendingPathComponent("token_pool.json"),
            authURL: codexURL.appendingPathComponent("auth.json"),
            autoLoad: true
        )
    }

    init(poolURL: URL, authURL: URL, autoLoad: Bool = true) {
        self.poolURL = poolURL
        self.authURL = authURL
        if autoLoad {
            load()
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: poolURL) else {
            accounts = []
            revisions = [:]
            return
        }
        do {
            let pool = try decoder.decode(TokenPool.self, from: data)
            accounts = pool.accounts
            resetRevisions()
            markActiveAccount()
        } catch {
            accounts = []
            revisions = [:]
        }
    }

    func save() {
        try? saveThrowing()
    }

    func key(for account: TokenAccount) -> AccountKey? {
        AccountKey(account: account)
    }

    func account(for key: AccountKey) -> TokenAccount? {
        guard let index = index(for: key) else { return nil }
        return accounts[index]
    }

    func accountKeys() -> [AccountKey] {
        accounts.compactMap(AccountKey.init(account:))
    }

    func snapshot(for key: AccountKey) -> CredentialSnapshot? {
        guard let index = index(for: key) else { return nil }
        let revision = revisions[key] ?? makeNextRevision(for: key)
        let account = accounts[index]
        return CredentialSnapshot(
            key: key,
            revision: revision,
            chatgptAccountId: account.chatgptAccountId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken,
            expiresAt: account.expiresAt,
            isActive: account.isActive
        )
    }

    /// Commits a successful browser OAuth result. Existing quota and UI metadata are retained.
    /// If the account is active, auth.json is updated from the committed credentials before return.
    @discardableResult
    func commitOAuthAccount(_ incoming: TokenAccount, replacing replacementKey: AccountKey? = nil) throws -> AccountKey {
        guard let incomingKey = AccountKey(account: incoming) else {
            throw TokenStoreError.invalidAccount
        }
        guard !incoming.accessToken.isEmpty,
              !incoming.refreshToken.isEmpty,
              !incoming.idToken.isEmpty,
              !incoming.chatgptAccountId.isEmpty else {
            throw TokenStoreError.invalidCredentials
        }

        let replacementIndex: Int?
        if replacementKey == incomingKey, let replacementKey {
            replacementIndex = index(for: replacementKey)
        } else {
            replacementIndex = index(for: incomingKey)
        }

        if let replacementIndex {
            let current = accounts[replacementIndex]
            var merged = current
            merged.email = incoming.email.isEmpty ? current.email : incoming.email
            merged.chatgptAccountId = incoming.chatgptAccountId.isEmpty
                ? current.chatgptAccountId
                : incoming.chatgptAccountId
            merged.accessToken = incoming.accessToken
            merged.refreshToken = incoming.refreshToken
            merged.idToken = incoming.idToken
            merged.expiresAt = incoming.expiresAt
            merged.planType = incoming.planType
            merged.tokenExpired = false
            merged.isSuspended = false

            if merged.isActive {
                try writeAuthJSON(for: merged)
            }
            accounts[replacementIndex] = merged
        } else {
            var added = incoming
            added.isActive = false
            added.tokenExpired = false
            added.isSuspended = false
            accounts.append(added)
        }

        _ = makeNextRevision(for: incomingKey)
        try saveThrowing()
        return incomingKey
    }

    /// Imports credentials without replacing current quota, active state or access-state metadata.
    /// Empty imported refresh/id credentials never erase existing non-empty values.
    @discardableResult
    func upsertImportedAccount(_ incoming: TokenAccount) throws -> AccountKey {
        guard let incomingKey = AccountKey(account: incoming) else {
            throw TokenStoreError.invalidAccount
        }
        guard !incoming.accessToken.isEmpty else {
            throw TokenStoreError.invalidCredentials
        }

        if let index = index(for: incomingKey) {
            let current = accounts[index]
            var merged = current
            merged.email = incoming.email.isEmpty ? current.email : incoming.email
            merged.chatgptAccountId = incoming.chatgptAccountId.isEmpty
                ? current.chatgptAccountId
                : incoming.chatgptAccountId
            merged.accessToken = incoming.accessToken
            if !incoming.refreshToken.isEmpty { merged.refreshToken = incoming.refreshToken }
            if !incoming.idToken.isEmpty { merged.idToken = incoming.idToken }
            if let expiresAt = incoming.expiresAt { merged.expiresAt = expiresAt }
            if !incoming.planType.isEmpty { merged.planType = incoming.planType }

            let credentialsChanged = current.accessToken != merged.accessToken
                || current.refreshToken != merged.refreshToken
                || current.idToken != merged.idToken
            if merged.isActive, credentialsChanged {
                try writeAuthJSON(for: merged)
            }
            accounts[index] = merged
            if credentialsChanged {
                _ = makeNextRevision(for: incomingKey)
            }
        } else {
            var added = incoming
            added.isActive = false
            accounts.append(added)
            _ = makeNextRevision(for: incomingKey)
        }

        try saveThrowing()
        return incomingKey
    }

    @discardableResult
    func applyUsagePatch(
        _ patch: AccountUsagePatch,
        to key: AccountKey,
        ifCurrent expectedRevision: CredentialRevision
    ) -> ConditionalCommit {
        guard let index = index(for: key) else { return .missing }
        guard revisions[key] == expectedRevision else { return .stale }

        var current = accounts[index]
        current.tokenExpired = false
        current.isSuspended = false
        current.planType = patch.planType
        current.weeklyUsedPercent = patch.weeklyUsedPercent
        current.weeklyResetAt = patch.weeklyResetAt
            ?? futureDate(current.weeklyResetAt, relativeTo: patch.checkedAt)
        current.rateLimitResetCreditsAvailableCount = patch.resetCreditsAvailableCount
        if let count = patch.resetCreditsAvailableCount, count > 0 {
            current.rateLimitResetCreditsExpiresAt = patch.resetCreditsExpiresAt
                ?? futureDate(current.rateLimitResetCreditsExpiresAt, relativeTo: patch.checkedAt)
        } else {
            current.rateLimitResetCreditsExpiresAt = nil
        }
        current.lastChecked = patch.checkedAt
        if let organizationName = patch.organizationName {
            current.organizationName = organizationName
        }
        accounts[index] = current
        save()
        return .applied
    }

    @discardableResult
    func markTokenExpired(
        _ key: AccountKey,
        ifCurrent expectedRevision: CredentialRevision
    ) -> ConditionalCommit {
        guard let index = index(for: key) else { return .missing }
        guard revisions[key] == expectedRevision else { return .stale }
        accounts[index].tokenExpired = true
        save()
        return .applied
    }

    @discardableResult
    func markSuspended(
        _ key: AccountKey,
        ifCurrent expectedRevision: CredentialRevision
    ) -> ConditionalCommit {
        guard let index = index(for: key) else { return .missing }
        guard revisions[key] == expectedRevision else { return .stale }
        accounts[index].tokenExpired = false
        accounts[index].isSuspended = true
        save()
        return .applied
    }

    @discardableResult
    func commitRefreshedCredentials(
        _ credentials: AccountCredentials,
        to key: AccountKey,
        ifCurrent expectedRevision: CredentialRevision
    ) throws -> ConditionalCommit {
        guard let index = index(for: key) else { return .missing }
        guard revisions[key] == expectedRevision else { return .stale }
        guard !credentials.accessToken.isEmpty,
              !credentials.refreshToken.isEmpty,
              !credentials.idToken.isEmpty else {
            throw TokenStoreError.invalidCredentials
        }

        var current = accounts[index]
        current.accessToken = credentials.accessToken
        current.refreshToken = credentials.refreshToken
        current.idToken = credentials.idToken
        current.expiresAt = credentials.expiresAt
        current.tokenExpired = false
        if current.isActive {
            try writeAuthJSON(for: current)
        }
        accounts[index] = current
        _ = makeNextRevision(for: key)
        try saveThrowing()
        return .applied
    }

    @discardableResult
    func markRefreshCredentialInvalid(
        _ key: AccountKey,
        ifCurrent expectedRevision: CredentialRevision
    ) -> ConditionalCommit {
        guard let index = index(for: key) else { return .missing }
        guard revisions[key] == expectedRevision else { return .stale }

        accounts[index].tokenExpired = true
        // auth.json remains the authority for an active account. Do not create a pool/auth split
        // by clearing only the pool copy; the caller will immediately launch full OAuth.
        if !accounts[index].isActive, !accounts[index].refreshToken.isEmpty {
            accounts[index].refreshToken = ""
        }
        // Invalidate every result that started before the refresh credential was rejected,
        // even for active accounts whose auth.json copy must remain untouched until OAuth.
        _ = makeNextRevision(for: key)
        save()
        return .applied
    }

    func remove(_ account: TokenAccount) {
        guard let key = AccountKey(account: account) else { return }
        remove(key)
    }

    func remove(_ key: AccountKey) {
        accounts.removeAll { AccountKey(account: $0) == key }
        revisions[key] = nil
        save()
    }

    /// Activates by stable key and always writes the latest credentials held by the store.
    func activate(_ key: AccountKey) throws {
        guard let index = index(for: key) else { throw TokenStoreError.missingAccount }
        let current = accounts[index]
        guard !current.idToken.isEmpty else { throw TokenStoreError.missingIdToken }
        try writeAuthJSON(for: current)
        for accountIndex in accounts.indices {
            accounts[accountIndex].isActive = accountIndex == index
        }
        try saveThrowing()
    }

    func activate(_ account: TokenAccount) throws {
        guard let key = AccountKey(account: account) else { throw TokenStoreError.invalidAccount }
        try activate(key)
    }

    /// Applies auth.json as the active account credential authority. Returns true only when
    /// credential material changed (including an id_token-only rotation).
    @discardableResult
    func syncActiveCredentialsFromAuthFile() -> Bool {
        guard let credentials = readActiveAuthCredentials(),
              let activeIndex = activeIndex(for: credentials) else { return false }

        var active = accounts[activeIndex]
        let credentialsChanged = active.accessToken != credentials.accessToken
            || active.refreshToken != credentials.refreshToken
            || active.idToken != credentials.idToken
        let activeFlagsChanged = accounts.indices.contains { index in
            accounts[index].isActive != (index == activeIndex)
        }
        guard credentialsChanged || activeFlagsChanged else { return false }

        if credentialsChanged {
            active.accessToken = credentials.accessToken
            active.refreshToken = credentials.refreshToken
            active.idToken = credentials.idToken
            if let expiration = AccountBuilder.decodeJWT(credentials.accessToken)["exp"] as? Double {
                active.expiresAt = Date(timeIntervalSince1970: expiration)
            }
            active.tokenExpired = false
            if let key = AccountKey(account: active) {
                _ = makeNextRevision(for: key)
            }
        }
        accounts[activeIndex] = active
        for index in accounts.indices {
            accounts[index].isActive = index == activeIndex
        }
        save()
        return credentialsChanged
    }

    func markActiveAccount() {
        guard let credentials = readActiveAuthCredentials() else { return }
        let matchedIndex = activeIndex(for: credentials)
        var changed = false
        for index in accounts.indices {
            let shouldBeActive = index == matchedIndex
            if accounts[index].isActive != shouldBeActive {
                accounts[index].isActive = shouldBeActive
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Private

    private func saveThrowing() throws {
        let pool = TokenPool(accounts: accounts)
        let data: Data
        do {
            data = try encoder.encode(pool)
            try FileManager.default.createDirectory(
                at: poolURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: poolURL, options: .atomic)
        } catch {
            throw TokenStoreError.persistenceFailed(error)
        }
    }

    private func writeAuthJSON(for account: TokenAccount) throws {
        guard !account.idToken.isEmpty else { throw TokenStoreError.missingIdToken }
        let tokens: [String: Any] = [
            "access_token": account.accessToken,
            "refresh_token": account.refreshToken,
            "id_token": account.idToken,
            "account_id": account.chatgptAccountId,
        ]
        let auth: [String: Any] = [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
            "tokens": tokens,
        ]
        guard JSONSerialization.isValidJSONObject(auth) else {
            throw TokenStoreError.encodingFailed
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: auth, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(
                at: authURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: authURL, options: .atomic)
        } catch {
            throw TokenStoreError.persistenceFailed(error)
        }
    }

    private func readActiveAuthCredentials() -> ActiveAuthCredentials? {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accountId = tokens["account_id"] as? String,
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String,
              let idToken = tokens["id_token"] as? String,
              !accountId.isEmpty,
              !accessToken.isEmpty,
              !refreshToken.isEmpty,
              !idToken.isEmpty else { return nil }
        return ActiveAuthCredentials(
            accountId: accountId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken
        )
    }

    private func activeIndex(for credentials: ActiveAuthCredentials) -> Int? {
        if let exact = accounts.firstIndex(where: { $0.accessToken == credentials.accessToken }) {
            return exact
        }
        if let currentWorkspace = accounts.firstIndex(where: {
            $0.isActive && $0.chatgptAccountId == credentials.accountId
        }) {
            return currentWorkspace
        }
        let matches = accounts.indices.filter {
            accounts[$0].chatgptAccountId == credentials.accountId
                || accounts[$0].accountId == credentials.accountId
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func index(for key: AccountKey) -> Int? {
        accounts.firstIndex { AccountKey(account: $0) == key }
    }

    private func resetRevisions() {
        revisions = [:]
        for account in accounts {
            if let key = AccountKey(account: account) {
                _ = makeNextRevision(for: key)
            }
        }
    }

    @discardableResult
    private func makeNextRevision(for key: AccountKey) -> CredentialRevision {
        let revision = CredentialRevision(value: nextRevisionValue)
        nextRevisionValue &+= 1
        revisions[key] = revision
        return revision
    }

    private func futureDate(_ date: Date?, relativeTo reference: Date) -> Date? {
        guard let date, date > reference else { return nil }
        return date
    }
}

enum TokenStoreError: LocalizedError {
    case encodingFailed
    case missingIdToken
    case invalidAccount
    case invalidCredentials
    case missingAccount
    case persistenceFailed(Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "写入授权信息失败"
        case .missingIdToken:
            return "账号缺少 id_token，无法激活"
        case .invalidAccount:
            return "账号缺少可识别的身份信息"
        case .invalidCredentials:
            return "授权凭证不完整"
        case .missingAccount:
            return "账号已不存在"
        case .persistenceFailed(let error):
            return error.localizedDescription
        }
    }
}
