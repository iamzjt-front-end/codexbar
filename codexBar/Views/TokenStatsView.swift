import SwiftUI

struct TokenStatsView: View {
    @EnvironmentObject var language: LanguageSettings
    @ObservedObject var service: TokenStatsService = .shared

    var body: some View {
        let _ = language.identity

        VStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { service.range },
                set: { service.switchTo($0) }
            )) {
                ForEach(TokenStatsRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                    ProgressView().controlSize(.mini).scaleEffect(0.5)
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

enum TokenFormat {
    /// zh: 12345 -> "1.2万", 2160000000 -> "21.6亿"
    /// en: 1234 -> "1.23K", 1234567 -> "1.23M", 1234000000 -> "1.23B"
    static func compact(_ n: Int) -> String {
        if L.zh { return compactChinese(n) }

        let v = Double(n)
        switch n {
        case 1_000_000_000...:
            return format(v / 1_000_000_000, suffix: "B", decimals: 2)
        case 1_000_000...:
            return format(v / 1_000_000, suffix: "M", decimals: 2)
        case 10_000...:
            return format(v / 1_000, suffix: "K", decimals: 1)
        case 1_000...:
            return format(v / 1_000, suffix: "K", decimals: 2)
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
