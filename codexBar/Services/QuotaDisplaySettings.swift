import Combine
import Foundation

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

    func displayPercent(forUsedPercent usedPercent: Double) -> Double {
        switch self {
        case .used:
            return min(max(usedPercent, 0), 100)
        case .remaining:
            return min(max(100 - usedPercent, 0), 100)
        }
    }
}

@MainActor
final class QuotaDisplaySettings: ObservableObject {
    static let shared = QuotaDisplaySettings()

    @Published private(set) var amountMode: QuotaAmountMode
    @Published private(set) var showStatusLights: Bool

    private let amountDefaultsKey = "quotaAmountMode"
    private let showStatusLightsDefaultsKey = "quotaShowStatusLights"

    private init() {
        let initialAmountMode: QuotaAmountMode
        if let saved = UserDefaults.standard.string(forKey: amountDefaultsKey),
           let savedMode = QuotaAmountMode(rawValue: saved) {
            initialAmountMode = savedMode
        } else {
            initialAmountMode = .used
            UserDefaults.standard.set(initialAmountMode.rawValue, forKey: amountDefaultsKey)
        }

        amountMode = initialAmountMode

        if UserDefaults.standard.object(forKey: showStatusLightsDefaultsKey) == nil {
            showStatusLights = true
            UserDefaults.standard.set(true, forKey: showStatusLightsDefaultsKey)
        } else {
            showStatusLights = UserDefaults.standard.bool(forKey: showStatusLightsDefaultsKey)
        }
    }

    var amountHelpText: String {
        L.quotaAmountModeHelp(amountMode.label)
    }

    var statusLightsHelpText: String {
        L.statusLightsDisplayHelp(showStatusLights ? L.statusLightsVisible : L.statusLightsHidden)
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
