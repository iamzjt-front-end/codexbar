import Foundation

enum AppVersion {
    /// 日期构建号是对外版本号；旧构建继续回退到 marketing version + build。
    nonisolated static func display(marketingVersion: String, bundleVersion: String) -> String {
        if let releaseVersion = releaseVersion(fromBundleVersion: bundleVersion) {
            return "v\(releaseVersion)"
        }

        let version = marketingVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.isEmpty { return build }
        if build.isEmpty { return "v\(version)" }
        return "v\(version) (\(build))"
    }

    /// `20260714` / `20260714.2` -> `2026.07.14` / `2026.07.14.2`。
    nonisolated static func releaseVersion(fromBundleVersion bundleVersion: String) -> String? {
        let normalized = bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let compactDate = parts.first,
              compactDate.count == 8,
              compactDate.allSatisfy(\.isNumber),
              let year = Int(compactDate.prefix(4)),
              let month = Int(compactDate.dropFirst(4).prefix(2)),
              let day = Int(compactDate.suffix(2)) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let validated = calendar.dateComponents([.year, .month, .day], from: date)
        guard validated.year == year, validated.month == month, validated.day == day else {
            return nil
        }

        var version = String(format: "%04d.%02d.%02d", year, month, day)
        if parts.count == 2 {
            guard !parts[1].isEmpty,
                  parts[1].allSatisfy(\.isNumber),
                  parts[1].first != "0" else {
                return nil
            }
            version += ".\(parts[1])"
        }
        return version
    }
}
