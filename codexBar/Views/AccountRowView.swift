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
        let fiveHourUsedPercent = account.hasFiveHourQuota
            ? account.fiveHourUsedPercent
            : nil
        let fiveHourDisplayPercent = fiveHourUsedPercent.map {
            quotaDisplay.amountMode.displayPercent(forUsedPercent: $0)
        }
        let fiveHourResetDescription = account.fiveHourResetDescription
        let weeklyDisplayPercent = quotaDisplay.amountMode.displayPercent(
            forUsedPercent: account.weeklyUsedPercent
        )
        let weeklyResetDescription = account.weeklyResetDescription
        let showWeeklyReset = !weeklyResetDescription.isEmpty

        VStack(alignment: .leading, spacing: PopupSpacing.compact) {
            // Line 1: org name + plan badge + active mark + switch button
            HStack(spacing: PopupSpacing.compact) {
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

                if hasResetCredits {
                    resetCreditsBadge
                }

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
            .frame(maxWidth: .infinity, alignment: .leading)

            if shouldShowResetCreditsExpiration {
                resetCreditsExpirationInfo
            }

            // Line 2: usage info
            if account.tokenExpired {
                HStack(spacing: PopupSpacing.compact) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(L.tokenExpiredHint)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Spacer()
                }
            } else if account.isBanned {
                HStack(spacing: PopupSpacing.compact) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(L.accountSuspended)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Spacer()
                }
            } else {
                if let fiveHourUsedPercent, let fiveHourDisplayPercent {
                    HStack(alignment: .top, spacing: PopupSpacing.regular) {
                        quotaColumn(
                            label: "5h",
                            displayPercent: fiveHourDisplayPercent,
                            usedPercent: fiveHourUsedPercent,
                            resetDescription: fiveHourResetDescription,
                            showReset: !fiveHourResetDescription.isEmpty
                        )
                        quotaColumn(
                            label: "7d",
                            displayPercent: weeklyDisplayPercent,
                            usedPercent: account.weeklyUsedPercent,
                            resetDescription: weeklyResetDescription,
                            showReset: showWeeklyReset
                        )
                    }
                } else {
                    quotaColumn(
                        label: "7d",
                        displayPercent: weeklyDisplayPercent,
                        usedPercent: account.weeklyUsedPercent,
                        resetDescription: weeklyResetDescription,
                        showReset: showWeeklyReset
                    )
                }
            }
        }
        .padding(.vertical, PopupSpacing.regular)
        .padding(.horizontal, PopupSpacing.regular)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.045))
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

    private var hasResetCredits: Bool {
        guard let count = account.rateLimitResetCreditsAvailableCount else { return false }
        return count > 0
    }

    private var resetCreditsColor: Color {
        guard let count = account.rateLimitResetCreditsAvailableCount, count > 0 else {
            return .secondary
        }
        return CodexStatusPalette.ok
    }

    private var shouldShowResetCreditsExpiration: Bool {
        guard let count = account.rateLimitResetCreditsAvailableCount,
              count > 0,
              let expiresAt = account.rateLimitResetCreditsExpiresAt else {
            return false
        }
        return isWithinResetCreditsReminderWindow(expiresAt)
    }

    private var resetCreditsExpirationInfo: some View {
        HStack(spacing: PopupSpacing.compact) {
            Image(systemName: resetCreditsExpirationIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(resetCreditsExpirationText)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: PopupSpacing.compact)
        }
        .foregroundColor(resetCreditsExpirationColor)
        .padding(.horizontal, PopupSpacing.regular)
        .padding(.vertical, PopupSpacing.compact)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(resetCreditsExpirationColor.opacity(0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(resetCreditsExpirationColor.opacity(0.42), lineWidth: 1)
        )
        .help(L.resetCreditsExpiresAtHelp)
    }

    private func isWithinResetCreditsReminderWindow(_ expiresAt: Date) -> Bool {
        let remaining = expiresAt.timeIntervalSince(now)
        return remaining > 0 && remaining <= 3 * 24 * 60 * 60
    }

    private var resetCreditsExpirationColor: Color {
        CodexStatusPalette.brightWarning
    }

    private var resetCreditsExpirationIcon: String {
        "calendar.badge.clock"
    }

    private var resetCreditsExpirationText: String {
        guard let expiresAt = account.rateLimitResetCreditsExpiresAt else { return "" }
        return L.resetCreditsExpiresAt(formattedResetCreditsExpirationDate(expiresAt))
    }

    private func formattedResetCreditsExpirationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.zh ? "zh_CN" : "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func usageColor(_ percent: Double) -> Color {
        CodexStatusPalette.color(forUsedPercent: percent)
    }

    private func quotaColumn(
        label: String,
        displayPercent: Double,
        usedPercent: Double,
        resetDescription: String,
        showReset: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: PopupSpacing.compact) {
            HStack(spacing: PopupSpacing.compact) {
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
                .scaleEffect(x: 1, y: 0.9)
                .frame(height: 5)
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
