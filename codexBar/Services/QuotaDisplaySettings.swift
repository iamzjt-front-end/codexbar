import Combine
import Foundation

enum QuotaDisplayMode: String, CaseIterable, Identifiable {
    case numbers
    case bars

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .numbers: return L.quotaDisplayNumbersShort
        case .bars: return L.quotaDisplayBarsShort
        }
    }

    var label: String {
        switch self {
        case .numbers: return L.quotaDisplayNumbers
        case .bars: return L.quotaDisplayBars
        }
    }
}

enum QuotaAmountMode: String, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .used: return L.quotaAmountUsedShort
        case .remaining: return L.quotaAmountRemainingShort
        }
    }

    var label: String {
        switch self {
        case .used: return L.quotaAmountUsed
        case .remaining: return L.quotaAmountRemaining
        }
    }
}

@MainActor
final class QuotaDisplaySettings: ObservableObject {
    static let shared = QuotaDisplaySettings()

    @Published private(set) var mode: QuotaDisplayMode
    @Published private(set) var amountMode: QuotaAmountMode
    @Published private(set) var alwaysShowResetTime: Bool
    @Published private(set) var showStatusLights: Bool

    private let modeDefaultsKey = "quotaDisplayMode"
    private let amountDefaultsKey = "quotaAmountMode"
    private let alwaysShowResetTimeDefaultsKey = "quotaAlwaysShowResetTime"
    private let showStatusLightsDefaultsKey = "quotaShowStatusLights"

    private init() {
        let initialMode: QuotaDisplayMode
        if let saved = UserDefaults.standard.string(forKey: modeDefaultsKey),
           let savedMode = QuotaDisplayMode(rawValue: saved) {
            initialMode = savedMode
        } else {
            initialMode = .numbers
            UserDefaults.standard.set(initialMode.rawValue, forKey: modeDefaultsKey)
        }

        let initialAmountMode: QuotaAmountMode
        if let saved = UserDefaults.standard.string(forKey: amountDefaultsKey),
           let savedMode = QuotaAmountMode(rawValue: saved) {
            initialAmountMode = savedMode
        } else {
            initialAmountMode = .used
            UserDefaults.standard.set(initialAmountMode.rawValue, forKey: amountDefaultsKey)
        }

        mode = initialMode
        amountMode = initialAmountMode
        alwaysShowResetTime = true
        UserDefaults.standard.set(true, forKey: alwaysShowResetTimeDefaultsKey)

        if UserDefaults.standard.object(forKey: showStatusLightsDefaultsKey) == nil {
            showStatusLights = true
            UserDefaults.standard.set(true, forKey: showStatusLightsDefaultsKey)
        } else {
            showStatusLights = UserDefaults.standard.bool(forKey: showStatusLightsDefaultsKey)
        }
    }

    var displayHelpText: String {
        L.quotaDisplayModeHelp(mode.label)
    }

    var amountHelpText: String {
        L.quotaAmountModeHelp(amountMode.label)
    }

    var resetTimeHelpText: String {
        L.resetTimeDisplayHelp(alwaysShowResetTime ? L.resetTimeDisplayAlways : L.resetTimeDisplayNearLimit)
    }

    var statusLightsHelpText: String {
        L.statusLightsDisplayHelp(showStatusLights ? L.statusLightsVisible : L.statusLightsHidden)
    }

    func setMode(_ newMode: QuotaDisplayMode) {
        guard mode != newMode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: modeDefaultsKey)
    }

    func toggle() {
        setMode(mode == .numbers ? .bars : .numbers)
    }

    func setAmountMode(_ newMode: QuotaAmountMode) {
        guard amountMode != newMode else { return }
        amountMode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: amountDefaultsKey)
    }

    func toggleAmountMode() {
        setAmountMode(amountMode == .used ? .remaining : .used)
    }

    func setShowStatusLights(_ enabled: Bool) {
        guard showStatusLights != enabled else { return }
        showStatusLights = enabled
        UserDefaults.standard.set(enabled, forKey: showStatusLightsDefaultsKey)
    }

    func toggleStatusLights() {
        setShowStatusLights(!showStatusLights)
    }
}
