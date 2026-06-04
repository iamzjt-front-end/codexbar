import Foundation
import Combine

enum TokenStatsRange: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return L.tokenRangeToday
        case .week:  return L.tokenRangeWeek
        case .month: return L.tokenRangeMonth
        }
    }

    /// 区间起点（含）：today=今天0点，week=本周一0点，month=本月1号0点
    var since: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // 周一
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        switch self {
        case .today:
            return dayStart
        case .week:
            let weekday = cal.component(.weekday, from: dayStart) // 1=Sun..7=Sat
            let offset = ((weekday - cal.firstWeekday) + 7) % 7
            return cal.date(byAdding: .day, value: -offset, to: dayStart) ?? dayStart
        case .month:
            let comps = cal.dateComponents([.year, .month], from: dayStart)
            return cal.date(from: comps) ?? dayStart
        }
    }
}

@MainActor
final class TokenStatsService: ObservableObject {
    static let shared = TokenStatsService()
    private init() {}

    @Published var range: TokenStatsRange = .today
    @Published var stat = CodexStatsDB.WindowStat()
    @Published var daily: [String: Int] = [:]   // 热力图：近 16 周每日 token
    @Published var loading = false

    private var currentTask: Task<Void, Never>?

    func switchTo(_ r: TokenStatsRange) {
        guard r != range else { return }
        range = r
        refresh()
    }

    func refresh() {
        currentTask?.cancel()
        let since = range.since
        let r = range
        // 热力图固定窗口：近 ~17 周
        let heatSince = Calendar(identifier: .gregorian).date(byAdding: .day, value: -119, to: Date()) ?? since
        loading = true
        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            let s = CodexStatsDB.stat(since: since)
            let d = CodexStatsDB.dailyTokens(since: heatSince)
            await MainActor.run {
                guard let self else { return }
                if self.range == r {
                    self.stat = s
                    self.daily = d
                    self.loading = false
                }
            }
        }
    }
}
