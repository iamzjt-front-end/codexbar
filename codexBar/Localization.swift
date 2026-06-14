import Combine
import Foundation

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    @Published private(set) var override: Bool

    private init() {
        override = L.languageOverride ?? L.systemIsChinese
        L.languageOverride = override
    }

    var identity: String {
        override ? "zh" : "en"
    }

    var buttonLabel: String {
        override ? "中" : "EN"
    }

    var switchLanguageHelp: String {
        L.zh ? "切换语言" : "Switch Language"
    }

    func cycle() {
        override.toggle()
        L.languageOverride = override
    }
}

/// Bilingual string helper — detects system language at runtime, with user override.
enum L {
    /// nil only appears for legacy preferences; UI always stores a concrete language.
    static var languageOverride: Bool? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "languageOverride") != nil else { return nil }
            return d.bool(forKey: "languageOverride")
        }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "languageOverride")
            } else {
                UserDefaults.standard.removeObject(forKey: "languageOverride")
            }
        }
    }

    static var zh: Bool {
        if let override = languageOverride { return override }
        return systemIsChinese
    }

    static var systemIsChinese: Bool {
        let lang = Locale.current.language.languageCode?.identifier ?? ""
        return lang.hasPrefix("zh")
    }

    // MARK: - Status Bar
    static var weeklyLimit: String { zh ? "周限额" : "Weekly Limit" }
    static var hourLimit: String   { zh ? "5h限额" : "5h Limit" }
    static var codexSessionOffline: String { zh ? "Codex 未连接" : "Codex offline" }
    static var codexSessionReady: String { zh ? "Codex 已就绪" : "Codex ready" }
    static var codexSessionRunningGeneric: String { zh ? "Codex 正在运行" : "Codex running" }
    static func codexSessionRunning(_ phase: String) -> String {
        zh ? "Codex 正在\(phase)" : "Codex running: \(phase)"
    }
    static var codexSessionNeedsAttention: String { zh ? "Codex 需要处理" : "Codex needs attention" }
    static var codexSessionStatusUnreadable: String { zh ? "状态不可读取" : "Status unreadable" }
    static var codexSessionStatusStale: String { zh ? "状态已过期" : "Status stale" }
    static var codexHookTooltipNeedsInstall: String {
        zh ? "需要安装并信任 Codex 钩子，红绿灯才能显示当前会话状态" : "Install and trust Codex hooks to show live conversation status"
    }
    static var codexHookSetupBadge: String { zh ? "钩子未装" : "Hooks" }
    static var codexHookSetupTitle: String {
        zh ? "安装并信任 Codex 钩子" : "Install and trust Codex hooks"
    }
    static var codexHookUpdateTitle: String {
        zh ? "更新 Codex 钩子" : "Update Codex hooks"
    }
    static var codexHookErrorTitle: String {
        zh ? "Codex 钩子配置异常" : "Codex hook config issue"
    }
    static var codexHookSetupDetail: String {
        zh
            ? "红绿灯需要通过 Codex hooks 获取当前会话的运行、就绪和权限状态。安装后，Codex 提示时请信任这个 hook。"
            : "Traffic lights use Codex hooks to read running, ready, and permission states. After installing, trust this hook when Codex asks."
    }
    static var codexHookInstallButton: String { zh ? "安装钩子" : "Install Hooks" }
    static var codexHookUpdateButton: String { zh ? "更新钩子" : "Update Hooks" }
    static var codexHookInstallConfirmTitle: String {
        zh ? "安装 CodexAppBar 钩子？" : "Install CodexAppBar hooks?"
    }
    static func codexHookInstallConfirmInfo(_ path: String) -> String {
        zh
            ? "将备份并合并写入 \(path)。Codex 下次提示信任 hook 时，请选择信任。"
            : "This will back up and merge changes into \(path). When Codex asks to trust the hook, choose trust."
    }
    static var codexHookInstallConfirmButton: String { zh ? "安装" : "Install" }
    static var codexHookInstallSuccess: String {
        zh ? "Codex 钩子已安装；Codex 提示时请信任 hook" : "Codex hooks installed; trust the hook when Codex asks"
    }
    static func codexHookInstallFailed(_ reason: String) -> String {
        zh ? "Codex 钩子安装失败：\(reason)" : "Failed to install Codex hooks: \(reason)"
    }
    static var codexHookScriptMissing: String {
        zh ? "找不到随 App 打包的 hook 脚本" : "Bundled hook script is missing"
    }
    static var codexHookInvalidConfig: String {
        zh ? "hooks.json 不是有效的对象格式" : "hooks.json is not a valid object"
    }

    // MARK: - MenuBarView
    static var noAccounts: String      { zh ? "还没有账号"          : "No Accounts" }
    static var addAccountHint: String  { zh ? "点击下方 + 添加账号"   : "Tap + below to add an account" }
    static var refreshUsage: String    { zh ? "刷新用量"            : "Refresh Usage" }
    static func refreshFrequencyHelp(_ detail: String) -> String {
        zh ? "额度刷新频率：\(detail)" : "Quota refresh frequency: \(detail)"
    }
    static var quotaDisplayNumbers: String { zh ? "数字" : "Numbers" }
    static var quotaDisplayBars: String { zh ? "进度条" : "Bars" }
    static var quotaDisplayNumbersShort: String { zh ? "数字" : "123" }
    static var quotaDisplayBarsShort: String { zh ? "进度" : "Bars" }
    static func quotaDisplayModeHelp(_ detail: String) -> String {
        zh ? "顶部额度展示：\(detail)" : "Menu bar quota display: \(detail)"
    }
    static var quotaAmountUsed: String { zh ? "已用额度" : "Used quota" }
    static var quotaAmountRemaining: String { zh ? "剩余额度" : "Remaining quota" }
    static var quotaAmountUsedShort: String { zh ? "已用" : "Used" }
    static var quotaAmountRemainingShort: String { zh ? "剩余" : "Left" }
    static func quotaAmountModeHelp(_ detail: String) -> String {
        zh ? "额度口径：\(detail)" : "Quota metric: \(detail)"
    }
    static var resetTimeDisplayAlways: String { zh ? "始终" : "Always" }
    static var resetTimeDisplayNearLimit: String { zh ? "临近时" : "Near limit" }
    static var alwaysShowResetTime: String { zh ? "始终显示重置时间" : "Always show reset time" }
    static func resetTimeDisplayHelp(_ detail: String) -> String {
        zh ? "重置时间：\(detail)" : "Reset time: \(detail)"
    }
    static var resetCreditsAvailable: String { zh ? "可用重置次数" : "Available resets" }
    static func resetCreditsCount(_ n: Int) -> String {
        if zh { return "\(n) 次" }
        return n == 1 ? "1 reset" : "\(n) resets"
    }
    static var resetCreditsUnknown: String { "--" }
    static var resetCreditsHelp: String {
        zh
            ? "官方 banked Codex rate-limit reset 次数；邀请奖励到账后会增加。"
            : "Official banked Codex rate-limit resets. Successful referral rewards add to this count."
    }
    static var addAccount: String      { zh ? "添加账号"            : "Add Account" }
    static var importAccount: String   { zh ? "导入账号 JSON"       : "Import Accounts JSON" }
    static func importedCount(_ n: Int) -> String {
        zh ? "已导入 \(n) 个账号" : "Imported \(n) account(s)"
    }
    static var quit: String            { zh ? "退出"               : "Quit" }
    static var switchAccount: String    { zh ? "切换账号"            : "Switch Account" }
    static var switchTitle: String     { zh ? "切换账号"            : "Switch Account" }
    static var continueRestart: String { zh ? "继续"               : "Continue" }
    static var cancel: String          { zh ? "取消"               : "Cancel" }
    static var justUpdated: String     { zh ? "刚刚更新"            : "Just updated" }
    static var restartCodexTitle: String {
        zh ? "切换账号需要重启 Codex" : "Switching Account Requires Restarting Codex"
    }
    static var restartCodexInfo: String {
        zh
            ? "切换账号需要关闭并重新打开 Codex.app 才能生效。是否继续？"
            : "Switching account requires quitting and reopening Codex.app to take effect. Continue?"
    }
    static var switchModeTitle: String {
        zh ? "选择切换方式" : "Choose How to Switch"
    }
    static var switchModeInfo: String {
        zh
            ? "「仅切换」只写入账号，不退出 Codex（不中断任务，但需 Codex 下次重新读取才生效）。\n「切换并重启」会强制退出并重开 Codex 立即生效（会中断进行中的任务）。"
            : "\"Switch Only\" writes the account without quitting Codex (no task interruption, but takes effect only when Codex re-reads auth).\n\"Switch & Restart\" force-quits and reopens Codex for immediate effect (interrupts running tasks)."
    }
    static var switchOnly: String      { zh ? "仅切换（不退出）" : "Switch Only" }
    static var switchAndRestart: String { zh ? "切换并重启 Codex" : "Switch & Restart" }
    static var cannotActivateNoIdToken: String {
        zh ? "该账号缺少 id_token 且无法续期，请重新授权后再激活" : "This account has no id_token and could not refresh; re-authorize before activating"
    }
    static var forceQuitAndReopen: String { zh ? "强制退出并重新打开" : "Force Quit & Reopen" }
    static var forceQuitOnly: String    { zh ? "仅强制退出" : "Force Quit Only" }
    static var restartLater: String     { zh ? "稍后手动重启" : "Later" }

    static func available(_ n: Int, _ total: Int) -> String {
        zh ? "\(n)/\(total) 可用" : "\(n)/\(total) Available"
    }
    static func minutesAgo(_ m: Int) -> String {
        zh ? "\(m) 分钟前更新" : "Updated \(m) min ago"
    }
    static func hoursAgo(_ h: Int) -> String {
        zh ? "\(h) 小时前更新" : "Updated \(h) hr ago"
    }
    static var switchWarningTitle: String {
        zh ? "⚠️ 实验性功能 — 账号切换" : "⚠️ Experimental — Account Switch"
    }
    static func switchConfirm(_ name: String) -> String { switchWarning(name) }
    static func switchConfirmMsg(_ name: String) -> String { switchWarning(name) }
    static func switchWarning(_ name: String) -> String {
        zh
            ? "⚠️ 实验性功能\n\n将切换到「\(name)」。\n\n此功能通过直接修改配置文件实现辅助切换，需要退出整个 Codex.app 才能生效。退出过程中可能导致数据丢失！\n\n如果你正在使用 subagent，强烈建议通过软件内的退出登录功能重新登录其他账号，而非使用此切换方案。"
            : "⚠️ Experimental Feature\n\nSwitching to \"\(name)\".\n\nThis feature works by modifying the config file directly. Codex.app must be fully quit to apply the change, which may cause data loss.\n\nIf you are using subagents, it is strongly recommended to log out from within Codex.app and log in with another account instead."
    }

    // MARK: - Auto switch
    static var autoSwitchTitle: String {
        zh ? "已自动切换账号" : "Account Auto-Switched"
    }
    static func autoSwitchBody(_ from: String, _ to: String) -> String {
        zh
            ? "「\(from)」额度不足，已自动切换至「\(to)」"
            : "Quota low on \"\(from)\", switched to \"\(to)\""
    }
    static var autoSwitchNoCandidates: String {
        zh
            ? "所有账号额度不足或不可用，请手动处理"
            : "All accounts are low or unavailable, please take action"
    }

    // MARK: - AccountRowView
    static var reauth: String          { zh ? "重新授权"     : "Re-authorize" }
    static var switchBtn: String       { zh ? "切换"         : "Switch" }
    static var tokenExpiredMsg: String { zh ? "Token 已过期，请重新授权" : "Token expired, please re-authorize" }
    static var bannedMsg: String       { zh ? "账号已停用"   : "Account suspended" }
    static var deleteBtn: String       { zh ? "删除"         : "Delete" }
    static var deleteConfirm: String   { zh ? "删除"         : "Delete" }

    static func deletePrompt(_ name: String) -> String {
        zh ? "确认删除 \(name)？" : "Delete \(name)?"
    }
    static func confirmDelete(_ name: String) -> String { deletePrompt(name) }
    static var delete: String         { zh ? "删除"     : "Delete" }
    static var tokenExpiredHint: String { zh ? "Token 已过期，请重新授权" : "Token expired, please re-authorize" }
    static var accountSuspended: String { zh ? "账号已停用" : "Account suspended" }
    static var weeklyExhausted: String  { zh ? "周额度耗尽" : "Weekly quota exhausted" }
    static var primaryExhausted: String { zh ? "5h 额度耗尽" : "5h quota exhausted" }

    // MARK: - TokenAccount status
    static var statusOk: String       { zh ? "正常"     : "OK" }
    static var statusWarning: String  { zh ? "即将用尽" : "Warning" }
    static var statusExceeded: String { zh ? "额度耗尽" : "Exceeded" }
    static var statusBanned: String   { zh ? "已停用"   : "Suspended" }

    // MARK: - Reset countdown
    static var resetSoon: String { zh ? "即将重置" : "Resetting soon" }
    static func resetAt(_ time: String) -> String {
        zh ? "\(time) 重置" : "Resets at \(time)"
    }
    static func resetTomorrowAt(_ time: String) -> String {
        zh ? "明天 \(time) 重置" : "Resets tomorrow at \(time)"
    }
    static func resetAtDate(_ dateTime: String) -> String {
        zh ? "\(dateTime) 重置" : "Resets \(dateTime)"
    }
    static func resetInMin(_ m: Int) -> String {
        zh ? "\(m) 分钟后重置" : "Resets in \(m) min"
    }
    static func resetInHr(_ h: Int, _ m: Int) -> String {
        zh ? "\(h) 小时 \(m) 分后重置" : "Resets in \(h)h \(m)m"
    }
    static func resetInDay(_ d: Int, _ h: Int) -> String {
        zh ? "\(d) 天 \(h) 小时后重置" : "Resets in \(d)d \(h)h"
    }

    // MARK: - Token stats
    static var tokenRangeToday: String { zh ? "今日" : "Today" }
    static var tokenRangeWeek: String  { zh ? "本周" : "This Week" }
    static var tokenRangeMonth: String { zh ? "本月" : "This Month" }
    static var tokenTotal: String      { zh ? "Token 用量" : "Tokens Used" }
    static func tokenThreadCount(_ n: Int) -> String {
        zh ? "\(n) 个会话" : "\(n) threads"
    }
    static var heatmapLess: String { zh ? "少" : "Less" }
    static var heatmapMore: String { zh ? "多" : "More" }
}
