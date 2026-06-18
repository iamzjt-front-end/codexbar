import AppKit
import Combine
import CryptoKit
import Foundation
import UserNotifications

struct AppUpdateRelease: Equatable {
    let tagName: String
    let title: String
    let releaseURL: URL
    let publishedAt: Date?
    let assetName: String
    let assetURL: URL
    let assetSize: Int64
    let assetDigest: String?

    var displayName: String {
        title.isEmpty ? tagName : title
    }
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateRelease)
    case downloading(AppUpdateRelease)
    case installing(AppUpdateRelease)
    case failed(String)
}

@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var latestRelease: AppUpdateRelease?

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/iamzjt-front-end/codexbar/releases/latest")!
    private let defaults = UserDefaults.standard
    private var activeDownloadTask: URLSessionDownloadTask?
    private var downloadObservation: NSKeyValueObservation?
    private var clearTransientTask: Task<Void, Never>?
    private var hasStarted = false

    private init() {}

    var shouldShowUpdateRow: Bool {
        switch state {
        case .idle:
            return false
        case .checking, .upToDate, .available, .downloading, .installing, .failed:
            return true
        }
    }

    var isWorking: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        case .idle, .upToDate, .available, .failed:
            return false
        }
    }

    var hasAvailableUpdate: Bool {
        if case .available = state { return true }
        return false
    }

    func startPeriodicChecks() {
        guard !hasStarted else { return }
        hasStarted = true

        Task { await checkForUpdates(silent: true) }
    }

    func checkForUpdates(silent: Bool) async {
        guard !isWorking else { return }
        clearTransientTask?.cancel()
        if !silent {
            state = .checking
        }

        do {
            let response = try await fetchLatestRelease()
            guard let release = response.installableRelease else {
                throw AppUpdateError.noInstallableAsset
            }

            latestRelease = release
            if Self.isRelease(release.tagName, newerThanBundleBuild: currentBundleVersion) {
                state = .available(release)
                notifyIfNeeded(for: release)
            } else if silent {
                switch state {
                case .available, .failed, .upToDate:
                    state = .idle
                case .idle, .checking, .downloading, .installing:
                    break
                }
            } else {
                state = .upToDate
                clearTransientStatusLater()
            }
        } catch {
            guard !silent else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func downloadAndInstallLatest() async {
        guard !isWorking else { return }

        let release: AppUpdateRelease
        if let available = availableRelease {
            release = available
        } else {
            await checkForUpdates(silent: false)
            guard let available = availableRelease else { return }
            release = available
        }

        do {
            clearTransientTask?.cancel()
            downloadProgress = 0
            state = .downloading(release)

            let archiveURL = try await downloadArchive(for: release)
            try verifyDigestIfPresent(for: archiveURL, expectedDigest: release.assetDigest)

            let stagedAppURL = try stageApp(from: archiveURL)
            try verifyStagedApp(stagedAppURL, expectedRelease: release)

            state = .installing(release)
            try launchInstaller(for: stagedAppURL)
            NSApplication.shared.terminate(nil)
        } catch {
            activeDownloadTask?.cancel()
            activeDownloadTask = nil
            downloadObservation?.invalidate()
            downloadObservation = nil
            state = .failed(error.localizedDescription)
        }
    }

    private var availableRelease: AppUpdateRelease? {
        switch state {
        case .available(let release), .downloading(let release), .installing(let release):
            return release
        case .idle, .checking, .upToDate, .failed:
            return latestRelease
        }
    }

    private var currentBundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private func fetchLatestRelease() async throws -> GitHubReleaseResponse {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexAppBar/\(currentBundleVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidReleaseResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateError.badServerStatus(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubReleaseResponse.self, from: data)
    }

    private func downloadArchive(for release: AppUpdateRelease) async throws -> URL {
        let downloadDirectory = try makeUpdateDirectory(named: "download")
        let destinationURL = downloadDirectory.appendingPathComponent(release.assetName)
        var request = URLRequest(url: release.assetURL)
        request.setValue("CodexAppBar/\(currentBundleVersion)", forHTTPHeaderField: "User-Agent")

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
                defer {
                    Task { @MainActor in
                        self?.downloadObservation?.invalidate()
                        self?.downloadObservation = nil
                        self?.activeDownloadTask = nil
                    }
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(throwing: AppUpdateError.invalidReleaseResponse)
                    return
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    continuation.resume(throwing: AppUpdateError.badServerStatus(httpResponse.statusCode))
                    return
                }
                guard let temporaryURL else {
                    continuation.resume(throwing: AppUpdateError.downloadMissingFile)
                    return
                }

                do {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            downloadObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let fraction = progress.fractionCompleted
                    if fraction.isFinite {
                        self.downloadProgress = min(max(fraction, 0), 1)
                    }
                }
            }
            activeDownloadTask = task
            task.resume()
        }
    }

    private func verifyDigestIfPresent(for archiveURL: URL, expectedDigest: String?) throws {
        guard let expectedDigest, expectedDigest.hasPrefix("sha256:") else { return }
        let expectedHash = String(expectedDigest.dropFirst("sha256:".count)).lowercased()
        let data = try Data(contentsOf: archiveURL)
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else {
            throw AppUpdateError.digestMismatch
        }
    }

    private func stageApp(from archiveURL: URL) throws -> URL {
        let stageDirectory = try makeUpdateDirectory(named: "stage")
        let extractDirectory = stageDirectory.appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        try runTool("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractDirectory.path])

        guard let appURL = findFirstApp(in: extractDirectory) else {
            throw AppUpdateError.appNotFoundInArchive
        }
        return appURL
    }

    private func verifyStagedApp(_ appURL: URL, expectedRelease release: AppUpdateRelease) throws {
        try runTool("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])

        guard let stagedBundle = Bundle(url: appURL),
              let stagedBundleID = stagedBundle.bundleIdentifier,
              stagedBundleID == Bundle.main.bundleIdentifier else {
            throw AppUpdateError.bundleIdentifierMismatch
        }

        let stagedBuild = stagedBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        guard Self.isBuild(stagedBuild, atLeastReleaseTag: release.tagName) else {
            throw AppUpdateError.stagedVersionMismatch
        }
    }

    private func launchInstaller(for stagedAppURL: URL) throws {
        let currentAppURL = Bundle.main.bundleURL
        if currentAppURL.path.contains("/AppTranslocation/") {
            throw AppUpdateError.translocatedApp
        }

        let parentURL = currentAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentURL.path) else {
            throw AppUpdateError.installLocationNotWritable(parentURL.path)
        }

        let installerDirectory = try makeUpdateDirectory(named: "installer")
        let scriptURL = installerDirectory.appendingPathComponent("install-codexbar-update.sh")
        let logURL = installerDirectory.appendingPathComponent("install.log")
        let script = """
        #!/bin/sh
        set -eu

        current_app="$1"
        new_app="$2"
        app_pid="$3"
        log_file="$4"

        {
          echo "CodexAppBar updater started: $(date)"

          i=0
          while kill -0 "$app_pid" 2>/dev/null; do
            i=$((i + 1))
            if [ "$i" -gt 120 ]; then
              echo "Timed out waiting for old app to quit"
              exit 1
            fi
            sleep 0.25
          done

          parent_dir="$(dirname "$current_app")"
          app_name="$(basename "$current_app")"
          backup_app="${parent_dir}/.${app_name}.codexbar-update-backup.$$"
          rm -rf "$backup_app"

          if [ -d "$current_app" ]; then
            mv "$current_app" "$backup_app"
          fi

          if /usr/bin/ditto "$new_app" "$current_app"; then
            /usr/bin/xattr -dr com.apple.quarantine "$current_app" 2>/dev/null || true
            /usr/bin/open "$current_app"
            rm -rf "$backup_app"
            rm -rf "$(dirname "$new_app")"
            echo "CodexAppBar updater finished: $(date)"
          else
            echo "Copy failed; restoring previous app"
            rm -rf "$current_app"
            if [ -d "$backup_app" ]; then
              mv "$backup_app" "$current_app"
              /usr/bin/open "$current_app"
            fi
            exit 1
          fi
        } >> "$log_file" 2>&1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            currentAppURL.path,
            stagedAppURL.path,
            "\(ProcessInfo.processInfo.processIdentifier)",
            logURL.path
        ]
        do {
            try process.run()
        } catch {
            throw AppUpdateError.installerLaunchFailed(error.localizedDescription)
        }
    }

    private func makeUpdateDirectory(named name: String) throws -> URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexAppBar", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let directory = cacheRoot.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func findFirstApp(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }
        return nil
    }

    private func runTool(_ launchPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppUpdateError.toolFailed((message?.isEmpty == false ? message : nil) ?? "\(launchPath) exited \(process.terminationStatus)")
        }
    }

    private func notifyIfNeeded(for release: AppUpdateRelease) {
        let key = "codexbar.lastNotifiedUpdateTag"
        guard defaults.string(forKey: key) != release.tagName else { return }
        defaults.set(release.tagName, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = L.updateNotificationTitle
        content.body = L.updateNotificationBody(release.displayName)
        content.sound = .default

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let request = UNNotificationRequest(
                identifier: "codexbar-update-\(release.tagName)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func clearTransientStatusLater() {
        clearTransientTask?.cancel()
        clearTransientTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, case .upToDate = self.state else { return }
                self.state = .idle
            }
        }
    }

    private static func isRelease(_ tagName: String, newerThanBundleBuild bundleBuild: String) -> Bool {
        compareVersionComponents(releaseComponents(from: tagName), releaseComponents(from: bundleBuild)) == .orderedDescending
    }

    private static func isBuild(_ build: String, atLeastReleaseTag tagName: String) -> Bool {
        compareVersionComponents(releaseComponents(from: build), releaseComponents(from: tagName)) != .orderedAscending
    }

    private static func releaseComponents(from value: String) -> [Int] {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let dateMatch = normalized.firstMatch(of: /(?:^v)?(\d{4})\.(\d{1,2})\.(\d{1,2})(?:\.(\d+))?$/) {
            let year = Int(dateMatch.1) ?? 0
            let month = Int(dateMatch.2) ?? 0
            let day = Int(dateMatch.3) ?? 0
            let suffix = dateMatch.4.flatMap { Int($0) } ?? 0
            return [year * 10_000 + month * 100 + day, suffix]
        }

        if let compactDateMatch = normalized.firstMatch(of: /^(\d{8})(?:\.(\d+))?$/) {
            let date = Int(compactDateMatch.1) ?? 0
            let suffix = compactDateMatch.2.flatMap { Int($0) } ?? 0
            return [date, suffix]
        }

        let components = normalized
            .split { !$0.isNumber }
            .compactMap { Int($0) }
        return components.isEmpty ? [0] : components
    }

    private static func compareVersionComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [GitHubReleaseAsset]

    var installableRelease: AppUpdateRelease? {
        let selectedAsset = assets.first { asset in
            asset.name.hasPrefix("codexAppBar-") && asset.name.hasSuffix(".zip")
        } ?? assets.first { $0.name.hasSuffix(".zip") }

        guard let asset = selectedAsset else { return nil }
        return AppUpdateRelease(
            tagName: tagName,
            title: name ?? tagName,
            releaseURL: htmlURL,
            publishedAt: publishedAt,
            assetName: asset.name,
            assetURL: asset.browserDownloadURL,
            assetSize: asset.size,
            assetDigest: asset.digest
        )
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let size: Int64
    let browserDownloadURL: URL
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

private enum AppUpdateError: LocalizedError {
    case invalidReleaseResponse
    case badServerStatus(Int)
    case noInstallableAsset
    case downloadMissingFile
    case digestMismatch
    case appNotFoundInArchive
    case bundleIdentifierMismatch
    case stagedVersionMismatch
    case translocatedApp
    case installLocationNotWritable(String)
    case toolFailed(String)
    case installerLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidReleaseResponse:
            return L.updateErrorInvalidResponse
        case .badServerStatus(let status):
            return L.updateErrorBadStatus(status)
        case .noInstallableAsset:
            return L.updateErrorNoAsset
        case .downloadMissingFile:
            return L.updateErrorDownloadMissingFile
        case .digestMismatch:
            return L.updateErrorDigestMismatch
        case .appNotFoundInArchive:
            return L.updateErrorAppNotFound
        case .bundleIdentifierMismatch:
            return L.updateErrorBundleIdentifierMismatch
        case .stagedVersionMismatch:
            return L.updateErrorStagedVersionMismatch
        case .translocatedApp:
            return L.updateErrorTranslocated
        case .installLocationNotWritable(let path):
            return L.updateErrorInstallLocationNotWritable(path)
        case .toolFailed(let message):
            return L.updateErrorToolFailed(message)
        case .installerLaunchFailed(let reason):
            return L.updateErrorInstallerLaunchFailed(reason)
        }
    }
}
