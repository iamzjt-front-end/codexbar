import AppKit
import SwiftUI

@MainActor
struct TaskCenterSummaryView: View {
    @ObservedObject private var service: TaskCenterService
    @ObservedObject private var hookInstaller: CodexHookInstallerService
    @ObservedObject private var language: LanguageSettings

    private let onOpen: () -> Void

    init(onOpen: @escaping () -> Void) {
        self.init(
            service: .shared,
            hookInstaller: .shared,
            language: .shared,
            onOpen: onOpen
        )
    }

    init(
        service: TaskCenterService,
        hookInstaller: CodexHookInstallerService,
        onOpen: @escaping () -> Void
    ) {
        self.init(
            service: service,
            hookInstaller: hookInstaller,
            language: .shared,
            onOpen: onOpen
        )
    }

    init(
        service: TaskCenterService,
        hookInstaller: CodexHookInstallerService,
        language: LanguageSettings,
        onOpen: @escaping () -> Void
    ) {
        _service = ObservedObject(wrappedValue: service)
        _hookInstaller = ObservedObject(wrappedValue: hookInstaller)
        _language = ObservedObject(wrappedValue: language)
        self.onOpen = onOpen
    }

    private var copy: TaskCenterCopy {
        TaskCenterCopy(isChinese: language.override)
    }

    private var hookIsNotReady: Bool {
        hookInstaller.state != .installed
    }

    private var mainText: String {
        if hookIsNotReady {
            return copy.hookTitle(for: hookInstaller.state)
        }
        return copy.summary(
            needsAttention: service.snapshot.needsAttentionCount,
            running: service.snapshot.runningCount
        )
    }

    private var detailText: String {
        if hookIsNotReady {
            return copy.hookSummaryDetail
        }
        guard let record = service.snapshot.mostUrgent else {
            return copy.openTaskCenterDetail
        }
        return "\(record.projectName) · \(copy.phase(record.phase))"
    }

    private var accentColor: Color {
        if hookIsNotReady {
            return CodexStatusPalette.warning
        }
        if service.snapshot.needsAttentionCount > 0 {
            return CodexStatusPalette.danger
        }
        if service.snapshot.runningCount > 0 {
            return CodexStatusPalette.warning
        }
        if service.snapshot.readyCount > 0 {
            return CodexStatusPalette.ok
        }
        return .secondary
    }

    private var symbolName: String {
        if hookIsNotReady {
            return "exclamationmark.triangle.fill"
        }
        if service.snapshot.needsAttentionCount > 0 {
            return "exclamationmark.circle.fill"
        }
        if service.snapshot.runningCount > 0 {
            return "bolt.fill"
        }
        if service.snapshot.readyCount > 0 {
            return "checkmark.circle.fill"
        }
        return "circle.dashed"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mainText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(detailText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [copy.taskCenterTitle, mainText, detailText]
                .joined(separator: copy.accessibilitySeparator)
        )
        .accessibilityHint(copy.openTaskCenterHint)
    }
}

@MainActor
struct TaskCenterView: View {
    @ObservedObject private var service: TaskCenterService
    @ObservedObject private var hookInstaller: CodexHookInstallerService
    @ObservedObject private var notifications: TaskNotificationService
    @ObservedObject private var language: LanguageSettings

    @State private var hookActionError: String?
    @State private var notificationActionError: String?
    @State private var isEnablingNotifications = false

    init() {
        self.init(
            service: .shared,
            hookInstaller: .shared,
            notifications: .shared,
            language: .shared
        )
    }

    init(
        service: TaskCenterService,
        hookInstaller: CodexHookInstallerService,
        notifications: TaskNotificationService,
        language: LanguageSettings
    ) {
        _service = ObservedObject(wrappedValue: service)
        _hookInstaller = ObservedObject(wrappedValue: hookInstaller)
        _notifications = ObservedObject(wrappedValue: notifications)
        _language = ObservedObject(wrappedValue: language)
    }

    private var copy: TaskCenterCopy {
        TaskCenterCopy(isChinese: language.override)
    }

