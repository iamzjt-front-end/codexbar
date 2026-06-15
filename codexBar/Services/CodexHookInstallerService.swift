import Combine
import Foundation

enum CodexHookInstallState: Equatable {
    case checking
    case missing
    case needsUpdate
    case installed
    case error(String)

    var needsAction: Bool {
        switch self {
        case .missing, .needsUpdate, .error:
            return true
        case .checking, .installed:
            return false
        }
    }
}

private struct CodexHookSpec {
    let event: String
    let matcher: String?
    let scriptArguments: [String]
    let statusMessage: String
}

@MainActor
final class CodexHookInstallerService: ObservableObject {
    static let shared = CodexHookInstallerService()

    @Published private(set) var state: CodexHookInstallState = .checking
    @Published private(set) var lastBackupPath: String?

    let hooksURL: URL
    let scriptURL: URL
    private let bundledScriptURL: URL?

    private var timer: AnyCancellable?
    private var didAttemptAutomaticMigration = false

    private static let hookScriptName = "codexbar-session-status-hook.py"
    private static let hookIdentity = "codexbar-session-status-hook.py"
    private static let hookTimeout = 2

    // Keep hooks on low-frequency conversation events. Tool hooks can receive
    // large payloads and should not sit on Codex's main turn path just to update
    // the menu bar lights.
    private static let specs: [CodexHookSpec] = [
        CodexHookSpec(
            event: "SessionStart",
            matcher: "compact",
            scriptArguments: ["SessionStart", "compact"],
            statusMessage: "Marking CodexAppBar compacting"
        ),
        CodexHookSpec(
            event: "SessionStart",
            matcher: "startup|resume|clear",
            scriptArguments: ["SessionStart"],
            statusMessage: "Syncing CodexAppBar status"
        ),
        CodexHookSpec(
            event: "UserPromptSubmit",
            matcher: nil,
            scriptArguments: ["UserPromptSubmit"],
            statusMessage: "Marking CodexAppBar running"
        ),
        CodexHookSpec(
            event: "PermissionRequest",
            matcher: "*",
            scriptArguments: ["PermissionRequest"],
            statusMessage: "Marking CodexAppBar attention"
        ),
        CodexHookSpec(
            event: "Stop",
            matcher: nil,
            scriptArguments: ["Stop"],
            statusMessage: "Marking CodexAppBar ready"
        )
    ]

