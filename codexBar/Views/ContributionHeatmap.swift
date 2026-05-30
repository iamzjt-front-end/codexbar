import SwiftUI

/// GitHub 风格贡献热力图：展示最近 N 周每天的 token 用量，绿点深浅按对数档位。
struct ContributionHeatmap: View {
    let daily: [String: Int]   // "yyyy-MM-dd" -> tokens
    var weeks: Int = 16

    // GitHub 风格正方形小格子
    private let cellW: CGFloat = 9
    private let cellH: CGFloat = 9
    private let gap: CGFloat = 3

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 网格起点：今天所在周的周一，往回推 weeks-1 周
    private var columns: [[Date]] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // 周一
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let offsetToMon = ((weekday - cal.firstWeekday) + 7) % 7
        guard let thisMon = cal.date(byAdding: .day, value: -offsetToMon, to: today),
              let start = cal.date(byAdding: .day, value: -(weeks - 1) * 7, to: thisMon) else { return [] }

        var cols: [[Date]] = []
        for w in 0..<weeks {
            var col: [Date] = []
            for d in 0..<7 {
                if let day = cal.date(byAdding: .day, value: w * 7 + d, to: start) {
                    col.append(day)
                }
            }
            cols.append(col)
        }
        return cols
    }

    /// 对数档位 0...4
    private func level(_ tokens: Int) -> Int {
        switch tokens {
        case 0: return 0
        case 1..<10_000_000: return 1          // <10M
        case 10_000_000..<100_000_000: return 2 // 10M-100M
        case 100_000_000..<1_000_000_000: return 3 // 100M-1B
        default: return 4                       // >=1B
        }
    }

    /// GitHub 经典 5 档实色梯度（深浅分明，不靠 opacity）
    private func color(_ lvl: Int) -> Color {
        switch lvl {
        case 0: return Color.primary.opacity(0.08) // 空：随深浅主题自适应的低透明度
        case 1: return Color(red: 0.62, green: 0.78, blue: 0.65) // 柔和浅绿
        case 2: return Color(red: 0.42, green: 0.66, blue: 0.48) // 柔和中绿
        case 3: return Color(red: 0.28, green: 0.52, blue: 0.36) // 柔和深绿
        default: return Color(red: 0.18, green: 0.38, blue: 0.26) // 柔和最深绿
        }
    }

    var body: some View {
        let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                VStack(spacing: gap) {
                    ForEach(col, id: \.self) { day in
                        let key = Self.fmt.string(from: day)
                        let tok = daily[key] ?? 0
                        let future = day > today
                        RoundedRectangle(cornerRadius: 2)
                            .fill(future ? Color.clear : color(level(tok)))
                            .frame(width: cellW, height: cellH)
                    }
                }
            }
        }
    }
}