    private var shouldShowHookBlockingState: Bool {
        hookInstaller.state != .installed && service.snapshot.records.isEmpty
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(spacing: 0) {
                TaskCenterHeader(
                    snapshot: service.snapshot,
                    copy: copy
                )

                Divider()

                if hookInstaller.state != .installed {
                    TaskCenterHookBanner(
                        state: hookInstaller.state,
                        errorMessage: hookActionError,
                        copy: copy,
                        action: installOrUpdateHook
                    )

                    Divider()
                } else if service.snapshot.isLegacyFallback {
                    TaskCenterInfoBanner(
                        symbolName: "clock.arrow.circlepath",
                        text: copy.legacyFallbackDetail,
                        color: CodexStatusPalette.warning
                    )

                    Divider()
                }

                if !notifications.isEnabled {
                    TaskCenterNotificationBanner(
                        isEnabling: isEnablingNotifications,
                        errorMessage: notificationActionError,
                        copy: copy,
                        action: enableNotifications
                    )

                    Divider()
                }

                if service.snapshot.unreadableCount > 0 {
                    TaskCenterInfoBanner(
                        symbolName: "doc.badge.ellipsis",
                        text: copy.unreadableRecords(service.snapshot.unreadableCount),
                        color: CodexStatusPalette.warning
                    )

                    Divider()
                }

                if shouldShowHookBlockingState {
                    TaskCenterUnavailableView(
                        title: copy.hookTitle(for: hookInstaller.state),
                        detail: copy.hookBlockingDetail,
                        symbolName: "point.3.connected.trianglepath.dotted"
                    )
                } else if service.snapshot.records.isEmpty {
                    TaskCenterUnavailableView(
                        title: copy.noTaskStatusReceived,
                        detail: copy.noEventsDetail,
                        symbolName: "tray"
                    )
                } else {
                    TaskCenterRecordList(
                        snapshot: service.snapshot,
                        selectedTaskKey: service.selectedTaskKey,
                        now: timeline.date,
                        copy: copy
                    )
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 480)
        .onAppear {
            service.start()
            hookInstaller.refresh()
            notifications.refreshAuthorizationStatus()
            TaskCenterWindowCoordinator.shared.updateLocalizedTitle()
        }
        .onChange(of: language.identity) { _, _ in
            TaskCenterWindowCoordinator.shared.updateLocalizedTitle()
        }
    }

    private func installOrUpdateHook() {
        let alert = NSAlert()
        alert.messageText = L.codexHookInstallConfirmTitle
        alert.informativeText = L.codexHookInstallConfirmInfo(hookInstaller.hooksURL.path)
        alert.addButton(withTitle: L.codexHookInstallConfirmButton)
        alert.addButton(withTitle: L.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try hookInstaller.install()
            hookActionError = nil
            service.refresh()
        } catch {
            hookActionError = copy.hookActionFailed(error.localizedDescription)
        }
    }

    private func enableNotifications() {
        guard !isEnablingNotifications else { return }
        isEnablingNotifications = true
        notificationActionError = nil

        Task {
            let enabled = await notifications.enable()
            isEnablingNotifications = false
            if !enabled {
                notificationActionError = copy.notificationPermissionDenied
            }
        }
    }
}

private struct TaskCenterHeader: View {
    let snapshot: TaskCenterSnapshot
    let copy: TaskCenterCopy

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(copy.taskCenterTitle)
                    .font(.system(size: 17, weight: .semibold))

                Text(copy.summary(
                    needsAttention: snapshot.needsAttentionCount,
                    running: snapshot.runningCount
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()

            TaskCenterCountBadge(
                value: snapshot.needsAttentionCount,
                label: copy.needsAttentionShort,
                color: CodexStatusPalette.danger
            )

            TaskCenterCountBadge(
                value: snapshot.runningCount,
                label: copy.runningShort,
                color: CodexStatusPalette.warning
            )

            TaskCenterCountBadge(
                value: snapshot.readyCount,
                label: copy.waitingShort,
                color: CodexStatusPalette.ok
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct TaskCenterCountBadge: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            Text(value, format: .number)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? color : Color.secondary)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 36)
        .accessibilityElement(children: .combine)
    }
}

private struct TaskCenterRecordList: View {
    let snapshot: TaskCenterSnapshot
    let selectedTaskKey: String?
    let now: Date
    let copy: TaskCenterCopy

