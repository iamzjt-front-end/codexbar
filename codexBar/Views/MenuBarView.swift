import SwiftUI
import AppKit
import Combine
import UserNotifications
import UniformTypeIdentifiers

struct MenuBarView: View {
    @EnvironmentObject var store: TokenStore
    @EnvironmentObject var oauth: OAuthManager
    @EnvironmentObject var language: LanguageSettings
    @EnvironmentObject var refreshFrequency: RefreshFrequencySettings
    @EnvironmentObject var quotaDisplay: QuotaDisplaySettings
    @EnvironmentObject var codexHookInstaller: CodexHookInstallerService
    @EnvironmentObject var appUpdater: AppUpdateService
    @State private var isRefreshing = false
    @State private var showError: String?
    @State private var showSuccess: String?
    @State private var now = Date()
    @State private var refreshingAccounts: Set<String> = []
    @State private var lastVisibleRefresh = Date()
    @State private var showRefreshCompleted = false
    @State private var refreshFeedbackHideTask: Task<Void, Never>?

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
        store.accounts.filter(\.isAvailable).count
    }

    private var availabilityBadgeColor: Color {
        availableCount > 0 ? CodexStatusPalette.ok : CodexStatusPalette.unavailable
    }

    private var accountListHeight: CGFloat {
        let headerHeight = CGFloat(groupedAccounts.count) * 18
        let rowHeight = CGFloat(store.accounts.count) * 72
        return min(320, max(110, headerHeight + rowHeight + 16))
    }

    private var refreshStatusText: String? {
        if isRefreshing { return L.refreshing }
        if showRefreshCompleted { return L.refreshed }
        return nil
    }

    private var refreshHelpText: String {
        if let lastUpdate = store.accounts.compactMap({ $0.lastChecked }).max() {
            return "\(L.refreshUsage) · \(relativeTime(lastUpdate))"
        }
        return L.refreshUsage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("CodexAppBar")
                    .font(.system(size: 13, weight: .semibold))

                if !store.accounts.isEmpty {
                    Text(L.available(availableCount, store.accounts.count))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(availabilityBadgeColor.opacity(0.18))
                        .foregroundColor(availabilityBadgeColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(availabilityBadgeColor.opacity(0.28), lineWidth: 0.8)
                        )
                        .cornerRadius(4)
                }

                if codexHookInstaller.state.needsAction {
                    Text(L.codexHookSetupBadge)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(CodexStatusPalette.warning.opacity(0.16))
                        .foregroundColor(CodexStatusPalette.warning)
                        .cornerRadius(4)
                }

                Spacer()

                if let refreshStatusText {
                    Text(refreshStatusText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isRefreshing ? .secondary : CodexStatusPalette.ok)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }

                Button {
                    Task { await refresh() }
                } label: {
                    RefreshIconView(
                        isRefreshing: isRefreshing,
                        size: 18,
                        fontSize: 13,
                        weight: .medium
                    )
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(refreshHelpText)
                .disabled(isRefreshing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.16), value: refreshStatusText)

            CodexResetWindowTipView()

            if appUpdater.shouldShowUpdateRow {
                Divider()

                AppUpdateRow(updater: appUpdater)
            }

            Divider()

            CodexRadarView()

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
                    .focusable(false)
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
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 8) {
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
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 12))
                        .frame(width: 18, height: 18, alignment: .center)
                }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(L.addAccount)

                    Button {
                        importAccounts()
                    } label: {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 12))
                            .frame(width: 18, height: 18, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(L.importAccount)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        refreshFrequency.cycle()
                        lastVisibleRefresh = .distantPast
                    } label: {
                        HStack(alignment: .center, spacing: 2) {
                            Image(systemName: "timer")
                                .font(.system(size: 11))
                            Text(refreshFrequency.buttonLabel)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(height: 18, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(refreshFrequency.helpText)

                    Button {
                        quotaDisplay.toggleAmountMode()
                    } label: {
                        Text(quotaDisplay.amountMode.shortLabel)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(height: 18, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(quotaDisplay.amountHelpText)

                    Button {
                        quotaDisplay.toggle()
                    } label: {
                        Text(quotaDisplay.mode.shortLabel)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(height: 18, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(quotaDisplay.displayHelpText)

                    Button {
                        quotaDisplay.toggleStatusLights()
                    } label: {
                        StatusLightsToggleIcon(isOn: quotaDisplay.showStatusLights)
                            .frame(width: 22, height: 18, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(quotaDisplay.statusLightsHelpText)

                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        Task { await appUpdater.checkForUpdates(silent: false) }
                    } label: {
                        Image(systemName: appUpdater.hasAvailableUpdate ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                            .frame(width: 18, height: 18, alignment: .center)
                            .foregroundColor(appUpdater.hasAvailableUpdate ? CodexStatusPalette.warning : .primary)
                            .background(
                                Circle()
                                    .fill(appUpdater.hasAvailableUpdate ? CodexStatusPalette.warning.opacity(0.16) : Color.clear)
                            )
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .disabled(appUpdater.isWorking)
                    .help(L.checkForUpdates)

                    Button {
                        language.cycle()
                    } label: {
                        Text(language.buttonLabel)
                            .font(.system(size: 10, weight: .medium))
                            .frame(height: 18, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(language.switchLanguageHelp)

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 12))
                            .frame(width: 18, height: 18, alignment: .center)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(L.quit)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
            Task { await appUpdater.checkForUpdates(silent: true) }
        }
        .onDisappear {
            menuVisible = false
            refreshFeedbackHideTask?.cancel()
            refreshFeedbackHideTask = nil
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
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
        let accountIDs = Set(store.accounts.map(\.id))
        refreshFeedbackHideTask?.cancel()
        refreshFeedbackHideTask = nil
        showRefreshCompleted = false
        isRefreshing = true
        refreshingAccounts.formUnion(accountIDs)

        async let radarRefresh: Void = CodexRadarService.shared.refresh()
        async let updateCheck: Void = appUpdater.checkForUpdates(silent: true)
        await RefreshService.shared.refreshExpiring(store: store)
        await WhamService.shared.refreshAll(store: store)
        await radarRefresh
        await updateCheck
        lastVisibleRefresh = Date()
        TokenStatsService.shared.refresh()
        isRefreshing = false
        refreshingAccounts.subtract(accountIDs)
        showRefreshCompleted = true
        refreshFeedbackHideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showRefreshCompleted = false
                refreshFeedbackHideTask = nil
            }
        }
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
        let accountID = account.id
        refreshingAccounts.insert(accountID)
        defer { refreshingAccounts.remove(accountID) }

        RefreshService.shared.syncActiveFromAuthJson(store: store)
        var target = latestAccount(matching: account)
        if RefreshService.shared.needsRefresh(target) {
            _ = await RefreshService.shared.refreshAndPersist(target, store: store)
            target = latestAccount(matching: target)
        }
        await WhamService.shared.refreshOne(account: target, store: store)
    }

    private func latestAccount(matching account: TokenAccount) -> TokenAccount {
        store.accounts.first { $0.accountId == account.accountId } ?? account
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

private struct AppUpdateRow: View {
    @ObservedObject var updater: AppUpdateService

    private var iconName: String {
        switch updater.state {
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .available:
            return "arrow.down.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .installing:
            return "shippingbox.circle.fill"
        case .upToDate:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var iconColor: Color {
        switch updater.state {
        case .available:
            return CodexStatusPalette.warning
        case .downloading, .checking, .installing:
            return .secondary
        case .upToDate:
            return CodexStatusPalette.ok
        case .failed:
            return CodexStatusPalette.warning
        case .idle:
            return .secondary
        }
    }

    private var title: String {
        switch updater.state {
        case .checking:
            return L.updateChecking
        case .available(let release):
            return L.updateAvailableTitle(release.tagName)
        case .downloading:
            return L.updateDownloading
        case .installing:
            return L.updateInstalling
        case .upToDate:
            return L.updateUpToDate
        case .failed:
            return L.updateFailedTitle
        case .idle:
            return L.checkForUpdates
        }
    }

    private var detail: String {
        switch updater.state {
        case .available(let release):
            return L.updateAvailableDetail(release.displayName, formattedSize(release.assetSize))
        case .downloading(let release):
            return L.updateDownloadingDetail(Int(updater.downloadProgress * 100), formattedSize(release.assetSize))
        case .installing:
            return L.updateInstallingDetail
        case .failed(let message):
            return message
        case .checking:
            return L.updateCheckingDetail
        case .upToDate:
            return L.updateUpToDateDetail
        case .idle:
            return ""
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .downloading = updater.state {
                    ProgressView(value: updater.downloadProgress)
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 6)

            if showsPrimaryButton {
                Button(action: primaryAction) {
                    Text(primaryButtonTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(primaryButtonForeground)
                        .padding(.horizontal, 8)
                        .frame(height: 20, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(primaryButtonBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(primaryButtonBorder, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.borderless)
                .focusable(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var showsPrimaryButton: Bool {
        switch updater.state {
        case .available, .failed:
            return true
        case .idle, .checking, .upToDate, .downloading, .installing:
            return false
        }
    }

    private var primaryButtonTitle: String {
        if case .failed = updater.state {
            return L.retry
        }
        return L.updateNow
    }

    private var primaryButtonBackground: Color {
        if case .available = updater.state {
            return CodexStatusPalette.warning
        }
        return CodexStatusPalette.warning.opacity(0.16)
    }

    private var primaryButtonForeground: Color {
        if case .available = updater.state {
            return .white
        }
        return CodexStatusPalette.warning
    }

    private var primaryButtonBorder: Color {
        if case .available = updater.state {
            return CodexStatusPalette.warning.opacity(0.45)
        }
        return CodexStatusPalette.warning.opacity(0.28)
    }

    private func primaryAction() {
        if case .available = updater.state {
            let alert = NSAlert()
            alert.messageText = L.updateConfirmTitle
            alert.informativeText = L.updateConfirmInfo
            alert.addButton(withTitle: L.updateConfirmButton)
            alert.addButton(withTitle: L.cancel)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        Task {
            await updater.downloadAndInstallLatest()
        }
    }

    private func formattedSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct StatusLightsToggleIcon: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 2.2) {
            light(.red, active: isOn)
            light(.yellow, active: isOn)
            light(.green, active: isOn)
        }
        .opacity(isOn ? 1 : 0.45)
    }

    private func light(_ color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : Color.secondary.opacity(0.45))
            .frame(width: 5.2, height: 5.2)
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
            .focusable(false)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
