import AppKit
import SwiftUI

struct CodexRadarView: View {
    @EnvironmentObject var language: LanguageSettings
    @ObservedObject private var radar = CodexRadarService.shared

    var body: some View {
        let _ = language.identity

        VStack(alignment: .leading, spacing: 8) {
            header

            if let latest = radar.snapshot?.modelIQ?.latest {
                qualitySummary(latest)
                comparisonList
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onAppear {
            if radar.snapshot == nil {
                Task { await radar.refresh() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 16, height: 16)

            Text(L.modelQualityTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)

            if let updatedText {
                Text(updatedText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            Button {
                Task { await radar.refresh() }
            } label: {
                RefreshIconView(
                    isRefreshing: radar.isRefreshing,
                    size: 14,
                    fontSize: 10,
                    weight: .medium
                )
                .frame(width: 17, height: 17)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .foregroundColor(.secondary)
            .disabled(radar.isRefreshing)
            .help(L.modelQualityRefreshHelp)
            .accessibilityLabel(L.modelQualityRefreshHelp)

            Button {
                NSWorkspace.shared.open(radar.homepageURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 17, height: 17)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .foregroundColor(.secondary)
            .help(L.modelQualityOpenHelp)
            .accessibilityLabel(L.modelQualityOpenHelp)
        }
    }

    @ViewBuilder
    private func qualitySummary(_ latest: CodexRadarModelIQEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(modelName(for: latest))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(passLine(for: latest))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: -1) {
                    Text(scoreText(latest.score))
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(statusColor(latest.status))
                        .minimumScaleFactor(0.78)
                        .lineLimit(1)
                        .contentTransition(.numericText())

                    Text("IQ")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(statusColor(latest.status).opacity(0.28), lineWidth: 0.8)
                    )
            )
        }
    }

    private var comparisonList: some View {
        let comparisons = orderedComparisons

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(comparisons.prefix(3)), id: \.id) { item in
                comparisonLine(item)
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 7) {
            Image(systemName: radar.lastError == nil ? "ellipsis" : "wifi.exclamationmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Text(emptyText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)

            Spacer()
        }
        .frame(minHeight: 36)
    }

    private func comparisonLine(_ item: RadarComparisonItem) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor(item.entry.status))
                .frame(width: 5, height: 5)

            Text(item.shortLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 4) {
                Text("IQ")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(scoreText(item.entry.score))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(statusColor(item.entry.status))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .allowsTightening(true)
            }
            .frame(width: 62, alignment: .trailing)
            .layoutPriority(1)
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.028))
        )
        .accessibilityElement(children: .combine)
    }

    private var updatedText: String? {
        guard let date = radar.snapshot?.monitoredAt ?? radar.lastFetchAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.zh ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private var emptyText: String {
        if radar.isRefreshing {
            return L.modelQualityReading
        }
        if let lastError = radar.lastError {
            return lastError
        }
        return L.modelQualityNoData
    }

    private var orderedComparisons: [RadarComparisonItem] {
        guard let comparisons = radar.snapshot?.modelIQ?.comparisons else { return [] }
        let preferredOrder = ["gpt_55_high", "gpt_55_medium", "gpt_54_xhigh"]
        return comparisons
            .compactMap { key, comparison -> RadarComparisonItem? in
                guard let latest = comparison.latest else { return nil }
                return RadarComparisonItem(
                    id: key,
                    label: comparison.label ?? modelName(
                        model: comparison.model ?? latest.model,
                        effort: comparison.reasoningEffort ?? latest.reasoningEffort
                    ),
                    entry: latest
                )
            }
            .sorted {
                let left = preferredOrder.firstIndex(of: $0.id) ?? Int.max
                let right = preferredOrder.firstIndex(of: $1.id) ?? Int.max
                if left != right { return left < right }
                return $0.label < $1.label
            }
    }

    private func modelName(for entry: CodexRadarModelIQEntry) -> String {
        modelName(model: entry.model, effort: entry.reasoningEffort)
    }

    private func modelName(model: String?, effort: String?) -> String {
        let modelText = model?.uppercased().replacingOccurrences(of: "GPT-", with: "GPT-") ?? "Codex"
        guard let effort, !effort.isEmpty else { return modelText }
        return "\(modelText) \(effort)"
    }

    private func scoreText(_ score: Double?) -> String {
        guard let score else { return "--" }
        return String(format: "%.1f", score)
    }

    private func passLine(for entry: CodexRadarModelIQEntry) -> String {
        guard let passed = entry.passed,
              let tasks = entry.tasks,
              let baseline = baselinePassed(for: entry),
              let dateText = displayDateText(entry.date) else {
            return L.modelQualityBenchmarkNote
        }
        return L.modelQualityPassLine(
            date: dateText,
            passed: "\(passed)",
            tasks: "\(tasks)",
            baseline: "\(baseline)"
        )
    }

    private func baselinePassed(for entry: CodexRadarModelIQEntry) -> Int? {
        guard let passed = entry.passed, let score = entry.score, score > 0 else { return nil }
        return Int((Double(passed) * 100 / score).rounded())
    }

    private func displayDateText(_ rawDate: String?) -> String? {
        guard let rawDate, !rawDate.isEmpty else { return nil }

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"

        guard let date = parser.date(from: rawDate) else { return rawDate }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.zh ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = L.zh ? "M月d日" : "MMM d"
        return formatter.string(from: date)
    }

    private func statusColor(_ status: String?) -> Color {
        switch status?.lowercased() {
        case "green":
            return CodexStatusPalette.ok
        case "yellow":
            return CodexStatusPalette.warning
        case "red":
            return CodexStatusPalette.danger
        default:
            return .accentColor
        }
    }
}

private struct RadarComparisonItem {
    let id: String
    let label: String
    let entry: CodexRadarModelIQEntry

    var shortLabel: String {
        label
            .replacingOccurrences(of: "GPT-", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }
}