    private var runningRecords: [TaskActivityRecord] {
        snapshot.records.filter { $0.state == .running }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                TaskCenterSection(
                    title: copy.needsAttentionSection,
                    activeCount: snapshot.needsAttentionCount,
                    records: snapshot.needsAttentionRecords,
                    selectedTaskKey: selectedTaskKey,
                    now: now,
                    copy: copy
                )

                TaskCenterSection(
                    title: copy.runningSection,
                    activeCount: snapshot.runningCount,
                    records: runningRecords,
                    selectedTaskKey: selectedTaskKey,
                    now: now,
                    copy: copy,
                    staleCount: snapshot.staleRecords.count
                )

                TaskCenterSection(
                    title: copy.waitingInputSection,
                    activeCount: snapshot.readyCount,
                    records: snapshot.readyRecords,
                    selectedTaskKey: selectedTaskKey,
                    now: now,
                    copy: copy
                )
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 1)
            .onChange(of: selectedTaskKey) { _, taskKey in
                scrollToSelection(taskKey, using: proxy, animated: true)
            }
            .onAppear {
                scrollToSelection(selectedTaskKey, using: proxy, animated: false)
            }
        }
    }

    private func scrollToSelection(
        _ taskKey: String?,
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let taskKey else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(taskKey, anchor: .center)
                }
            } else {
                proxy.scrollTo(taskKey, anchor: .center)
            }
        }
    }
}

private struct TaskCenterSection: View {
    let title: String
    let activeCount: Int
    let records: [TaskActivityRecord]
    let selectedTaskKey: String?
    let now: Date
    let copy: TaskCenterCopy
    var staleCount = 0

