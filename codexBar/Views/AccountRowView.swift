import SwiftUI

/// One org/account row under an email group
struct AccountRowView: View {
    @EnvironmentObject var language: LanguageSettings
    @EnvironmentObject var quotaDisplay: QuotaDisplaySettings

    let account: TokenAccount
    let isActive: Bool
    let now: Date
    let isRefreshing: Bool
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onReauth: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let _ = language.identity
        let primaryDisplayPercent = displayPercent(forUsedPercent: account.primaryUsedPercent)
        let secondaryDisplayPercent = displayPercent(forUsedPercent: account.secondaryUsedPercent)
        let primaryResetDescription = account.primaryResetDescription
        let secondaryResetDescription = account.secondaryResetDescription
        let showPrimaryReset = shouldShowResetTime(
            description: primaryResetDescription,
            usedPercent: account.primaryUsedPercent
        )
        let showSecondaryReset = shouldShowResetTime(
            description: secondaryResetDescription,
            usedPercent: account.secondaryUsedPercent
        )

        VStack(alignment: .leading, spacing: 4) {
            // Line 1: org name + plan badge + active mark + switch button
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Text(displayName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .accentColor : .primary)
                    .lineLimit(1)

                Text(planBadgeText)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(planBadgeColor.opacity(0.15))
                    .foregroundColor(planBadgeColor)
                    .cornerRadius(3)

                resetCreditsBadge

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 10))
                }

                Spacer()

                // 删除按钮（NSAlert 二次确认）
                Button {
                    let alert = NSAlert()
                    alert.messageText = L.confirmDelete(displayName)
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L.delete)
                    alert.addButton(withTitle: L.cancel)
                    if alert.runModal() == .alertFirstButtonReturn {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .foregroundColor(.secondary)

                if account.tokenExpired {
                    Button(L.reauth, action: onReauth)
                        .buttonStyle(.borderedProminent)
                        .focusable(false)
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .medium))
                        .tint(.orange)
                } else if !account.isBanned {
                    Button(action: onRefresh) {
                        RefreshIconView(
                            isRefreshing: isRefreshing,
                            size: 14,
                            fontSize: 10,
                            weight: .medium
                        )
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .foregroundColor(.secondary)
                    .disabled(isRefreshing)

                    if !isActive {
                        Button(L.switchBtn, action: onActivate)
                            .buttonStyle(.borderedProminent)
                            .focusable(false)
                            .controlSize(.mini)
                            .font(.system(size: 10, weight: .medium))
                    }
                }
            }

            if shouldShowResetCreditsExpirationWarning {
                resetCreditsExpirationWarning
            }

            // Line 2: usage info
            if account.tokenExpired {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(L.tokenExpiredHint)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Spacer()
                }
            } else if account.isBanned {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(L.accountSuspended)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Spacer()
                }
            } else {
                // 额度耗尽时仍保留双列布局：100% 进度条以 danger 色填满，
                // 重置时间显示在对应列下方，行高与可用状态保持一致。
                HStack(alignment: .top, spacing: 8) {
                    quotaColumn(
                        label: "5h",
                        displayPercent: primaryDisplayPercent,
                        usedPercent: account.primaryUsedPercent,
                        resetDescription: primaryResetDescription,
                        showReset: showPrimaryReset
                    )
                    quotaColumn(
                        label: "7d",
                        displayPercent: secondaryDisplayPercent,
                        usedPercent: account.secondaryUsedPercent,
                        resetDescription: secondaryResetDescription,
                        showReset: showSecondaryReset
                    )
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 16)   // indent under email header
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
    }

    private var displayName: String {
        if let org = account.organizationName, !org.isEmpty { return org }
        return String(account.accountId.prefix(8))
    }

    private var statusColor: Color {
        if account.tokenExpired { return CodexStatusPalette.warning }
        return CodexStatusPalette.color(for: account.usageStatus)
    }

    private var planBadgeColor: Color {
        switch normalizedPlanType {
        case "free": return .green
        case "prolite", "pro5x", "codexpro5x": return .blue
        case "pro", "promax", "pro20x", "codexpro20x": return .indigo
        case "team": return .teal
        case "plus": return .purple
        default: return .gray
        }
    }

    private var planBadgeText: String {
        switch normalizedPlanType {
        case "prolite", "pro5x", "codexpro5x": return "PRO 5X"
        case "pro", "promax", "pro20x", "codexpro20x": return "PRO 20X"
        default: return account.planType.uppercased()
        }
    }

    private var normalizedPlanType: String {
        account.planType
            .lowercased()
            .replacingOccurrences(of: "[_\\-\\s]", with: "", options: .regularExpression)
    }

    private var resetCreditsBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "gift.fill")
                .font(.system(size: 8, weight: .medium))
            Text(resetCreditsText)
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
        }
        .foregroundColor(resetCreditsColor)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(resetCreditsColor.opacity(0.12))
        .cornerRadius(3)
        .help(L.resetCreditsHelp)
        .accessibilityLabel(L.resetCreditsAvailable)
        .accessibilityValue(resetCreditsText)
    }

    private var resetCreditsText: String {
        guard let count = account.rateLimitResetCreditsAvailableCount else { return L.resetCreditsUnknown }
        return L.resetCreditsCount(count)
    }

    private var resetCreditsColor: Color {
        guard let count = account.rateLimitResetCreditsAvailableCount, count > 0 else {
            return .secondary
        }
        return CodexStatusPalette.ok
    }

    private var shouldShowResetCreditsExpirationWarning: Bool {
        guard let count = account.rateLimitResetCreditsAvailableCount,
              count > 0,
              let expiresAt = account.rateLimitResetCreditsExpiresAt else {
            return false
        }
        let remaining = expiresAt.timeIntervalSince(now)
        return remaining > 0 && remaining <= 3 * 24 * 60 * 60
    }

    private var resetCreditsExpirationWarning: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(L.resetCreditsExpireSoon(resetCreditsExpirationDescription))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
        }
        .foregroundColor(CodexStatusPalette.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(CodexStatusPalette.warning.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(CodexStatusPalette.warning.opacity(0.24), lineWidth: 0.8)
        )
        .help(L.resetCreditsExpireSoonHelp)
    }

    private var resetCreditsExpirationDescription: String {
        guard let expiresAt = account.rateLimitResetCreditsExpiresAt else { return "" }
        let remaining = max(0, expiresAt.timeIntervalSince(now))
        if remaining < 60 * 60 {
            let minutes = max(1, Int(ceil(remaining / 60)))
            return L.resetCreditsExpireInMinutes(minutes)
        }
        if remaining < 24 * 60 * 60 {
            let hours = max(1, Int(ceil(remaining / 3600)))
            return L.resetCreditsExpireInHours(hours)
        }
        let days = max(1, Int(ceil(remaining / (24 * 60 * 60))))
        return L.resetCreditsExpireInDays(days)
    }

    private func usageColor(_ percent: Double) -> Color {
        CodexStatusPalette.color(forUsedPercent: percent)
    }

    private func displayPercent(forUsedPercent usedPercent: Double) -> Double {
        switch quotaDisplay.amountMode {
        case .used:
            return min(max(usedPercent, 0), 100)
        case .remaining:
            return min(max(100 - usedPercent, 0), 100)
        }
    }

    private func shouldShowResetTime(description: String, usedPercent: Double) -> Bool {
        !description.isEmpty && (quotaDisplay.alwaysShowResetTime || usedPercent >= 70)
    }

    private func quotaColumn(
        label: String,
        displayPercent: Double,
        usedPercent: Double,
        resetDescription: String,
        showReset: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(displayPercent))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(usageColor(usedPercent))
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: displayPercent)
            }
            ProgressView(value: min(displayPercent / 100, 1.0))
                .tint(usageColor(usedPercent))
                .scaleEffect(x: 1, y: 0.7)
                .animation(.easeInOut(duration: 0.4), value: displayPercent)
            if showReset {
                Text("\(label): \(resetDescription)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
