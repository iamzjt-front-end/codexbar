import SwiftUI

/// GitHub 风格贡献热力图：展示最近 N 周每天的 token 用量，绿点深浅按对数档位。
struct ContributionHeatmap: View {
    let daily: [String: Int]   // "yyyy-MM-dd" -> tokens
    var weeks: Int = 16

    @State private var hoveredCell: HoveredCell?

    // GitHub 风格正方形小格子
    private let cellW: CGFloat = 9
    private let cellH: CGFloat = 9
    private let gap: CGFloat = 3
    private let tooltipWidth: CGFloat = 104
    private let tooltipHeight: CGFloat = 38
    private let tooltipGap: CGFloat = 4

    private struct HoveredCell: Equatable {
        let key: String
        let date: Date
        let column: Int
        let row: Int
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let zhTooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    private static let enTooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d"
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

    private var gridWidth: CGFloat {
        CGFloat(weeks) * cellW + CGFloat(max(weeks - 1, 0)) * gap
    }

    private var gridHeight: CGFloat {
        7 * cellH + 6 * gap
    }

    var body: some View {
        let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { column, col in
                    VStack(spacing: gap) {
                        ForEach(Array(col.enumerated()), id: \.element) { row, day in
                            heatmapCell(day: day, column: column, row: row, today: today)
                        }
                    }
                }
            }

            if let hoveredCell {
                usageTooltip(for: hoveredCell)
                    .position(tooltipPosition(for: hoveredCell))
                    .allowsHitTesting(false)
                    .id(hoveredCell.key)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .identity
                    ))
                    .zIndex(2)
            }
        }
        .frame(width: gridWidth, height: gridHeight)
        .animation(.easeOut(duration: 0.12), value: hoveredCell)
    }

    private func heatmapCell(day: Date, column: Int, row: Int, today: Date) -> some View {
        let key = Self.fmt.string(from: day)
        let tokens = daily[key] ?? 0
        let isFuture = day > today
        let isHovered = hoveredCell?.key == key

        return RoundedRectangle(cornerRadius: 2)
            .fill(isFuture ? Color.clear : color(level(tokens)))
            .frame(width: cellW, height: cellH)
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .frame(width: cellW + 4, height: cellH + 4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { isInside in
                guard !isFuture else { return }
                if isInside {
                    hoveredCell = HoveredCell(
                        key: key,
                        date: day,
                        column: column,
                        row: row
                    )
                } else if hoveredCell?.key == key {
                    hoveredCell = nil
                }
            }
            .zIndex(isHovered ? 1 : 0)
    }

    private func usageTooltip(for cell: HoveredCell) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tooltipDate(cell.date))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(L.tokenDailyUsage(TokenFormat.compact(daily[cell.key] ?? 0)))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .frame(width: tooltipWidth, height: tooltipHeight, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func tooltipPosition(for cell: HoveredCell) -> CGPoint {
        let cellCenterX = CGFloat(cell.column) * (cellW + gap) + cellW / 2
        let cellCenterY = CGFloat(cell.row) * (cellH + gap) + cellH / 2
        let halfTooltipWidth = tooltipWidth / 2
        let halfTooltipHeight = tooltipHeight / 2
        let rawY: CGFloat

        if cell.row <= 2 {
            rawY = cellCenterY + cellH / 2 + tooltipGap + halfTooltipHeight
        } else {
            rawY = cellCenterY - cellH / 2 - tooltipGap - halfTooltipHeight
        }

        return CGPoint(
            x: min(max(cellCenterX, halfTooltipWidth), gridWidth - halfTooltipWidth),
            y: min(max(rawY, halfTooltipHeight), gridHeight - halfTooltipHeight)
        )
    }

    private func tooltipDate(_ date: Date) -> String {
        let formatter = L.zh ? Self.zhTooltipDateFormatter : Self.enTooltipDateFormatter
        return formatter.string(from: date)
    }
}
