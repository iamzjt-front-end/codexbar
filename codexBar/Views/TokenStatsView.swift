import SwiftUI

struct TokenStatsView: View {
    @EnvironmentObject var language: LanguageSettings
    @ObservedObject var service: TokenStatsService = .shared

    var body: some View {
        let _ = language.identity

        VStack(spacing: 8) {
            TokenRangeSegmentedControl(selection: Binding(
                get: { service.range },
                set: { service.switchTo($0) }
            ))
            .id(language.identity)

            HStack(spacing: 5) {
                Text(TokenFormat.compact(service.stat.totalTokens))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.accentColor)
                    .contentTransition(.numericText())
                Text(L.tokenTotal)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                if service.loading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                }
                Spacer()
                Text(L.tokenThreadCount(service.stat.threadCount))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.25), value: service.stat.totalTokens)

            ContributionHeatmap(daily: service.daily)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { service.refresh() }
    }
}

private struct TokenRangeSegmentedControl: View {
    @Binding var selection: TokenStatsRange

    private var segmentMinWidth: CGFloat {
        L.zh ? 54 : 78
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(TokenStatsRange.allCases.enumerated()), id: \.element.id) { index, range in
                segment(for: range)

                if index < TokenStatsRange.allCases.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 17)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.10))
        )
        .frame(height: 34)
        .animation(.easeOut(duration: 0.16), value: selection)
    }

    private func segment(for range: TokenStatsRange) -> some View {
        let isSelected = selection == range

        return Text(range.label)
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundColor(isSelected ? .white : .primary.opacity(0.76))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(minWidth: segmentMinWidth, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selection = range
            }
    }
}

enum TokenFormat {
    /// zh: 12345 -> "1.2万", 2160000000 -> "21.6亿"
    /// en: 1234 -> "1.2K", 1234567 -> "1.2M", 1234000000 -> "1.2B"
    static func compact(_ n: Int) -> String {
        if L.zh { return compactChinese(n) }

        let v = Double(n)
        switch n {
        case 1_000_000_000...:
            return format(v / 1_000_000_000, suffix: "B", decimals: 1)
        case 1_000_000...:
            return format(v / 1_000_000, suffix: "M", decimals: 1)
        case 1_000...:
            return format(v / 1_000, suffix: "K", decimals: 1)
        default:
            return "\(n)"
        }
    }

    private static func compactChinese(_ n: Int) -> String {
        let v = Double(n)
        switch n {
        case 100_000_000...:
            return format(v / 100_000_000, suffix: "亿", decimals: 1)
        case 10_000...:
            return format(v / 10_000, suffix: "万", decimals: 1)
        default:
            return "\(n)"
        }
    }

    private static func format(_ value: Double, suffix: String, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        while text.contains("."), text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text + suffix
    }
}
