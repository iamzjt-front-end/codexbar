import Darwin
import AppKit
import Combine
import Foundation

struct TaskActivityLoadResult: Equatable {
    let records: [TaskActivityRecord]
    let isLegacyFallback: Bool
    let unreadableCount: Int
}

protocol TaskActivityDirectoryMonitoring: AnyObject {
    func start(onChange: @escaping (_ requiresRearm: Bool) -> Void) throws
    func stop()
}

final class DispatchTaskActivityDirectoryMonitor: TaskActivityDirectoryMonitoring {
    private let directoryURL: URL
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func start(onChange: @escaping (_ requiresRearm: Bool) -> Void) throws {
        guard source == nil else { return }

        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        self.descriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            let events = self?.source?.data ?? []
            onChange(events.contains(.delete) || events.contains(.rename))
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        stop()
    }
}

@MainActor
final class TaskActivityRepository {
    typealias MonitorFactory = (URL) -> TaskActivityDirectoryMonitoring

    static let staleRunningInterval: TimeInterval = 6 * 60 * 60
    static let retentionInterval: TimeInterval = 24 * 60 * 60
    static let legacyTaskKey = "b4a76c8bea495cad717bd8d3aa4c7b1e07731063a47553a2fbfdb02318845a25"
    private static let maximumRecordBytes = 64 * 1_024
    private static let maximumFutureClockSkew: TimeInterval = 5 * 60

    let sessionsURL: URL
    let legacyStatusURL: URL

    private let fileManager: FileManager
    private let now: () -> Date
    private let monitorFactory: MonitorFactory
    private let decoder = JSONDecoder()

    private var monitor: TaskActivityDirectoryMonitoring?
    private var debounceWorkItem: DispatchWorkItem?
    private var boundaryWorkItem: DispatchWorkItem?
    private var wakeCancellable: AnyCancellable?
    private var onChange: ((TaskActivityLoadResult) -> Void)?
    private var started = false
    private var monitorNeedsRearm = false

    convenience init() {
        let home = Self.userHomeDirectory()
        let root = home.appendingPathComponent(".codex/codexbar", isDirectory: true)
        self.init(
            sessionsURL: root.appendingPathComponent("sessions", isDirectory: true),
            legacyStatusURL: root.appendingPathComponent("session_status.json")
        )
    }

    init(
        sessionsURL: URL,
        legacyStatusURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionsURL = sessionsURL
        self.legacyStatusURL = legacyStatusURL
        self.fileManager = fileManager
        self.now = now
        monitorFactory = { DispatchTaskActivityDirectoryMonitor(directoryURL: $0) }
    }

    init(
        sessionsURL: URL,
        legacyStatusURL: URL,
        fileManager: FileManager,
        now: @escaping () -> Date,
        monitorFactory: @escaping MonitorFactory
    ) {
        self.sessionsURL = sessionsURL
        self.legacyStatusURL = legacyStatusURL
        self.fileManager = fileManager
        self.now = now
        self.monitorFactory = monitorFactory
    }

    func start(onChange: @escaping (TaskActivityLoadResult) -> Void) {
        self.onChange = onChange
        guard !started else {
            reload()
            return
        }
        started = true

        secureRuntimeDirectories()
        installMonitor()
        wakeCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }

