import AppKit
import SwiftUI

struct CodexRadarView: View {
    @ObservedObject private var radar = CodexRadarService.shared

    var body: some View {
        let presentation = presentation

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: presentation.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(presentation.tint)
                    .frame(width: 18, height: 18)

                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let badge = presentation.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(presentation.tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(presentation.tint.opacity(0.12))
                            .cornerRadius(5)
                    }
                }
                .frame(height: 18, alignment: .center)

                Spacer(minLength: 4)

                HStack(alignment: .center, spacing: 7) {
                    Button {
                        Task { await radar.refresh() }
                    } label: {
                        RefreshIconView(
                            isRefreshing: radar.isRefreshing,
                            size: 15,
                            fontSize: 10,
                            weight: .medium
                        )
                        .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .foregroundColor(.secondary)
                    .help(L.zh ? "刷新 Codex 雷达" : "Refresh Codex Radar")
                    .disabled(radar.isRefreshing)

                    Button {
                        NSWorkspace.shared.open(radar.homepageURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .foregroundColor(.secondary)
                    .help(L.zh ? "打开 Codex 雷达" : "Open Codex Radar")
                }
                .frame(height: 18, alignment: .center)
            }

            Text(presentation.subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(presentation.tint.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(presentation.tint.opacity(0.58), lineWidth: 1.3)
                )
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var presentation: RadarPresentation {
        guard let snapshot = radar.snapshot else {
            if radar.isRefreshing {
                return RadarPresentation(
                    title: L.zh ? "Codex 雷达同步中" : "Codex Radar syncing",
                    subtitle: L.zh ? "正在获取重置预测" : "Fetching reset prediction",
                    badge: nil,
                    iconName: "antenna.radiowaves.left.and.right",
                    tint: .blue
                )
            }

            return RadarPresentation(
                title: L.zh ? "Codex 雷达暂不可用" : "Codex Radar unavailable",
                subtitle: radar.lastError ?? (L.zh ? "稍后自动重试" : "Will retry automatically"),
                badge: nil,
                iconName: "wifi.exclamationmark",
                tint: .secondary
            )
        }

        if radar.isStale {
            return RadarPresentation(
                title: L.zh ? "Codex 雷达数据已过期" : "Codex Radar stale",
                subtitle: lastUpdatedText,
                badge: nil,
                iconName: "clock.badge.exclamationmark",
                tint: .secondary
            )
        }

        if snapshot.windowOpen {
            return RadarPresentation(
                title: L.zh ? "速蹬窗口开启" : "Reset window open",
                subtitle: snapshot.window.message ?? snapshot.window.title ?? (L.zh ? "建议先用剩余额度" : "Use remaining quota first"),
                badge: L.zh ? "窗口" : "Open",
                iconName: "bolt.circle.fill",
                tint: .orange
            )
        }

        let level = snapshot.prediction?.level?.lowercased() ?? "none"
        switch level {
        case "high":
            return RadarPresentation(
                title: L.zh ? "重置预测：高概率" : "Reset prediction: high",
                subtitle: probabilityLine(snapshot),
                badge: probabilityBadge(snapshot.prediction),
                iconName: "exclamationmark.circle.fill",
                tint: .red
            )
        case "medium":
            return RadarPresentation(
                title: L.zh ? "重置预测：中概率" : "Reset prediction: medium",
                subtitle: probabilityLine(snapshot),
                badge: probabilityBadge(snapshot.prediction),
                iconName: "antenna.radiowaves.left.and.right",
                tint: .yellow
            )
        case "low":
            return RadarPresentation(
                title: L.zh ? "重置预测：低概率" : "Reset prediction: low",
                subtitle: probabilityLine(snapshot),
                badge: probabilityBadge(snapshot.prediction),
                iconName: "checkmark.circle.fill",
                tint: .green
            )
        default:
            return RadarPresentation(
                title: L.zh ? "暂无速蹬窗口" : "No reset window",
                subtitle: probabilityLine(snapshot),
                badge: nil,
                iconName: "checkmark.circle.fill",
                tint: .green
            )
        }
    }

    private var lastUpdatedText: String {
        guard let date = radar.lastFetchAt else {
            return L.zh ? "尚未更新" : "Not updated yet"
        }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return L.zh ? "刚刚更新" : "Just updated" }
        if seconds < 3600 {
            return L.zh ? "\(seconds / 60) 分钟前更新" : "Updated \(seconds / 60)m ago"
        }
        return L.zh ? "\(seconds / 3600) 小时前更新" : "Updated \(seconds / 3600)h ago"
    }

    private func probabilityLine(_ snapshot: CodexRadarSnapshot) -> String {
        let probability = snapshot.prediction?.probabilitySummary
            ?? (L.zh ? "暂无概率" : "No probability")
        if let summary = snapshot.prediction?.summary, !summary.isEmpty {
            return "\(probability) · \(summary)"
        }
        return "\(probability) · \(lastUpdatedText)"
    }

    private func probabilityBadge(_ prediction: CodexRadarPrediction?) -> String? {
        guard let probability48h = prediction?.probability48h else { return nil }
        return "\(Int(probability48h * 100))%"
    }
}

private struct RadarPresentation {
    let title: String
    let subtitle: String
    let badge: String?
    let iconName: String
    let tint: Color
}