    private init() {
        let home: URL
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: pwDir))
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        hooksURL = home.appendingPathComponent(".codex/hooks.json")
        scriptURL = home
            .appendingPathComponent(".codex/codexbar")
            .appendingPathComponent(Self.hookScriptName)
        bundledScriptURL = Bundle.main.url(
            forResource: Self.hookScriptName.replacingOccurrences(of: ".py", with: ""),
            withExtension: "py"
        )
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    func refresh() {
        do {
            try syncScriptIfNeeded()
            guard FileManager.default.fileExists(atPath: hooksURL.path) else {
                state = .missing
                return
            }
            var root = try readRootObject()
            let currentState = installState(in: root, expectedScriptPath: scriptURL.path)
            if currentState == .needsUpdate,
               !didAttemptAutomaticMigration {
                didAttemptAutomaticMigration = true
                try writeMergedRootObject(from: root, backupExisting: true)
                root = try readRootObject()
                state = installState(in: root, expectedScriptPath: scriptURL.path)
                return
            }
            state = currentState
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func install() throws {
        try syncScriptIfNeeded()
        let root = try readRootObjectIfPresent()
        try writeMergedRootObject(from: root, backupExisting: true)
        refresh()
    }

    private func syncScriptIfNeeded() throws {
        guard let bundledScriptURL else {
            throw CodexHookInstallerError.scriptMissing
        }

        let fileManager = FileManager.default
        let bundledData = try Data(contentsOf: bundledScriptURL)
        if fileManager.fileExists(atPath: scriptURL.path),
           let installedData = try? Data(contentsOf: scriptURL),
           installedData == bundledData {
            return
        }

        try fileManager.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bundledData.write(to: scriptURL, options: .atomic)
    }

    private func writeMergedRootObject(from root: [String: Any], backupExisting: Bool) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if backupExisting, fileManager.fileExists(atPath: hooksURL.path) {
            let backup = backupURL()
            try fileManager.copyItem(at: hooksURL, to: backup)
            lastBackupPath = backup.path
        } else {
            lastBackupPath = nil
        }

        let updated = try mergedRootObject(root, scriptURL: scriptURL)
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }

    private func installState(in root: [String: Any], expectedScriptPath: String) -> CodexHookInstallState {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return .missing
        }

        let hasAnyCodexBarHook = hooks.values.contains { value in
            containsCodexBarHook(in: value)
        }

        let hasAllExpectedHooks = Self.specs.allSatisfy { spec in
            guard let entries = hooks[spec.event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard matcherMatches(entry["matcher"] as? String, expected: spec.matcher),
                      let hookItems = entry["hooks"] as? [[String: Any]] else { return false }
                return hookItems.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return command.contains(expectedScriptPath)
                        && spec.scriptArguments.allSatisfy { command.contains($0) }
                }
            }
        }

        if hasAllExpectedHooks {
            return containsUnexpectedCodexBarHook(in: hooks, expectedScriptPath: expectedScriptPath) ? .needsUpdate : .installed
        }
        return hasAnyCodexBarHook ? .needsUpdate : .missing
    }

    private func mergedRootObject(_ root: [String: Any], scriptURL: URL) throws -> [String: Any] {
        var updated = root
        var hooks = (updated["hooks"] as? [String: Any]) ?? [:]

        for event in Array(hooks.keys) {
            if let entries = hooks[event] as? [[String: Any]] {
                let cleanedEntries = entries.compactMap { removeCodexBarHooks(from: $0) }
                if cleanedEntries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = cleanedEntries
                }
            }
        }

        for spec in Self.specs {
            var entries = (hooks[spec.event] as? [[String: Any]]) ?? []
            entries.append(entry(for: spec, scriptURL: scriptURL))
            hooks[spec.event] = entries
        }

        updated["hooks"] = hooks
        return updated
    }

    private func entry(for spec: CodexHookSpec, scriptURL: URL) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": command(for: spec, scriptURL: scriptURL),
                    "timeout": Self.hookTimeout,
                    "statusMessage": spec.statusMessage
                ]
            ]
        ]
        if let matcher = spec.matcher {
            entry["matcher"] = matcher
        }
        return entry
    }

    private func command(for spec: CodexHookSpec, scriptURL: URL) -> String {
        let args = spec.scriptArguments.map(Self.shellQuoted).joined(separator: " ")
        return "/usr/bin/python3 \(Self.shellQuoted(scriptURL.path)) \(args)"
    }

    private func removeCodexBarHooks(from entry: [String: Any]) -> [String: Any]? {
        guard let hookItems = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        let remaining = hookItems.filter { hook in
            guard let command = hook["command"] as? String else { return true }
            return !command.contains(Self.hookIdentity)
        }

        guard !remaining.isEmpty else { return nil }
        var updated = entry
        updated["hooks"] = remaining
        return updated
    }

    private func containsCodexBarHook(in value: Any) -> Bool {
        if let entries = value as? [[String: Any]] {
            return entries.contains { entry in
                guard let hookItems = entry["hooks"] as? [[String: Any]] else { return false }
                return hookItems.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return command.contains(Self.hookIdentity)
                }
            }
        }
        return false
    }

    private func containsUnexpectedCodexBarHook(in hooks: [String: Any], expectedScriptPath: String) -> Bool {
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let hookItems = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in hookItems {
                    guard let command = hook["command"] as? String,
                          command.contains(Self.hookIdentity) else { continue }
                    if !isExpectedCodexBarHook(
                        event: event,
                        entry: entry,
                        hook: hook,
                        command: command,
                        expectedScriptPath: expectedScriptPath
                    ) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func isExpectedCodexBarHook(
        event: String,
        entry: [String: Any],
        hook: [String: Any],
        command: String,
        expectedScriptPath: String
    ) -> Bool {
        Self.specs.contains { spec in
            spec.event == event &&
                matcherMatches(entry["matcher"] as? String, expected: spec.matcher) &&
                (hook["timeout"] as? Int ?? Self.hookTimeout) == Self.hookTimeout &&
                command.contains(expectedScriptPath) &&
                spec.scriptArguments.allSatisfy { command.contains($0) }
        }
    }

    private func matcherMatches(_ actual: String?, expected: String?) -> Bool {
        switch (actual, expected) {
        case (nil, nil):
            return true
        case let (actual?, expected?):
            return actual == expected
        default:
            return false
        }
    }

    private func readRootObjectIfPresent() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else {
            return [:]
        }
        return try readRootObject()
    }

    private func readRootObject() throws -> [String: Any] {
        let data = try Data(contentsOf: hooksURL)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw CodexHookInstallerError.invalidHooksFile
        }
        return root
    }

    private func backupURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = formatter.string(from: Date())
        return hooksURL.deletingLastPathComponent()
            .appendingPathComponent("hooks.json.bak-codexbar-\(suffix)")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum CodexHookInstallerError: LocalizedError {
    case scriptMissing
    case invalidHooksFile

    var errorDescription: String? {
        switch self {
        case .scriptMissing:
            return L.codexHookScriptMissing
        case .invalidHooksFile:
            return L.codexHookInvalidConfig
        }
    }
}