        reload()
    }

    func stop() {
        started = false
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        boundaryWorkItem?.cancel()
        boundaryWorkItem = nil
        monitor?.stop()
        monitor = nil
        monitorNeedsRearm = false
        wakeCancellable?.cancel()
        wakeCancellable = nil
    }

    @discardableResult
    func reload() -> TaskActivityLoadResult {
        let result = load()
        scheduleNextBoundary(for: result.records)
        onChange?(result)
        if started, monitor == nil {
            installMonitor()
        }
        return result
    }

    func load() -> TaskActivityLoadResult {
        let currentDate = now()
        var unreadableDuringLoad = 0
        secureRuntimeDirectories()

        var recordsByTask: [String: TaskActivityRecord] = [:]
        for fileURL in sessionJSONFiles() {
            do {
                let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= Self.maximumRecordBytes else {
                    throw TaskActivityRepositoryError.invalidRecord
                }
                let data = try Data(contentsOf: fileURL)
                let record = try decoder.decode(TaskActivityRecord.self, from: data)
                try validate(record, fileURL: fileURL, at: currentDate)

                if currentDate.timeIntervalSince(record.updatedAt) >= Self.retentionInterval {
                    try? fileManager.removeItem(at: fileURL)
                    continue
                }

                if let current = recordsByTask[record.taskKey], current.updatedAt >= record.updatedAt {
                    continue
                }
                recordsByTask[record.taskKey] = record
            } catch {
                if !quarantine(fileURL, at: currentDate) {
                    unreadableDuringLoad += 1
                }
            }
        }

        cleanupQuarantine(at: currentDate)
        let quarantineCount = currentQuarantineCount()
        let records = Array(recordsByTask.values)
        if !records.isEmpty {
            return TaskActivityLoadResult(
                records: records,
                isLegacyFallback: false,
                unreadableCount: quarantineCount + unreadableDuringLoad
            )
        }

        do {
            if let legacy = try loadLegacyRecord(at: currentDate) {
                return TaskActivityLoadResult(
                    records: [legacy],
                    isLegacyFallback: true,
                    unreadableCount: quarantineCount + unreadableDuringLoad
                )
            }
        } catch {
            unreadableDuringLoad += 1
        }

        return TaskActivityLoadResult(
            records: [],
            isLegacyFallback: false,
            unreadableCount: quarantineCount + unreadableDuringLoad
        )
    }

    private func installMonitor() {
        monitor?.stop()
        let candidate = monitorFactory(sessionsURL)
        do {
            try candidate.start { [weak self] requiresRearm in
                Task { @MainActor in
                    self?.scheduleDebouncedReload(requiresRearm: requiresRearm)
                }
            }
            monitor = candidate
        } catch {
            monitor = nil
        }
    }

    private func scheduleDebouncedReload(requiresRearm: Bool) {
        guard started else { return }
        monitorNeedsRearm = monitorNeedsRearm || requiresRearm
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            let shouldRearm = self.monitorNeedsRearm
            self.monitorNeedsRearm = false
            self.reload()
            if shouldRearm {
                self.installMonitor()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func scheduleNextBoundary(for records: [TaskActivityRecord]) {
        boundaryWorkItem?.cancel()
        boundaryWorkItem = nil

        let currentDate = now()
        let boundaries = records.flatMap { record -> [Date] in
            var dates = [record.updatedAt.addingTimeInterval(Self.retentionInterval)]
            if record.state == .running {
                dates.append(record.updatedAt.addingTimeInterval(Self.staleRunningInterval))
            }
            return dates.filter { $0 > currentDate }
        }
        guard let nextBoundary = boundaries.min() else { return }

        let delay = max(0.05, nextBoundary.timeIntervalSince(currentDate) + 0.05)
        let workItem = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        boundaryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func sessionJSONFiles() -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { url in
            guard url.pathExtension.lowercased() == "json" else { return false }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private func validate(_ record: TaskActivityRecord, fileURL: URL, at date: Date) throws {
        guard record.schemaVersion == 2,
              !record.taskKey.isEmpty,
              record.taskKey.count <= 128,
              record.taskKey == fileURL.deletingPathExtension().lastPathComponent,
              !record.eventKey.isEmpty,
              record.eventKey.count <= 256,
              record.turnKey.map({ !$0.isEmpty && $0.count <= 128 }) ?? true,
              !record.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.projectName.count <= 120,
              !record.projectName.containsControlCharacters,
              record.model.map({ !$0.isEmpty && $0.count <= 160 }) ?? true,
              record.model.map({ !$0.containsControlCharacters }) ?? true,
              !record.source.isEmpty,
              record.source.count <= 80,
              !record.source.containsControlCharacters,
              record.updatedAt.timeIntervalSince(date) <= Self.maximumFutureClockSkew else {
            throw TaskActivityRepositoryError.invalidRecord
        }
    }

    private var quarantineURL: URL {
        sessionsURL.appendingPathComponent(".invalid", isDirectory: true)
    }

    @discardableResult
    private func quarantine(_ sourceURL: URL, at date: Date) -> Bool {
        do {
            try secureDirectory(at: quarantineURL)
            let timestamp = Int(date.timeIntervalSince1970 * 1_000)
            let name = "\(sourceURL.deletingPathExtension().lastPathComponent)-\(timestamp)-\(UUID().uuidString).json"
            let destinationURL = quarantineURL.appendingPathComponent(name)
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: destinationURL.path)
            return true
        } catch {
            return false
        }
    }

    private func cleanupQuarantine(at date: Date) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: quarantineURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls {
            let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let modifiedAt,
                  date.timeIntervalSince(modifiedAt) >= Self.retentionInterval else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private func currentQuarantineCount() -> Int {
        let urls = try? fileManager.contentsOfDirectory(
            at: quarantineURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return urls?.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.count ?? 0
    }

    private func loadLegacyRecord(at date: Date) throws -> TaskActivityRecord? {
        guard fileManager.fileExists(atPath: legacyStatusURL.path) else { return nil }
        let data = try Data(contentsOf: legacyStatusURL)
        let payload = try decoder.decode(LegacyTaskStatusPayload.self, from: data)
        guard let state = TaskActivityState(rawValue: payload.state ?? "") else { return nil }

        let attributes = try? fileManager.attributesOfItem(atPath: legacyStatusURL.path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let updatedAt = payload.updatedAt.flatMap(TaskActivityDateCoding.date(from:)) ?? modifiedAt ?? date
        guard date.timeIntervalSince(updatedAt) < Self.retentionInterval else { return nil }

        return TaskActivityRecord(
            taskKey: Self.legacyTaskKey,
            eventKey: "legacy-\(Int(updatedAt.timeIntervalSince1970 * 1_000))",
            state: state,
            phase: legacyPhase(state: state, source: payload.source),
            projectName: "Codex",
            updatedAt: updatedAt,
            source: payload.source ?? "legacy"
        )
    }

    private func legacyPhase(state: TaskActivityState, source: String?) -> TaskActivityPhase {
        switch state {
        case .needsAttention:
            return .awaitingPermission
        case .running:
            return source?.lowercased().contains("compact") == true ? .compacting : .processing
        case .ready:
            return source?.hasPrefix("SessionStart") == true ? .connecting : .waitingInput
        }
    }

    private static func userHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pwDir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func secureRuntimeDirectories() {
        try? secureDirectory(at: sessionsURL.deletingLastPathComponent())
        try? secureDirectory(at: sessionsURL)
    }

    private func secureDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

private struct LegacyTaskStatusPayload: Decodable {
    let state: String?
    let updatedAt: String?
    let source: String?
}

private enum TaskActivityRepositoryError: Error {
    case invalidRecord
}

private extension String {
    var containsControlCharacters: Bool {
        rangeOfCharacter(from: .controlCharacters) != nil
    }
}
