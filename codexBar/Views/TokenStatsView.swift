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
    /// 1234 → "1.2K"；1_234_567 → "1.2M"；1_234_000_000 → "1.2B"
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch n {
        case 1_000_000_000...:
            return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", v / 1_000_000)
        case 10_000...:
            return String(format: "%.1fK", v / 1_000)
        case 1_000...:
            return String(format: "%.2fK", v / 1_000)
        default:
            return "\(n)"
        }
    }
}
