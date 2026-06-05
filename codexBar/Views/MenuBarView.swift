import SwiftUI
import AppKit
import Combine
import UserNotifications

struct MenuBarView: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var oauth: OAuthManager
    @EnvironmentObject var language: LanguageSettings
    @EnvironmentObject var refreshFrequency: RefreshFrequencySettings
    @EnvironmentObject var codexHookInstaller: CodexHookInstallerService
    @State private var isRefreshing = false
    @State private var showError: String?
    @State private var showSuccess: String?
    @State private var now = Date()
    @State private var refreshingAccounts: Set<String> = []
    @State private var lastVisibleRefresh = Date()

    // 每秒刷新相对时间显示，并按用户选择的频率决定是否拉取额度。
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var menuVisible = false

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

    private var accountListHeight: CGFloat {
        let headerHeight = CGFloat(groupedAccounts.count) * 18
        let rowHeight = CGFloat(store.accounts.count) * 72
        return min(380, max(110, headerHeight + rowHeight + 16))
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

                if codexHookInstaller.state.needsAction {
                    Text(L.codexHookSetupBadge)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
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

            if codexHookInstaller.state.needsAction {
                CodexHookSetupRow(
                    state: codexHookInstaller.state,
                    installAction: installCodexHooks
                )

                Divider()
            }

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
                .frame(height: accountListHeight)
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
                    refreshFrequency.cycle()
                    lastVisibleRefresh = .distantPast
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                            .font(.system(size: 11))
                        Text(refreshFrequency.buttonLabel)
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .buttonStyle(.borderless)
                .help(refreshFrequency.helpText)

                Button {
                    language.cycle()
                } label: {
                    Text(language.buttonLabel)
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(language.switchLanguageHelp)

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
        .onReceive(tickTimer) { tickDate in
            now = tickDate
            guard menuVisible,
                  let active = store.accounts.first(where: { $0.isActive }),
                  !active.secondaryExhausted else { return }
            guard tickDate.timeIntervalSince(lastVisibleRefresh) >= refreshFrequency.selection.visibleInterval else { return }
            lastVisibleRefresh = tickDate
            Task {
                await refreshAccount(active)
                store.markActiveAccount()
            }
        }
        .onAppear {
            menuVisible = true
            lastVisibleRefresh = Date()
            store.markActiveAccount()
            codexHookInstaller.refresh()
            TokenStatsService.shared.refresh()
        }
        .onDisappear { menuVisible = false }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return L.justUpdated }
        if seconds < 3600 { return L.minutesAgo(seconds / 60) }
        return L.hoursAgo(seconds / 3600)
    }

    private func activateAccount(_ account: TokenAccount) {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.openai.codex"
        }

        // Codex 没跑：直接切，不打扰
        guard !running.isEmpty else {
            do { try store.activate(account) }
            catch { showError = error.localizedDescription }
            return
        }

        // Codex 在跑：问一下用户是否要切换（切换必须重启 Codex 才生效）
        let alert = NSAlert()
        alert.messageText = L.restartCodexTitle
        alert.informativeText = L.restartCodexInfo
        alert.addButton(withTitle: L.continueRestart)
        alert.addButton(withTitle: L.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.activate(account)
        } catch {
            showError = error.localizedDescription
            return
        }
        forceQuitCodex(running, reopen: true)
    }

    private func installCodexHooks() {
        let alert = NSAlert()
        alert.messageText = L.codexHookInstallConfirmTitle
        alert.informativeText = L.codexHookInstallConfirmInfo(codexHookInstaller.hooksURL.path)
        alert.addButton(withTitle: L.codexHookInstallConfirmButton)
        alert.addButton(withTitle: L.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try codexHookInstaller.install()
            showSuccess = L.codexHookInstallSuccess
            showError = nil
        } catch {
            showError = L.codexHookInstallFailed(error.localizedDescription)
            showSuccess = nil
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
        lastVisibleRefresh = Date()
        TokenStatsService.shared.refresh()
        isRefreshing = false
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

private struct CodexHookSetupRow: View {
    let state: CodexHookInstallState
    let installAction: () -> Void

    private var title: String {
        switch state {
        case .needsUpdate:
            return L.codexHookUpdateTitle
        case .error:
            return L.codexHookErrorTitle
        case .checking, .missing, .installed:
            return L.codexHookSetupTitle
        }
    }

    private var buttonTitle: String {
        state == .needsUpdate ? L.codexHookUpdateButton : L.codexHookInstallButton
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                Text(L.codexHookSetupDetail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button(action: installAction) {
                Text(buttonTitle)
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
