import Foundation

enum CodexRadarModelFamily: String, CaseIterable {
    case terra
    case luna
    case sol
    case unknown

    var displayName: String? {
        switch self {
        case .terra:
            return "Terra"
        case .luna:
            return "Luna"
        case .sol:
            return "Sol"
        case .unknown:
            return nil
        }
    }

    var symbolName: String {
        switch self {
        case .terra:
            return "globe.americas"
        case .luna:
            return "moon"
        case .sol:
            return "sun.max"
        case .unknown:
            return "cpu"
        }
    }

    nonisolated var sortOrder: Int {
        switch self {
        case .sol:
            return 0
        case .terra:
            return 1
        case .luna:
            return 2
        case .unknown:
            return 3
        }
    }

    static func resolve(model: String?, label: String?, id: String?) -> Self {
        let values = [model, label, id].compactMap { $0 }

        for family in [Self.terra, .luna, .sol] {
            if values.contains(where: { tokens(in: $0).contains(family.rawValue) }) {
                return family
            }
        }

        return .unknown
    }

    private static func tokens(in value: String) -> [String] {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

struct CodexRadarMatrixColumn: Identifiable, Hashable {
    let id: String
    let label: String
    let sortOrder: Int
}

struct CodexRadarMatrixCell: Identifiable {
    let id: String
    let sourceID: String
    let rowID: String
    let rowName: String
    let family: CodexRadarModelFamily
    let effort: String
    let score: Double
    let entry: CodexRadarModelIQEntry

    var displayName: String {
        "\(rowName) \(effort)"
    }

    var passCountText: String? {
        guard let passed = entry.passed, let tasks = entry.tasks else { return nil }
        return "\(passed)/\(tasks)"
    }
}

struct CodexRadarMatrixRow: Identifiable {
    let id: String
    let displayName: String
    let family: CodexRadarModelFamily
    let cellsByEffort: [String: CodexRadarMatrixCell]

    func cell(for effort: String) -> CodexRadarMatrixCell? {
        cellsByEffort[effort]
    }
}

struct CodexRadarMatrix {
    let columns: [CodexRadarMatrixColumn]
    let rows: [CodexRadarMatrixRow]
    let rankedCellIDs: [String]

    var bestCellID: String? {
        rankedCellIDs.first
    }

    var cells: [CodexRadarMatrixCell] {
        rows.flatMap { row in
            columns.compactMap { row.cell(for: $0.id) }
        }
    }

    var signature: String {
        cells
            .map { "\($0.id):\(CodexRadarPresentation.scoreText($0.score))" }
            .joined(separator: "|")
    }

    func cell(id: String?) -> CodexRadarMatrixCell? {
        guard let id else { return nil }
        return cells.first { $0.id == id }
    }

    func rank(of cell: CodexRadarMatrixCell) -> Int? {
        guard let index = rankedCellIDs.firstIndex(of: cell.id) else { return nil }
        return index + 1
    }
}

enum CodexRadarPresentation {
    static let standardEfforts = ["low", "medium", "high", "xhigh", "max"]
    private static let rankingEfforts = ["max", "xhigh", "high", "medium", "low"]

    private static let effortLabels: [String: String] = [
        "max": "max",
        "xhigh": "xh",
        "high": "high",
        "medium": "med",
        "low": "low"
    ]

    nonisolated private static let effortOrder = Dictionary(
        uniqueKeysWithValues: rankingEfforts.enumerated().map { ($0.element, $0.offset) }
    )

    static func matrix(from modelIQ: CodexRadarModelIQ?) -> CodexRadarMatrix {
        guard let modelIQ else {
            return CodexRadarMatrix(columns: standardColumns, rows: [], rankedCellIDs: [])
        }

        var cellsByID: [String: CodexRadarMatrixCell] = [:]

        for sourceID in modelIQ.comparisons.keys.sorted() {
            guard let comparison = modelIQ.comparisons[sourceID],
                  let entry = comparison.latest,
                  let cell = makeCell(
                    sourceID: sourceID,
                    entry: entry,
                    model: comparison.model ?? entry.model,
                    effort: comparison.reasoningEffort ?? entry.reasoningEffort,
                    label: comparison.label
                  ) else {
                continue
            }
            if cellsByID[cell.id] == nil {
                cellsByID[cell.id] = cell
            }
        }

        if let latest = modelIQ.latest,
           let cell = makeCell(
            sourceID: "latest",
            entry: latest,
            model: latest.model,
            effort: latest.reasoningEffort,
            label: nil
           ) {
            cellsByID[cell.id] = cell
        }

        let extraEfforts = Set(cellsByID.values.map(\.effort))
            .subtracting(standardEfforts)
            .sorted()
        let columns = standardColumns + extraEfforts.enumerated().map { index, effort in
            CodexRadarMatrixColumn(
                id: effort,
                label: effort,
                sortOrder: standardEfforts.count + index
            )
        }

        let groupedRows = Dictionary(grouping: cellsByID.values, by: \.rowID)
        let rows = groupedRows.values.compactMap { cells -> CodexRadarMatrixRow? in
            guard let sample = cells.first else { return nil }
            return CodexRadarMatrixRow(
                id: sample.rowID,
                displayName: sample.rowName,
                family: sample.family,
                cellsByEffort: Dictionary(uniqueKeysWithValues: cells.map { ($0.effort, $0) })
            )
        }
        .sorted(by: rowOrderedBefore)

        let allCells = rows.flatMap { $0.cellsByEffort.values }
        let rankedCellIDs = allCells.sorted(by: cellOrderedBefore).map(\.id)

        return CodexRadarMatrix(columns: columns, rows: rows, rankedCellIDs: rankedCellIDs)
    }

    static func scoreText(_ score: Double) -> String {
        if abs(score - score.rounded()) < 0.0001 {
            return String(format: "%.0f", score)
        }
        return String(format: "%.1f", score)
    }

    private static var standardColumns: [CodexRadarMatrixColumn] {
        standardEfforts.enumerated().map { index, effort in
            CodexRadarMatrixColumn(
                id: effort,
                label: effortLabels[effort] ?? effort,
                sortOrder: index
            )
        }
    }

    private static func makeCell(
        sourceID: String,
        entry: CodexRadarModelIQEntry,
        model: String?,
        effort: String?,
        label: String?
    ) -> CodexRadarMatrixCell? {
        guard let score = entry.score else { return nil }

        let normalizedEffort = normalizeEffort(effort ?? effortFromLabel(label)) ?? "default"
        let family = CodexRadarModelFamily.resolve(model: model, label: label, id: sourceID)
        let identity = rowIdentity(model: model, label: label, effort: normalizedEffort, family: family)

        return CodexRadarMatrixCell(
            id: "\(identity.id)|\(normalizedEffort)",
            sourceID: sourceID,
            rowID: identity.id,
            rowName: identity.name,
            family: family,
            effort: normalizedEffort,
            score: score,
            entry: entry
        )
    }

    private static func rowIdentity(
        model: String?,
        label: String?,
        effort: String,
        family: CodexRadarModelFamily
    ) -> (id: String, name: String) {
        if let familyName = family.displayName {
            return (family.rawValue, familyName)
        }

        let rawName = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? strippedModelName(from: label, effort: effort)
            ?? "Codex"
        let displayName = formattedModelName(rawName)
        let stableID = displayName.lowercased().replacingOccurrences(of: " ", with: "-")
        return ("model:\(stableID)", displayName)
    }

    private static func formattedModelName(_ value: String) -> String {
        if value.lowercased().hasPrefix("gpt-") {
            return "GPT-" + value.dropFirst(4)
        }
        return value
    }

    private static func strippedModelName(from label: String?, effort: String) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return nil
        }
        let suffixes = [" \(effort)", "-\(effort)", "_\(effort)"]
        for suffix in suffixes where label.lowercased().hasSuffix(suffix.lowercased()) {
            return String(label.dropLast(suffix.count))
        }
        return label
    }

    private static func normalizeEffort(_ effort: String?) -> String? {
        guard let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !effort.isEmpty else {
            return nil
        }
        return effort
    }

    private static func effortFromLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        return label
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .last
            .map(String.init)
    }

    nonisolated private static func rowOrderedBefore(
        _ lhs: CodexRadarMatrixRow,
        _ rhs: CodexRadarMatrixRow
    ) -> Bool {
        if lhs.family.sortOrder != rhs.family.sortOrder {
            return lhs.family.sortOrder < rhs.family.sortOrder
        }
        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    nonisolated private static func cellOrderedBefore(
        _ lhs: CodexRadarMatrixCell,
        _ rhs: CodexRadarMatrixCell
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }

        if lhs.family.sortOrder != rhs.family.sortOrder {
            return lhs.family.sortOrder < rhs.family.sortOrder
        }

        let leftEffort = effortOrder[lhs.effort] ?? Int.max
        let rightEffort = effortOrder[rhs.effort] ?? Int.max
        if leftEffort != rightEffort { return leftEffort < rightEffort }

        let nameOrder = lhs.rowName.localizedCaseInsensitiveCompare(rhs.rowName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.sourceID < rhs.sourceID
    }
}
