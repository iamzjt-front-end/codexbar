import SwiftUI

struct TaskAttentionPresentation: Equatable {
    let count: Int
    let projectName: String

    init?(snapshot: TaskCenterSnapshot) {
        guard let mostUrgent = snapshot.needsAttentionRecords.first else {
            return nil
        }
        count = snapshot.needsAttentionCount
        projectName = mostUrgent.projectName
    }
}

@MainActor
struct TaskAttentionBannerView: View {
    let presentation: TaskAttentionPresentation
    @ObservedObject var notifications: TaskNotificationService
    let isEnablingNotifications: Bool
    let onOpenCodex: () -> Void
    let onEnableNotifications: () -> Void

    private var title: String {
        L.taskAttentionBanner(
            count: presentation.count,
            projectName: presentation.projectName
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpenCodex) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CodexStatusPalette.danger)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(L.taskAttentionOpenCodexHint)

            if !notifications.isEnabled {
                Divider()
                    .frame(height: 18)

                Button(action: onEnableNotifications) {
                    if isEnablingNotifications {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(isEnablingNotifications)
                .help(L.taskAttentionEnableNotifications)
                .accessibilityLabel(L.taskAttentionEnableNotifications)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CodexStatusPalette.danger.opacity(0.08))
    }
}
