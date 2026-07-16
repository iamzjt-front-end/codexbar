import AppKit
import SwiftUI

struct CodexRadarView: View {
    @EnvironmentObject var language: LanguageSettings
    @ObservedObject private var radar = CodexRadarService.shared
    @State private var hoveredCellID: String?

    private var matrix: CodexRadarMatrix {
        CodexRadarPresentation.matrix(from: radar.snapshot?.modelIQ)
    }

    private var displayedCell: CodexRadarMatrixCell? {
        matrix.cell(id: hoveredCellID)
            ?? matrix.cell(id: matrix.bestCellID)
    }

    var body: some View {
        let _ = language.identity

        VStack(alignment: .leading, spacing: PopupSpacing.regular) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                header(now: context.date)
            }

            if matrix.rows.isEmpty {
                emptyState
            } else {
                CodexRadarMatrixView(
                    matrix: matrix,
                    hoveredCellID: $hoveredCellID
                )

                if let displayedCell {
                    qualityDetail(displayedCell)
                }
            }
        }
        .frame(width: 300 - PopupSpacing.section * 2, alignment: .leading)
        .padding(.horizontal, PopupSpacing.section)
        .padding(.vertical, PopupSpacing.regular)
        .onAppear {
            reconcileHover()
            if radar.needsVisibleRefresh {
                Task { await radar.refresh() }
            }
        }
        .onChange(of: matrix.signature) {
            reconcileHover()
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: PopupSpacing.regular) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 16, height: 16)

            Text(L.modelQualityTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)

            if let updatedText = freshnessText(now: now) {
                Text(updatedText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }

            Spacer(minLength: PopupSpacing.compact)

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

    private var emptyState: some View {
        HStack(spacing: PopupSpacing.regular) {
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

    private func qualityDetail(_ cell: CodexRadarMatrixCell) -> some View {
        Text(
            L.modelQualityDetail(
                model: cell.displayName,
                score: CodexRadarPresentation.scoreText(cell.score),
                passCount: cell.passCountText,
                rank: matrix.rank(of: cell)
            )
        )
        .font(.system(size: 9.5, weight: .medium))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .monospacedDigit()
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .accessibilityLabel(
            L.modelQualityCellAccessibility(
                model: cell.displayName,
                score: CodexRadarPresentation.scoreText(cell.score),
                passCount: cell.passCountText,
                rank: matrix.rank(of: cell)
            )
        )
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

    private func freshnessText(now: Date) -> String? {
        guard let date = radar.lastFetchAt ?? radar.snapshot?.monitoredAt else { return nil }
        let interval = max(0, now.timeIntervalSince(date))

        if interval < 60 {
            return L.modelQualityJustNow
        }
        if interval < 60 * 60 {
            return L.modelQualityMinutesAgo(max(1, Int(interval / 60)))
        }
        if interval < 24 * 60 * 60 {
            return L.modelQualityHoursAgo(max(1, Int(interval / (60 * 60))))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.zh ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func reconcileHover() {
        if matrix.cell(id: hoveredCellID) == nil {
            hoveredCellID = nil
        }
    }
}

struct CodexRadarMatrixView: View {
    let matrix: CodexRadarMatrix
    @Binding var hoveredCellID: String?

    private let contentWidth: CGFloat = 300 - PopupSpacing.section * 2
    private let rowLabelWidth: CGFloat = 67
    private let columnSpacing: CGFloat = 3
    private let rowHeight: CGFloat = 34

    private var columnWidth: CGFloat {
        let spacingWidth = CGFloat(matrix.columns.count) * columnSpacing
        return max(28, (contentWidth - rowLabelWidth - spacingWidth) / CGFloat(matrix.columns.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PopupSpacing.compact) {
            columnHeader

            ForEach(matrix.rows) { row in
                HStack(spacing: columnSpacing) {
                    rowLabel(row)

                    ForEach(matrix.columns) { column in
                        if let cell = row.cell(for: column.id) {
                            cellView(cell)
                        } else {
                            unavailableCell
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnHeader: some View {
        HStack(spacing: columnSpacing) {
            Color.clear
                .frame(width: rowLabelWidth, height: 16)

            ForEach(matrix.columns) { column in
                Text(column.label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: columnWidth, height: 16)
                    .accessibilityHidden(true)
            }
        }
    }

    private func rowLabel(_ row: CodexRadarMatrixRow) -> some View {
        HStack(spacing: PopupSpacing.compact) {
            Image(systemName: row.family.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 15, height: 15)
                .accessibilityHidden(true)

            Text(row.displayName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: rowLabelWidth, height: rowHeight, alignment: .leading)
    }

    private func cellView(_ cell: CodexRadarMatrixCell) -> some View {
        let isHovered = hoveredCellID == cell.id
        let statusColor = cellStatusColor(cell)
        let rank = matrix.rank(of: cell)
        let podiumRank = rank.flatMap { $0 <= 3 ? $0 : nil }

        return ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(statusColor.opacity(isHovered ? 0.09 : 0.055))

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if let podiumRank {
                        HStack(spacing: 1) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 8.5, weight: .semibold))

                            Text("\(podiumRank)")
                                .font(.system(size: 7, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundColor(rankColor(podiumRank))
                        .frame(height: 11)
                        .accessibilityHidden(true)
                    }
                }
                .frame(height: 12)
                .padding(.horizontal, 2)

                Text(CodexRadarPresentation.scoreText(cell.score))
                    .font(.system(size: 9.5, weight: rank == 1 ? .semibold : .medium, design: .rounded))
                    .foregroundColor(statusColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: columnWidth, height: rowHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredCellID = cell.id
            } else if hoveredCellID == cell.id {
                hoveredCellID = nil
            }
        }
        .help(L.modelQualityCellHelp(model: cell.displayName, passCount: cell.passCountText))
        .accessibilityLabel(
            L.modelQualityCellAccessibility(
                model: cell.displayName,
                score: CodexRadarPresentation.scoreText(cell.score),
                passCount: cell.passCountText,
                rank: rank
            )
        )
    }

    private var unavailableCell: some View {
        Text("–")
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundColor(.secondary.opacity(0.48))
            .frame(width: columnWidth, height: rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.018))
            )
            .accessibilityHidden(true)
    }

    private func cellStatusColor(_ cell: CodexRadarMatrixCell) -> Color {
        switch cell.entry.status?.lowercased() {
        case "green":
            return CodexStatusPalette.ok
        case "yellow":
            return CodexStatusPalette.warning
        case "red":
            return CodexStatusPalette.danger
        default:
            return .primary
        }
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1:
            return Color(red: 0.82, green: 0.58, blue: 0.08)
        case 2:
            return Color(red: 0.47, green: 0.52, blue: 0.58)
        default:
            return Color(red: 0.68, green: 0.38, blue: 0.20)
        }
    }
}

struct CodexResetWindowTipView: View {
    @EnvironmentObject var language: LanguageSettings
    @ObservedObject private var radar = CodexRadarService.shared
    private let infoAccent = Color(red: 0.12, green: 0.33, blue: 0.82)

    var body: some View {
        let _ = language.identity

        if let resetWindow {
            HStack(spacing: PopupSpacing.regular) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(infoAccent)
                    .frame(width: 17, height: 17)
                    .background(
                        Circle()
                            .fill(infoAccent.opacity(0.12))
                    )

                tipText(for: resetWindow)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .monospacedDigit()

                Spacer(minLength: PopupSpacing.regular)

                Button {
                    NSWorkspace.shared.open(resetWindow.sourceURL ?? radar.homepageURL)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .foregroundColor(infoAccent)
                .help(L.codexResetWindowSourceHelp)
                .accessibilityLabel(L.codexResetWindowSourceHelp)
            }
            .frame(height: 31)
            .padding(.horizontal, PopupSpacing.regular)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(infoAccent.opacity(0.075))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(infoAccent.opacity(0.14), lineWidth: 0.8)
                    )
            )
            .padding(.horizontal, PopupSpacing.section)
            .padding(.bottom, PopupSpacing.regular)
            .help(resetWindow.message ?? L.codexResetWindowFallback)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var resetWindow: CodexRadarResetWindow? {
        guard let snapshot = radar.snapshot,
              let window = snapshot.window,
              window.isOpen || snapshot.windowOpen == true || snapshot.status?.lowercased() == "open" else {
            return nil
        }
        return window
    }

    private func tipText(for window: CodexRadarResetWindow) -> Text {
        guard let expectedResetAt = window.expectedResetAt else {
            return Text(L.codexResetWindowFallback)
                .foregroundColor(.primary)
        }
        return Text(L.codexResetWindowOpen(formattedResetDate(expectedResetAt)))
            .foregroundColor(.primary)
    }

    private func formattedResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.zh ? "zh_CN" : "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = L.zh ? "M/d HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }
}
