import SwiftUI

@main
struct codexBarApp: App {
    @StateObject private var store = TokenStore.shared
    @StateObject private var oauth = OAuthManager.shared
    @StateObject private var language = LanguageSettings.shared
    @StateObject private var refreshFrequency = RefreshFrequencySettings.shared

    init() {
        // App 级后台续期，脱离菜单 View 生命周期（菜单关闭时 View 不存在，其内 Timer 不跑）
        BackgroundRefresher.shared.start(interval: RefreshFrequencySettings.shared.selection.backgroundInterval)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(oauth)
                .environmentObject(language)
                .environmentObject(refreshFrequency)
        } label: {
            MenuBarIconView(store: store)
                .environmentObject(language)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏图标：显示 terminal 图标 + 活跃账号的 5h / 周额度
struct MenuBarIconView: View {
    @ObservedObject var store: TokenStore
    @EnvironmentObject var language: LanguageSettings

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
            if let active = store.accounts.first(where: { $0.isActive }) {
                if active.secondaryExhausted {
                    Text(L.weeklyLimit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                } else if active.primaryExhausted {
                    Text(L.hourLimit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                } else {
                    Text("\(Int(active.primaryUsedPercent))%·\(Int(active.secondaryUsedPercent))%")
                        .font(.system(size: 10, weight: .medium))
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: active.primaryUsedPercent)
                }
            }
        }
        .id(language.identity)
    }

    private var iconName: String {
        // 优先以活跃账号状态决定图标；无活跃账号才看全部
        let ref: [TokenAccount]
        if let active = store.accounts.first(where: { $0.isActive }) {
            ref = [active]
        } else {
            ref = store.accounts
        }
        if ref.contains(where: { $0.isBanned }) {
            return "xmark.circle.fill"
        }
        if ref.contains(where: { $0.secondaryExhausted }) {
            return "exclamationmark.triangle.fill"
        }
        if ref.contains(where: { $0.quotaExhausted || $0.primaryUsedPercent >= 80 || $0.secondaryUsedPercent >= 80 }) {
            return "bolt.circle.fill"
        }
        return "terminal.fill"
    }
}
