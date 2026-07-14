import Foundation

enum TaskActivityState: String, Codable, CaseIterable, Sendable {
    case ready
    case running
    case needsAttention = "needs_attention"

    nonisolated fileprivate var priority: Int {
        switch self {
        case .needsAttention: return 3
        case .running: return 2
        case .ready: return 1
        }
    }
}

enum TaskActivityPhase: String, Codable, CaseIterable, Sendable {
    case connecting
    case processing
    case compacting
    case awaitingPermission = "awaiting_permission"
    case waitingInput = "waiting_input"
}

struct TaskActivityRecord: Codable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let taskKey: String
    let turnKey: String?
    let eventKey: String
    let state: TaskActivityState
    let phase: TaskActivityPhase
    let projectName: String
    let model: String?
    let updatedAt: Date
    let source: String
    let isStale: Bool

    var id: String { taskKey }

    init(
        schemaVersion: Int = 2,
        taskKey: String,
        turnKey: String? = nil,
        eventKey: String,
        state: TaskActivityState,
        phase: TaskActivityPhase,
        projectName: String,
        model: String? = nil,
        updatedAt: Date,
        source: String,
        isStale: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.taskKey = taskKey
        self.turnKey = turnKey
        self.eventKey = eventKey
        self.state = state
        self.phase = phase
        self.projectName = projectName
        self.model = model
        self.updatedAt = updatedAt
        self.source = source
        self.isStale = isStale
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case taskKey
        case turnKey
        case eventKey
        case state
        case phase
        case projectName
        case model
        case updatedAt
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        taskKey = try container.decode(String.self, forKey: .taskKey)
        turnKey = try container.decodeIfPresent(String.self, forKey: .turnKey)
        eventKey = try container.decode(String.self, forKey: .eventKey)
        state = try container.decode(TaskActivityState.self, forKey: .state)
        phase = try container.decode(TaskActivityPhase.self, forKey: .phase)
        projectName = try container.decode(String.self, forKey: .projectName)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        source = try container.decode(String.self, forKey: .source)
        isStale = false

        let dateString = try container.decode(String.self, forKey: .updatedAt)
        guard let parsedDate = TaskActivityDateCoding.date(from: dateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt,
                in: container,
                debugDescription: "updatedAt must be an ISO-8601 timestamp"
            )
        }
        updatedAt = parsedDate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(taskKey, forKey: .taskKey)
        try container.encodeIfPresent(turnKey, forKey: .turnKey)
        try container.encode(eventKey, forKey: .eventKey)
        try container.encode(state, forKey: .state)
        try container.encode(phase, forKey: .phase)
        try container.encode(projectName, forKey: .projectName)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(TaskActivityDateCoding.string(from: updatedAt), forKey: .updatedAt)
        try container.encode(source, forKey: .source)
    }

    func markingStale(_ stale: Bool) -> TaskActivityRecord {
        TaskActivityRecord(
            schemaVersion: schemaVersion,
            taskKey: taskKey,
            turnKey: turnKey,
            eventKey: eventKey,
            state: state,
            phase: phase,
            projectName: projectName,
            model: model,
            updatedAt: updatedAt,
            source: source,
            isStale: stale
        )
    }
}

struct TaskCenterSnapshot: Equatable, Sendable {
    static let empty = TaskCenterSnapshot(records: [])

    let records: [TaskActivityRecord]
    let needsAttentionRecords: [TaskActivityRecord]
    let runningRecords: [TaskActivityRecord]
    let readyRecords: [TaskActivityRecord]
    let staleRecords: [TaskActivityRecord]
    let aggregateLight: CodexSessionLight
    let mostUrgent: TaskActivityRecord?
    let isLegacyFallback: Bool
    let unreadableCount: Int

    var needsAttentionCount: Int { needsAttentionRecords.count }
    var runningCount: Int { runningRecords.count }
    var readyCount: Int { readyRecords.count }
    var hasActiveTasks: Bool { mostUrgent != nil }

    init(
        records sourceRecords: [TaskActivityRecord],
        now: Date = Date(),
        staleRunningInterval: TimeInterval = 6 * 60 * 60,
        isLegacyFallback: Bool = false,
        unreadableCount: Int = 0
    ) {
        let records = sourceRecords
            .map { record in
                let stale = record.state == .running && now.timeIntervalSince(record.updatedAt) >= staleRunningInterval
                return record.markingStale(stale)
            }
            .sorted(by: Self.sortRecords)

        self.records = records
        needsAttentionRecords = records.filter { $0.state == .needsAttention }
        runningRecords = records.filter { $0.state == .running && !$0.isStale }
        readyRecords = records.filter { $0.state == .ready }
        staleRecords = records.filter(\.isStale)
        self.isLegacyFallback = isLegacyFallback
        self.unreadableCount = unreadableCount

        if let urgent = needsAttentionRecords.first {
            aggregateLight = .needsAttention
            mostUrgent = urgent
        } else if let running = runningRecords.first {
            aggregateLight = .running
            mostUrgent = running
        } else if let ready = readyRecords.first {
            aggregateLight = .ready
            mostUrgent = ready
        } else {
            aggregateLight = .offline
            mostUrgent = nil
        }
    }

    nonisolated private static func sortRecords(_ lhs: TaskActivityRecord, _ rhs: TaskActivityRecord) -> Bool {
        let lhsPriority = lhs.isStale ? 0 : lhs.state.priority
        let rhsPriority = rhs.isStale ? 0 : rhs.state.priority
        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.taskKey < rhs.taskKey
    }
}

enum TaskActivityDateCoding {
    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
