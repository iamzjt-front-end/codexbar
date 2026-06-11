import Foundation
import Combine

class TokenStore: ObservableObject {
    static let shared = TokenStore()

    @Published var accounts: [TokenAccount] = []

    private let poolURL: URL
    private let authURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        // 用 getpwuid 取真实 home，绕过沙盒对 HOME 的重映射
        let sandboxHome = FileManager.default.homeDirectoryForCurrentUser
        let realHome: URL
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            realHome = URL(fileURLWithPath: String(cString: pwDir))
        } else {
            realHome = sandboxHome
        }
        let realCodex = realHome.appendingPathComponent(".codex")
        try? FileManager.default.createDirectory(at: realCodex, withIntermediateDirectories: true)

        // token_pool.json 和 auth.json 都放在真实 ~/.codex/
        poolURL = realCodex.appendingPathComponent("token_pool.json")
        authURL = realCodex.appendingPathComponent("auth.json")

        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: poolURL) else {
            accounts = []
            return
        }
        do {
            let pool = try decoder.decode(TokenPool.self, from: data)
            accounts = pool.accounts
            markActiveAccount()
        } catch {
            accounts = []
        }
    }

    func save() {
        let pool = TokenPool(accounts: accounts)
        guard let data = try? encoder.encode(pool) else { return }
        try? data.write(to: poolURL, options: .atomic)
    }

    func addOrUpdate(_ account: TokenAccount) {
        let matchIdx: Int?
        if !account.accountId.isEmpty {
            matchIdx = accounts.firstIndex { $0.accountId == account.accountId }
        } else if !account.email.isEmpty {
            matchIdx = accounts.firstIndex { $0.email == account.email }
        } else {
            matchIdx = nil
        }
        if let idx = matchIdx {
            var merged = account
            // 保留 store 里的 isActive，防止异步刷新快照覆盖 activate() 的结果
            merged.isActive = accounts[idx].isActive
            accounts[idx] = merged
        } else {
            accounts.append(account)
        }
        save()
    }

    func remove(_ account: TokenAccount) {
        accounts.removeAll { $0.accountId == account.accountId }
        save()
    }

    /// 将指定账号写入 ~/.codex/auth.json，激活为当前 Codex 使用账号
    func activate(_ account: TokenAccount) throws {
        // 守护：空 id_token 会让 Codex 报 "invalid ID token format" 并要求重登，绝不写入
        guard !account.idToken.isEmpty else { throw TokenStoreError.missingIdToken }
        let authDict = buildAuthJSON(account)
        guard JSONSerialization.isValidJSONObject(authDict),
              let data = try? JSONSerialization.data(withJSONObject: authDict, options: [.prettyPrinted, .sortedKeys]) else {
            throw TokenStoreError.encodingFailed
        }
        try data.write(to: authURL, options: .atomic)
        markActiveAccount()
        objectWillChange.send()
    }


    func activeAccount() -> TokenAccount? {
        accounts.first { $0.isActive }
    }

    // MARK: - Private

    func markActiveAccount() {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else { return }
        // 用 access_token 精确匹配激活账号：team workspace 多成员共享 chatgpt_account_id，
        // 仅靠 account_id 无法区分是哪个成员，access_token 才能定位到具体成员。
        let activeAccess = tokens["access_token"] as? String
        let activeAcctId = tokens["account_id"] as? String

        let activeIndex: Int?
        if let activeAccess, !activeAccess.isEmpty,
           let idx = accounts.firstIndex(where: { $0.accessToken == activeAccess }) {
            activeIndex = idx
        } else if let activeAcctId, !activeAcctId.isEmpty,
                  let idx = accounts.firstIndex(where: { $0.isActive && $0.chatgptAccountId == activeAcctId }) {
            activeIndex = idx
        } else if let activeAcctId, !activeAcctId.isEmpty {
            let matches = accounts.indices.filter {
                accounts[$0].chatgptAccountId == activeAcctId || accounts[$0].accountId == activeAcctId
            }
            activeIndex = matches.count == 1 ? matches[0] : nil
        } else {
            activeIndex = nil
        }

        guard let activeIndex else { return }
        for idx in accounts.indices {
            accounts[idx].isActive = idx == activeIndex
        }
        save()
    }

    private func buildAuthJSON(_ account: TokenAccount) -> [String: Any] {
        let tokens: [String: Any] = [
            "access_token": account.accessToken,
            "refresh_token": account.refreshToken,
            "id_token": account.idToken,
            "account_id": account.chatgptAccountId,
        ]
        return [
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": NSNull(),
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
            "tokens": tokens
        ]
    }
}

enum TokenStoreError: LocalizedError {
    case encodingFailed
    case missingIdToken
    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "写入 auth.json 失败"
        case .missingIdToken: return "账号缺少 id_token，无法激活"
        }
    }
}
