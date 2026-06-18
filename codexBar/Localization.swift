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
    static var addAccountHint: String  { zh ? "点击下方授权账号"      : "Authorize an account below" }
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
    static var statusLightsVisible: String { zh ? "显示" : "Shown" }
    static var statusLightsHidden: String { zh ? "隐藏" : "Hidden" }
    static func statusLightsDisplayHelp(_ detail: String) -> String {
        zh ? "顶部红绿灯：\(detail)" : "Menu bar status lights: \(detail)"
    }
    static var resetCreditsAvailable: String { zh ? "可用重置次数" : "Available resets" }
    static func resetCreditsCount(_ n: Int) -> String {
        if zh { return "\(n) 次" }
        return n == 1 ? "1 reset" : "\(n) resets"
    }
    static var resetCreditsUnknown: String { "--" }
    static var resetCreditsHelp: String {
        zh
            ? "官方 banked Codex rate-limit reset 次数；当前接口通常只返回数量，若返回过期时间会在临近 3 天时提示。"
            : "Official banked Codex rate-limit resets. The current endpoint usually returns only the count; if an expiration is returned, a 3-day warning appears."
    }
    static func resetCreditsExpireSoon(_ time: String) -> String {
        zh ? "重置机会即将过期：\(time)" : "Reset credits expire soon: \(time)"
    }
    static var resetCreditsExpireSoonHelp: String {
        zh ? "官方返回了重置机会过期时间，距离过期不足 3 天。" : "The official response includes a reset-credit expiration less than 3 days away."
    }
    static func resetCreditsExpireInMinutes(_ minutes: Int) -> String {
        zh ? "\(minutes) 分钟内" : "in \(minutes) min"
    }
    static func resetCreditsExpireInHours(_ hours: Int) -> String {
        zh ? "\(hours) 小时内" : "in \(hours) hr"
    }
    static func resetCreditsExpireInDays(_ days: Int) -> String {
        zh ? "\(days) 天内" : "in \(days) day\(days == 1 ? "" : "s")"
    }
    static var addAccount: String      { zh ? "授权账号"            : "Authorize Account" }
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
    static var refreshing: String      { zh ? "刷新中"              : "Refreshing" }
    static var refreshed: String       { zh ? "已刷新"              : "Refreshed" }
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
    static var checkForUpdates: String  { zh ? "检查更新" : "Check for Updates" }
    static var retry: String            { zh ? "重试" : "Retry" }
    static var updateNow: String        { zh ? "更新" : "Update" }
    static var updateChecking: String   { zh ? "正在检查更新" : "Checking for updates" }
    static var updateCheckingDetail: String {
        zh ? "正在读取 GitHub 最新 release。" : "Reading the latest GitHub release."
    }
    static func updateAvailableTitle(_ version: String) -> String {
        zh ? "发现新版本 \(version)" : "Update available \(version)"
    }
    static func updateAvailableDetail(_ name: String, _ size: String) -> String {
        zh ? "\(name) · \(size)，点击后会自动下载并重启更新。" : "\(name) · \(size). Click to download and relaunch."
    }
    static var updateDownloading: String { zh ? "正在下载更新" : "Downloading update" }
    static func updateDownloadingDetail(_ percent: Int, _ size: String) -> String {
        zh ? "\(percent)% · \(size)" : "\(percent)% · \(size)"
    }
    static var updateInstalling: String { zh ? "正在安装更新" : "Installing update" }
    static var updateInstallingDetail: String {
        zh ? "CodexAppBar 将自动退出并重新打开。" : "CodexAppBar will quit and reopen automatically."
    }
    static var updateConfirmTitle: String {
        zh ? "更新 CodexAppBar？" : "Update CodexAppBar?"
    }
    static var updateConfirmInfo: String {
        zh
            ? "更新需要下载新版本、退出当前 CodexAppBar，替换 App 后会自动重新打开。是否继续？"
            : "The update will download the new version, quit CodexAppBar, replace the app, and reopen automatically. Continue?"
    }
    static var updateConfirmButton: String { zh ? "下载并更新" : "Download & Update" }
    static var updateUpToDate: String { zh ? "已是最新版本" : "Already up to date" }
    static var updateUpToDateDetail: String {
        zh ? "当前安装版本已匹配 GitHub 最新 release。" : "The installed build matches the latest GitHub release."
    }
    static var updateFailedTitle: String { zh ? "更新失败" : "Update failed" }
    static var updateNotificationTitle: String {
        zh ? "CodexAppBar 有新版本" : "CodexAppBar update available"
    }
    static func updateNotificationBody(_ name: String) -> String {
        zh ? "\(name) 已发布，打开菜单即可更新。" : "\(name) is available. Open the menu to update."
    }
    static var updateErrorInvalidResponse: String {
        zh ? "GitHub 返回内容不可识别" : "GitHub returned an unrecognized response"
    }
    static func updateErrorBadStatus(_ status: Int) -> String {
        zh ? "GitHub 请求失败：HTTP \(status)" : "GitHub request failed: HTTP \(status)"
    }
    static var updateErrorNoAsset: String {
        zh ? "最新 release 中没有可安装的 codexAppBar zip" : "The latest release has no installable codexAppBar zip"
    }
    static var updateErrorDownloadMissingFile: String {
        zh ? "下载完成但找不到临时文件" : "Download finished but the temporary file is missing"
    }
    static var updateErrorDigestMismatch: String {
        zh ? "下载包 SHA-256 校验不一致" : "Downloaded package SHA-256 did not match"
    }
    static var updateErrorAppNotFound: String {
        zh ? "压缩包中没有找到 codexAppBar.app" : "Could not find codexAppBar.app in the archive"
    }
    static var updateErrorBundleIdentifierMismatch: String {
        zh ? "下载的 App 标识与当前 App 不一致" : "Downloaded app identifier does not match this app"
    }
    static var updateErrorStagedVersionMismatch: String {
        zh ? "下载的 App 版本号不匹配" : "Downloaded app build version does not match the release"
    }
    static var updateErrorTranslocated: String {
        zh ? "当前 App 仍在 macOS 随机转移路径中运行，请先移动到 Applications 后再更新" : "The app is running from a macOS translocation path. Move it to Applications first."
    }
    static func updateErrorInstallLocationNotWritable(_ path: String) -> String {
        zh ? "无法写入安装目录：\(path)" : "Cannot write to install location: \(path)"
    }
    static func updateErrorToolFailed(_ message: String) -> String {
        zh ? "更新工具执行失败：\(message)" : "Update tool failed: \(message)"
    }
    static func updateErrorInstallerLaunchFailed(_ reason: String) -> String {
        zh ? "无法启动安装器：\(reason)" : "Could not launch installer: \(reason)"
    }

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

    // MARK: - CodexRadar
    static func codexResetWindowOpen(_ resetTime: String) -> String {
        zh ? "速蹬窗口已开启，预计于 \(resetTime) 重置" : "Speedrun window is open, expected to reset at \(resetTime)"
    }
    static var codexResetWindowFallback: String { zh ? "速蹬窗口已开启" : "Speedrun window is open" }
    static var codexResetWindowSourceHelp: String { zh ? "打开官方证据" : "Open official source" }
    static var modelQualityTitle: String { zh ? "模型质量" : "Model Quality" }
    static var modelQualityRefreshHelp: String { zh ? "刷新模型质量" : "Refresh model quality" }
    static var modelQualityOpenHelp: String { zh ? "打开 CodexRadar" : "Open CodexRadar" }
    static var modelQualityBenchmarkNote: String {
        zh ? "固定 DeepSWE 任务集，分数越高越好" : "Fixed DeepSWE benchmark, higher is better"
    }
    static func modelQualityPassLine(date: String, passed: String, tasks: String, baseline: String) -> String {
        if zh {
            return "\(date) \(passed)/\(tasks) 通过，基线 \(baseline)/\(tasks)"
        }
        return "\(date) \(passed)/\(tasks) passed, baseline \(baseline)/\(tasks)"
    }
    static var modelQualityMetricCost: String { zh ? "费用" : "Cost" }
    static var modelQualityMetricTime: String { zh ? "耗时" : "Time" }
    static var modelQualityMetricCache: String { zh ? "缓存" : "Cache" }
    static var modelQualityMetricTokens: String { zh ? "Tokens" : "Tokens" }
    static var modelQualityReading: String { zh ? "正在读取 codexradar.com" : "Reading codexradar.com" }
    static var modelQualityNoData: String { zh ? "暂无模型质量数据" : "No model quality data" }
}