    var body: some View {
        Section {
            if records.isEmpty {
                Text(copy.emptySection)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 5)
                    .accessibilityLabel("\(title)，\(copy.emptySection)")
            } else {
                ForEach(records) { record in
                    TaskActivityRow(
                        record: record,
                        isSelected: selectedTaskKey == record.taskKey,
                        now: now,
                        copy: copy
                    )
                    .id(record.taskKey)
                    .listRowBackground(
                        selectedTaskKey == record.taskKey
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(title)
                Text(activeCount, format: .number)
                    .monospacedDigit()

                if staleCount > 0 {
                    Text(copy.staleCount(staleCount))
                        .foregroundStyle(CodexStatusPalette.warning)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .accessibilityElement(children: .combine)
        }
    }
}

private struct TaskActivityRow: View {
    let record: TaskActivityRecord
    let isSelected: Bool
    let now: Date
    let copy: TaskCenterCopy

    private var statusColor: Color {
        if record.isStale { return .secondary }
        switch record.state {
        case .needsAttention:
            return CodexStatusPalette.danger
        case .running:
            return CodexStatusPalette.warning
        case .ready:
            return CodexStatusPalette.ok
        }
    }

    private var metadata: String {
        var parts = [copy.phase(record.phase)]
        if let model = record.model, !model.isEmpty {
            parts.append(model)
        }
        parts.append(copy.relativeTime(record.updatedAt, relativeTo: now))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    if record.isStale {
                        Text(copy.staleBadge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CodexStatusPalette.warning)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(CodexStatusPalette.warning.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Text(metadata)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(copy.recordAccessibility(record, relativeTo: now))
            .accessibilityValue(isSelected ? copy.selected : "")

            Spacer(minLength: 8)

            Button(copy.openCodex) {
                CodexApplicationActivator.activate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint(copy.openCodexHint)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct TaskCenterHookBanner: View {
    let state: CodexHookInstallState
    let errorMessage: String?
    let copy: TaskCenterCopy
    let action: () -> Void

    private var canAct: Bool {
        switch state {
        case .missing, .needsUpdate, .error:
            return true
        case .checking, .installed:
            return false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if state == .checking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel(copy.hookChecking)
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexStatusPalette.warning)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(copy.hookTitle(for: state))
                    .font(.system(size: 12, weight: .semibold))

                Text(errorMessage ?? copy.hookSetupDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(errorMessage == nil ? Color.secondary : CodexStatusPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if canAct {
                Button(copy.hookButton(for: state), action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CodexStatusPalette.warning.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}

private struct TaskCenterNotificationBanner: View {
    let isEnabling: Bool
    let errorMessage: String?
    let copy: TaskCenterCopy
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(copy.notificationTitle)
                    .font(.system(size: 12, weight: .semibold))

                Text(errorMessage ?? copy.notificationDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(errorMessage == nil ? Color.secondary : CodexStatusPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: action) {
                if isEnabling {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(copy.enablingNotifications)
                } else {
                    Text(copy.enableNotifications)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isEnabling)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityElement(children: .contain)
    }
}

private struct TaskCenterInfoBanner: View {
    let symbolName: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.06))
        .accessibilityElement(children: .combine)
    }
}

private struct TaskCenterUnavailableView: View {
    let title: String
    let detail: String
    let symbolName: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
        } description: {
            Text(detail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

@MainActor
private enum CodexApplicationActivator {
    static func activate() {
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.openai.codex"
        }) {
            _ = app.activate(options: [.activateAllWindows])
            return
        }

        guard let appURL = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }
}

private struct TaskCenterCopy {
    let isChinese: Bool

    var accessibilitySeparator: String { isChinese ? "，" : ", " }

    var taskCenterTitle: String { L.taskCenterTitle }
    var needsAttentionShort: String { L.taskCenterNeedsAttentionShort }
    var runningShort: String { L.taskCenterRunningShort }
    var waitingShort: String { L.taskCenterWaitingShort }
    var needsAttentionSection: String { L.taskCenterNeedsAttentionSection }
    var runningSection: String { L.taskCenterRunningSection }
    var waitingInputSection: String { L.taskCenterWaitingInputSection }
    var emptySection: String { L.taskCenterEmptySection }
    var noRunningTasks: String { L.taskCenterNoRunningTasks }
    var noTaskStatusReceived: String { L.taskCenterNoTaskStatusReceived }
    var openTaskCenterDetail: String { L.taskCenterOpenDetail }
    var openTaskCenterHint: String { L.taskCenterOpenHint }
    var openCodex: String { L.taskCenterOpenCodex }
    var openCodexHint: String { L.taskCenterOpenCodexHint }
    var selected: String { L.taskCenterSelected }
    var staleBadge: String { L.taskCenterStaleBadge }
    var hookSummaryDetail: String { L.taskCenterHookSummaryDetail }
    var hookChecking: String { L.taskCenterHookChecking }
    var hookSetupDetail: String { L.taskCenterHookSetupDetail }
    var hookBlockingDetail: String { L.taskCenterHookBlockingDetail }
    var noEventsDetail: String { L.taskCenterNoEventsDetail }
    var legacyFallbackDetail: String { L.taskCenterLegacyFallbackDetail }
    var notificationTitle: String { L.taskCenterNotificationTitle }
    var notificationDetail: String { L.taskCenterNotificationDetail }
    var enableNotifications: String { L.taskCenterEnableNotifications }
    var enablingNotifications: String { L.taskCenterEnablingNotifications }
    var notificationPermissionDenied: String { L.taskCenterNotificationPermissionDenied }

    func summary(needsAttention: Int, running: Int) -> String {
        L.taskCenterSummary(needsAttention: needsAttention, running: running)
    }

    func phase(_ phase: TaskActivityPhase) -> String {
        L.taskCenterPhase(phase)
    }

    func state(_ state: TaskActivityState) -> String {
        L.taskCenterState(state)
    }

    func relativeTime(_ date: Date, relativeTo now: Date) -> String {
        L.taskCenterRelativeTime(date, relativeTo: now)
    }

    func staleCount(_ count: Int) -> String {
        L.taskCenterStaleCount(count)
    }

    func unreadableRecords(_ count: Int) -> String {
        L.taskCenterUnreadableRecords(count)
    }

    func hookTitle(for state: CodexHookInstallState) -> String {
        L.taskCenterHookTitle(for: state)
    }

    func hookButton(for state: CodexHookInstallState) -> String {
        L.taskCenterHookButton(for: state)
    }

    func hookActionFailed(_ reason: String) -> String {
        L.taskCenterHookActionFailed(reason)
    }

    func recordAccessibility(_ record: TaskActivityRecord, relativeTo now: Date) -> String {
        var parts = [
            state(record.state),
            record.projectName,
            phase(record.phase)
        ]
        if let model = record.model, !model.isEmpty {
            parts.append(model)
        }
        if record.isStale {
            parts.append(staleBadge)
        }
        parts.append(relativeTime(record.updatedAt, relativeTo: now))
        return parts.joined(separator: accessibilitySeparator)
    }

}
