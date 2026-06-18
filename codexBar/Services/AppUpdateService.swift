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

struct AppUpdateCompletion: Equatable {
    let tagName: String
    let displayName: String
    let currentVersion: String
}

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateRelease)
    case downloading(AppUpdateRelease)
    case readyToInstall(AppUpdateRelease)
    case installing(AppUpdateRelease)
    case failed(String)
}

@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()

    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var latestRelease: AppUpdateRelease?
    @Published private(set) var completedUpdate: AppUpdateCompletion?

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/iamzjt-front-end/codexbar/releases/latest")!
    private static let releasesAtomURL = URL(string: "https://github.com/iamzjt-front-end/codexbar/releases.atom")!
    private static let latestReleasePageURL = URL(string: "https://github.com/iamzjt-front-end/codexbar/releases/latest")!
    private static let githubBaseURL = URL(string: "https://github.com")!
    private static let pendingInstallTagKey = "codexbar.pendingInstallTag"
    private static let pendingInstallNameKey = "codexbar.pendingInstallName"
    private static let pendingInstallNotifiedKey = "codexbar.pendingInstallNotifiedTag"
    private let defaults = UserDefaults.standard
    private var activeDownloadTask: URLSessionDownloadTask?
    private var downloadObservation: NSKeyValueObservation?
    private var clearTransientTask: Task<Void, Never>?
    private var stagedUpdate: (release: AppUpdateRelease, appURL: URL)?
    private var hasStarted = false

    private init() {}

    var shouldShowUpdateRow: Bool {
        switch state {
        case .idle:
            return false
        case .checking, .upToDate, .available, .downloading, .readyToInstall, .installing, .failed:
            return true
        }
    }

    var isWorking: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        case .idle, .upToDate, .available, .readyToInstall, .failed:
            return false
        }
    }

    var hasAvailableUpdate: Bool {
        if case .available = state { return true }
        if case .readyToInstall = state { return true }
        return false
    }

    var hasReadyUpdate: Bool {
        if case .readyToInstall = state { return true }
        return false
    }

    var currentVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = currentBundleVersion
        if version.isEmpty {
            return build
        }
        return "v\(version) (\(build))"
    }

    func startPeriodicChecks() {
        guard !hasStarted else { return }
        hasStarted = true

        detectCompletedInstallIfNeeded()
        Task { await checkForUpdates(silent: true) }
    }

    func checkForUpdates(silent: Bool) async {
        guard !isWorking else { return }
        if case .readyToInstall = state { return }
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
                if let stagedUpdate, stagedUpdate.release.tagName == release.tagName {
                    state = .readyToInstall(release)
                    return
                }
                state = .available(release)
                notifyIfNeeded(for: release)
            } else if silent {
                switch state {
                case .available, .failed, .upToDate:
                    stagedUpdate = nil
                    state = .idle
                case .idle, .checking, .downloading, .readyToInstall, .installing:
                    break
                }
            } else {
                stagedUpdate = nil
                state = .upToDate
                clearTransientStatusLater()
            }
        } catch {
            guard !silent else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func downloadLatest() async {
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
            stagedUpdate = nil
            state = .downloading(release)

            let archiveURL = try await downloadArchive(for: release)
            try verifyDigestIfPresent(for: archiveURL, expectedDigest: release.assetDigest)

            let stagedAppURL = try stageApp(from: archiveURL)
            try verifyStagedApp(stagedAppURL, expectedRelease: release)

            downloadProgress = 1
            stagedUpdate = (release: release, appURL: stagedAppURL)
            state = .readyToInstall(release)
        } catch {
            activeDownloadTask?.cancel()
            activeDownloadTask = nil
            downloadObservation?.invalidate()
            downloadObservation = nil
            stagedUpdate = nil
            state = .failed(error.localizedDescription)
        }
    }

    func installDownloadedUpdate() async {
        guard !isWorking else { return }
        guard let stagedUpdate else {
            await downloadLatest()
            return
        }

        do {
            clearTransientTask?.cancel()
            state = .installing(stagedUpdate.release)
            try launchInstaller(for: stagedUpdate.appURL)
            rememberPendingInstall(for: stagedUpdate.release)
            NSApplication.shared.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismissCompletedUpdate() {
        completedUpdate = nil
        defaults.removeObject(forKey: Self.pendingInstallTagKey)
        defaults.removeObject(forKey: Self.pendingInstallNameKey)
        defaults.removeObject(forKey: Self.pendingInstallNotifiedKey)
    }

    private var availableRelease: AppUpdateRelease? {
        switch state {
        case .available(let release), .downloading(let release), .readyToInstall(let release), .installing(let release):
            return release
        case .idle, .checking, .upToDate, .failed:
            return latestRelease
        }
    }

    private var currentBundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private func rememberPendingInstall(for release: AppUpdateRelease) {
        defaults.set(release.tagName, forKey: Self.pendingInstallTagKey)
        defaults.set(release.displayName, forKey: Self.pendingInstallNameKey)
        defaults.removeObject(forKey: Self.pendingInstallNotifiedKey)
        defaults.synchronize()
    }

    private func detectCompletedInstallIfNeeded() {
        guard let tagName = defaults.string(forKey: Self.pendingInstallTagKey),
              !tagName.isEmpty,
              Self.isBuild(currentBundleVersion, atLeastReleaseTag: tagName) else {
            return
        }

        let displayName = defaults.string(forKey: Self.pendingInstallNameKey) ?? tagName
        let completion = AppUpdateCompletion(
            tagName: tagName,
            displayName: displayName,
            currentVersion: currentVersionDisplay
        )
        completedUpdate = completion
        notifyCompletedInstallIfNeeded(completion)
    }

    private func fetchLatestRelease() async throws -> GitHubReleaseResponse {
        do {
            return try await fetchLatestReleaseFromAPI()
        } catch {
            return try await fetchLatestReleaseFromWeb()
        }
    }

    private func fetchLatestReleaseFromAPI() async throws -> GitHubReleaseResponse {
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

    private func fetchLatestReleaseFromWeb() async throws -> GitHubReleaseResponse {
        do {
            return try await fetchLatestReleaseFromAtom()
        } catch {
            return try await fetchLatestReleaseFromLatestPage()
        }
    }

    private func fetchLatestReleaseFromAtom() async throws -> GitHubReleaseResponse {
        var request = URLRequest(url: Self.releasesAtomURL)
        request.timeoutInterval = 20
        request.setValue("CodexAppBar/\(currentBundleVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let xml = String(data: data, encoding: .utf8),
              let href = Self.firstMatch(
                in: xml,
                pattern: #"<link rel="alternate"[^>]+href="([^"]+/releases/tag/[^"]+)""#
              ),
              let htmlURL = URL(string: href),
              let tagName = Self.releaseTagName(from: htmlURL) else {
            throw AppUpdateError.invalidReleaseResponse
        }

        let asset = try await fetchInstallableAssetFromWeb(tagName: tagName)
        return GitHubReleaseResponse(
            tagName: tagName,
            name: "CodexAppBar \(tagName)",
            htmlURL: htmlURL,
            publishedAt: nil,
            assets: [asset]
        )
    }

    private func fetchLatestReleaseFromLatestPage() async throws -> GitHubReleaseResponse {
        var latestRequest = URLRequest(url: Self.latestReleasePageURL)
        latestRequest.timeoutInterval = 20
        latestRequest.setValue("CodexAppBar/\(currentBundleVersion)", forHTTPHeaderField: "User-Agent")

        let (_, latestResponse) = try await URLSession.shared.data(for: latestRequest)
        guard let httpResponse = latestResponse as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode),
              let finalURL = httpResponse.url,
              let tagName = Self.releaseTagName(from: finalURL) else {
            throw AppUpdateError.invalidReleaseResponse
        }

        let asset = try await fetchInstallableAssetFromWeb(tagName: tagName)
        return GitHubReleaseResponse(
            tagName: tagName,
            name: "CodexAppBar \(tagName)",
            htmlURL: finalURL,
            publishedAt: nil,
            assets: [asset]
        )
    }

    private func fetchInstallableAssetFromWeb(tagName: String) async throws -> GitHubReleaseAsset {
        let escapedTag = tagName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tagName
        guard let assetsURL = URL(string: "https://github.com/iamzjt-front-end/codexbar/releases/expanded_assets/\(escapedTag)") else {
            throw AppUpdateError.invalidReleaseResponse
        }

        var request = URLRequest(url: assetsURL)
        request.timeoutInterval = 20
        request.setValue("CodexAppBar/\(currentBundleVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw AppUpdateError.invalidReleaseResponse
        }

        guard let href = Self.firstMatch(
            in: html,
            pattern: #"href="([^"]*/releases/download/[^"]*/codexAppBar-[^"]+\.zip)""#
        ) else {
            throw AppUpdateError.noInstallableAsset
        }
        guard let assetURL = URL(string: href, relativeTo: Self.githubBaseURL)?.absoluteURL else {
            throw AppUpdateError.invalidReleaseResponse
        }

        let digest = Self.firstMatch(in: html, pattern: #"(sha256:[a-fA-F0-9]{64})"#)
        let size = await fetchAssetSize(at: assetURL)
        return GitHubReleaseAsset(
            name: assetURL.lastPathComponent,
            size: size,
            browserDownloadURL: assetURL,
            digest: digest
        )
    }

    private func fetchAssetSize(at url: URL) async -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue("CodexAppBar/\(currentBundleVersion)", forHTTPHeaderField: "User-Agent")

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode),
              httpResponse.expectedContentLength > 0 else {
            return 0
        }
        return httpResponse.expectedContentLength
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

    private func notifyCompletedInstallIfNeeded(_ completion: AppUpdateCompletion) {
        guard defaults.string(forKey: Self.pendingInstallNotifiedKey) != completion.tagName else { return }
        defaults.set(completion.tagName, forKey: Self.pendingInstallNotifiedKey)

        let content = UNMutableNotificationContent()
        content.title = L.updateInstalledNotificationTitle
        content.body = L.updateInstalledNotificationBody(completion.tagName)
        content.sound = .default

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let request = UNNotificationRequest(
                identifier: "codexbar-update-installed-\(completion.tagName)",
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

    private static func releaseTagName(from url: URL) -> String? {
        let components = url.pathComponents
        guard let tagIndex = components.firstIndex(of: "tag"),
              components.indices.contains(tagIndex + 1) else {
            return nil
        }
        let tagName = components[tagIndex + 1]
        return tagName.isEmpty ? nil : tagName
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        let captureIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let captureRange = Range(match.range(at: captureIndex), in: text) else { return nil }
        return String(text[captureRange])
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
