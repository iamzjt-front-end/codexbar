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
            ? "官方 banked Codex rate-limit reset 次数；会额外查询重置机会到期时间，临近 3 天时提示。"
            : "Official banked Codex rate-limit resets. The app also checks reset-credit expiration and warns within 3 days."
    }
    static func resetCreditsExpiresAt(_ time: String) -> String {
        zh ? "重置机会到期：\(time)" : "Reset credits expire: \(time)"
    }
    static var resetCreditsExpiresAtHelp: String {
        zh ? "官方重置机会到期时间。" : "Official reset-credit expiration time."
    }
    static var addAccount: String      { zh ? "授权账号"            : "Authorize Account" }
    static var importAccount: String   { zh ? "导入账号 JSON"       : "Import Accounts JSON" }
    static func importedCount(_ n: Int) -> String {
        zh ? "已导入 \(n) 个账号" : "Imported \(n) account(s)"
    }
    static var quit: String            { zh ? "退出"               : "Quit" }
    static var cancel: String          { zh ? "取消"               : "Cancel" }
    static var justUpdated: String     { zh ? "刚刚更新"            : "Just updated" }
    static var refreshing: String      { zh ? "刷新中"              : "Refreshing" }
    static var refreshed: String       { zh ? "已刷新"              : "Refreshed" }
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
    static var later: String            { zh ? "稍后" : "Later" }
    static var checkForUpdates: String  { zh ? "检查更新" : "Check for Updates" }
    static var retry: String            { zh ? "重试" : "Retry" }
    static var downloadUpdate: String   { zh ? "下载" : "Download" }
    static var installUpdateNow: String { zh ? "现在更新" : "Update Now" }
    static var updateChecking: String   { zh ? "正在检查更新" : "Checking for updates" }
    static var updateCheckingDetail: String {
        zh ? "正在读取 GitHub 最新 release。" : "Reading the latest GitHub release."
    }
    static func updateAvailableTitle(_ version: String) -> String {
        zh ? "发现新版本 \(version)" : "Update available \(version)"
    }
    static func updateAvailableDetail(_ name: String, _ size: String) -> String {
        zh ? "\(name) · \(size)，点击后先下载，下载完成后再确认是否安装。" : "\(name) · \(size). Download first, then choose whether to install."
    }
    static var updateDownloading: String { zh ? "正在下载更新" : "Downloading update" }
    static func updateDownloadingDetail(_ percent: Int, _ size: String) -> String {
        zh ? "\(percent)% · \(size)" : "\(percent)% · \(size)"
    }
    static var updateReadyToInstall: String { zh ? "更新已下载" : "Update downloaded" }
    static func updateReadyToInstallDetail(_ name: String) -> String {
        zh ? "\(name) 已准备好。现在更新会退出并重新打开 CodexAppBar。" : "\(name) is ready. Updating now will quit and reopen CodexAppBar."
    }
    static var updateInstalling: String { zh ? "正在安装更新" : "Installing update" }
    static var updateInstallingDetail: String {
        zh ? "CodexAppBar 将自动退出并重新打开。" : "CodexAppBar will quit and reopen automatically."
    }
    static var updateInstallConfirmTitle: String {
        zh ? "现在安装更新？" : "Install update now?"
    }
    static var updateInstallConfirmInfo: String {
        zh
            ? "下载已完成。安装会退出当前 CodexAppBar，替换 App 后自动重新打开。"
            : "The download is complete. Installing will quit CodexAppBar, replace the app, and reopen automatically."
    }
    static var updateInstallConfirmButton: String { zh ? "安装并重启" : "Install & Relaunch" }
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
    static func updateInstalledTitle(_ version: String) -> String {
        zh ? "已更新到 \(version)" : "Updated to \(version)"
    }
    static func updateInstalledDetail(_ currentVersion: String) -> String {
        zh ? "当前运行版本：\(currentVersion)" : "Current running version: \(currentVersion)"
    }
    static var dismissUpdateInstalled: String {
        zh ? "关闭更新完成提示" : "Dismiss update completed"
    }
    static var updateInstalledNotificationTitle: String {
        zh ? "CodexAppBar 已更新" : "CodexAppBar updated"
    }
    static func updateInstalledNotificationBody(_ version: String) -> String {
        zh ? "已成功更新到 \(version)。" : "Successfully updated to \(version)."
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
    // MARK: - AccountRowView
    static var reauth: String          { zh ? "重新授权"     : "Re-authorize" }
    static var switchBtn: String       { zh ? "切换"         : "Switch" }
    static func confirmDelete(_ name: String) -> String {
        zh ? "确认删除 \(name)？" : "Delete \(name)?"
    }
    static var delete: String         { zh ? "删除"     : "Delete" }
    static var tokenExpiredHint: String { zh ? "Token 已过期，请重新授权" : "Token expired, please re-authorize" }
    static var accountSuspended: String { zh ? "账号已停用" : "Account suspended" }

    // MARK: - Reset countdown
    static var resetSoon: String { zh ? "即将重置" : "Resetting soon" }
    static func resetAtDate(_ dateTime: String) -> String {
        zh ? "\(dateTime) 重置" : "Resets \(dateTime)"
    }

    // MARK: - Token stats
    static var tokenRangeToday: String { zh ? "今日" : "Today" }
    static var tokenRangeWeek: String  { zh ? "本周" : "This Week" }
    static var tokenRangeMonth: String { zh ? "本月" : "This Month" }
    static var tokenTotal: String      { zh ? "Token 用量" : "Tokens Used" }
    static func tokenThreadCount(_ n: Int) -> String {
        zh ? "\(n) 个会话" : "\(n) threads"
    }

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
    static var modelQualityReading: String { zh ? "正在读取 codexradar.com" : "Reading codexradar.com" }
    static var modelQualityNoData: String { zh ? "暂无模型质量数据" : "No model quality data" }
}
