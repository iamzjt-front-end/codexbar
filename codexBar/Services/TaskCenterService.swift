import Combine
import Foundation

@MainActor
final class TaskCenterService: ObservableObject {
    static let shared = TaskCenterService()

    @Published private(set) var snapshot: TaskCenterSnapshot = .empty

    let notificationService: TaskNotificationService
    var onRequestOpenCodex: (() -> Void)?

    private let repository: TaskActivityRepository
    private let now: () -> Date
    private var started = false

    convenience init() {
        self.init(
            repository: TaskActivityRepository(),
            notificationService: TaskNotificationService.shared,
            now: Date.init
        )
    }

    init(
        repository: TaskActivityRepository,
        notificationService: TaskNotificationService,
        now: @escaping () -> Date
    ) {
        self.repository = repository
        self.notificationService = notificationService
        self.now = now

        notificationService.onOpenCodex = { [weak self] in
            self?.onRequestOpenCodex?()
        }
    }

    func start() {
        guard !started else {
            refresh()
            return
        }
        started = true
        notificationService.refreshAuthorizationStatus()
        repository.start { [weak self] result in
            self?.apply(result)
        }
    }

    func stop() {
        repository.stop()
        started = false
    }

    func refresh() {
        if started {
            repository.reload()
        } else {
            apply(repository.load())
        }
    }

    private func apply(_ result: TaskActivityLoadResult) {
        let snapshot = TaskCenterSnapshot(
            records: result.records,
            now: now(),
            staleRunningInterval: TaskActivityRepository.staleRunningInterval,
            isLegacyFallback: result.isLegacyFallback,
            unreadableCount: result.unreadableCount
        )
        self.snapshot = snapshot
        notificationService.process(snapshot: snapshot)
    }
}
