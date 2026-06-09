import SwiftUI
import AppKit
import Combine
import UserNotifications
import UniformTypeIdentifiers

struct MenuBarView: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var oauth: OAuthManager
    @State private var isRefreshing = false
    @State private var showError: String?
    @State private var showSuccess: String?
    @State private var now = Date()
    @State private var refreshingAccounts: Set<String> = []

    // 每 10 秒刷新倒计时显示
    private let countdownTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    // 菜单打开时 10 秒快速刷新活跃账号；菜单关闭时 5 分钟后台刷新全部
    private let quickTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private let slowTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var menuVisible = false
    @State private var languageToggle = false  // 用于触发语言切换后的重绘

    /// email → accounts (sorted: active first, then by status)
    private var groupedAccounts: [(email: String, accounts: [TokenAccount])] {
        var dict: [String: [TokenAccount]] = [:]
        var order: [String] = []
        for acc in store.accounts {
            if dict[acc.email] == nil {
                dict[acc.email] = []
                order.append(acc.email)
            }
            dict[acc.email]!.append(acc)
        }
        // sort accounts within each group
        let sortedOrder = order.sorted { e1, e2 in
            let best1 = bestStatus(dict[e1]!)
            let best2 = bestStatus(dict[e2]!)
            return best1 < best2
        }
        return sortedOrder.map { email in
            let sorted = dict[email]!.sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                return statusRank(a) < statusRank(b)
            }
            return (email: email, accounts: sorted)
        }
    }

    private func bestStatus(_ accounts: [TokenAccount]) -> Int {
        accounts.map { statusRank($0) }.min() ?? 2
    }

    private func statusRank(_ a: TokenAccount) -> Int {
        switch a.usageStatus {
        case .ok: return 0
        case .warning: return 1
        case .exceeded: return 2
        case .banned: return 3
        }
    }

    private var availableCount: Int {
        store.accounts.filter { $0.usageStatus == .ok }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("CodexAppBar")
                    .font(.system(size: 13, weight: .semibold))

                if !store.accounts.isEmpty {
                    Text(L.available(availableCount, store.accounts.count))
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(availableCount > 0 ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                        .foregroundColor(availableCount > 0 ? .green : .red)
                        .cornerRadius(4)
                }

                Spacer()

                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
                .buttonStyle(.borderless)
                .help(L.refreshUsage)
                .disabled(isRefreshing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(L.noAccounts)
                        .foregroundColor(.secondary)
                    Text(L.addAccountHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedAccounts, id: \.email) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                // Email group header
                                Text(group.email)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .padding(.leading, 4)

                                // Account rows
                                ForEach(group.accounts) { account in
                                    AccountRowView(
                                        account: account,
                                        isActive: account.isActive,
                                        now: now,
                                        isRefreshing: refreshingAccounts.contains(account.id)
                                    ) {
                                        activateAccount(account)
                                    } onRefresh: {
                                        Task { await refreshAccount(account) }
                                    } onReauth: {
                                        reauthAccount(account)
                                    } onDelete: {
                                        store.remove(account)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 380)
            }

            if let success = showSuccess {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if let error = showError {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        showError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if !store.accounts.isEmpty {
                Divider()
                TokenStatsView()
            }

            Divider()

            // 底部操作栏
            HStack(spacing: 8) {
                if let lastUpdate = store.accounts.compactMap({ $0.lastChecked }).max() {
                    Text(relativeTime(lastUpdate))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    oauth.startOAuth { result in
                        switch result {
                        case .success(let tokens):
                            let account = AccountBuilder.build(from: tokens)
                            store.addOrUpdate(account)
                            Task { await WhamService.shared.refreshOne(account: account, store: store) }
                        case .failure(let error):
                            showError = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(L.addAccount)

                Button {
                    importAccounts()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(L.importAccount)

                Button {
                    switch L.languageOverride {
                    case nil:   L.languageOverride = true
                    case true:  L.languageOverride = false
                    case false: L.languageOverride = nil
                    }
                    languageToggle.toggle()
                } label: {
                    // languageToggle 作为 @State 依赖，保证切换后重绘
                    let label = languageToggle ? L.languageOverride : L.languageOverride
                    Text(label == nil ? "AUTO" : (label == true ? "中" : "EN"))
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("切换语言 / Switch Language")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(L.quit)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        .onReceive(countdownTimer) { _ in now = Date() }
        .onReceive(quickTimer) { _ in
            guard menuVisible,
                  let active = store.accounts.first(where: { $0.isActive }),
                  !active.secondaryExhausted else { return }
            Task {
                await refreshAccount(active)
                store.markActiveAccount()
            }
        }
        .onReceive(slowTimer) { _ in
            Task {
                if !menuVisible { await refresh() }
                store.markActiveAccount()
            }
        }
        .onAppear {
            menuVisible = true
            store.markActiveAccount()
        }
        .onDisappear { menuVisible = false }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return L.justUpdated }
        if seconds < 3600 { return L.minutesAgo(seconds / 60) }
        return L.hoursAgo(seconds / 3600)
    }

    private func activateAccount(_ account: TokenAccount) {
        // team/SSO 账号导入时常无 id_token。直接激活会写空 id_token 到 auth.json，
        // Codex 报 "invalid ID token format"。先用 refresh_token 补一个 id_token 再激活。
        if account.idToken.isEmpty && !account.refreshToken.isEmpty {
            Task {
                _ = await RefreshService.shared.refreshAndPersist(account, store: store)
                await MainActor.run {
                    if let updated = store.accounts.first(where: { $0.accountId == account.accountId }),
                       !updated.idToken.isEmpty {
                        performActivate(updated)
                    } else {
                        showError = L.cannotActivateNoIdToken
                    }
                }
            }
            return
        }
        performActivate(account)
    }

    private func performActivate(_ account: TokenAccount) {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.openai.codex"
        }

        // Codex 没跑：直接切，不打扰
        guard !running.isEmpty else {
            do { try store.activate(account) }
            catch { showError = error.localizedDescription }
            return
        }

        // Codex 在跑：给两种切换方式
        // - 仅切换：只写 auth.json，不退 Codex（不中断任务；Codex 下次重读 auth 才生效）
        // - 切换并重启：写 auth.json + 强退重开 Codex（立即生效，但中断进行中的任务）
        let alert = NSAlert()
        alert.messageText = L.switchModeTitle
        alert.informativeText = L.switchModeInfo
        alert.addButton(withTitle: L.switchOnly)         // .alertFirstButtonReturn
        alert.addButton(withTitle: L.switchAndRestart)   // .alertSecondButtonReturn
        alert.addButton(withTitle: L.cancel)             // .alertThirdButtonReturn
        let resp = alert.runModal()
        guard resp != .alertThirdButtonReturn else { return }

        do {
            try store.activate(account)
        } catch {
            showError = error.localizedDescription
            return
        }
        if resp == .alertSecondButtonReturn {
            forceQuitCodex(running, reopen: true)
        }
    }

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "codexbar-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private func forceQuitCodex(_ running: [NSRunningApplication], reopen: Bool) {
        let ws = NSWorkspace.shared

        if reopen {
            guard let url = ws.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
                running.forEach { $0.forceTerminate() }
                return
            }
            var observer: NSObjectProtocol?
            observer = ws.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.openai.codex" else { return }
                ws.notificationCenter.removeObserver(observer!)
                ws.open(url)
            }
        }

        running.forEach { $0.forceTerminate() }
    }

    private func refresh() async {
        isRefreshing = true
        await RefreshService.shared.refreshExpiring(store: store)
        await WhamService.shared.refreshAll(store: store)
        isRefreshing = false
    }

    private func importAccounts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L.importAccount
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        do {
            let accounts = try AccountImporter.parse(data)
            for acc in accounts { store.addOrUpdate(acc) }
            showSuccess = L.importedCount(accounts.count)
            let imported = accounts
            Task {
                for acc in imported {
                    await WhamService.shared.refreshOne(account: acc, store: store)
                }
            }
        } catch {
            showError = error.localizedDescription
        }
    }

    private func refreshAccount(_ account: TokenAccount) async {
        refreshingAccounts.insert(account.id)
        await WhamService.shared.refreshOne(account: account, store: store)
        refreshingAccounts.remove(account.id)
    }

    private func reauthAccount(_ account: TokenAccount) {
        // 先尝试用 refresh_token 静默续期，成功就免去浏览器重新授权
        if !account.refreshToken.isEmpty {
            Task {
                let ok = await RefreshService.shared.refreshAndPersist(account, store: store)
                if ok {
                    if let updated = store.accounts.first(where: { $0.accountId == account.accountId }) {
                        await WhamService.shared.refreshOne(account: updated, store: store)
                    }
                } else {
                    // 续期失败（refresh_token 失效）→ 回退到完整 OAuth 重新授权
                    startReauthOAuth(account)
                }
            }
            return
        }
        startReauthOAuth(account)
    }

    private func startReauthOAuth(_ account: TokenAccount) {
        oauth.startOAuth { result in
            switch result {
            case .success(let tokens):
                var updated = AccountBuilder.build(from: tokens)
                // 若 account_id 匹配，覆盖原账号；否则按新账号添加
                if updated.accountId == account.accountId {
                    updated.isActive = account.isActive
                    updated.tokenExpired = false
                    updated.isSuspended = false
                }
                store.addOrUpdate(updated)
                Task { await WhamService.shared.refreshOne(account: updated, store: store) }
            case .failure(let error):
                showError = error.localizedDescription
            }
        }
    }
}
