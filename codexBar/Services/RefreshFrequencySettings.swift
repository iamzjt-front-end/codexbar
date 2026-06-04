import Combine
import Foundation

enum RefreshFrequencyOption: String, CaseIterable, Identifiable {
    case auto
    case tenSeconds
    case thirtySeconds
    case oneMinute
    case twoMinutes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "AUTO"
        case .tenSeconds: return "10s"
        case .thirtySeconds: return "30s"
        case .oneMinute: return "1m"
        case .twoMinutes: return "2m"
        }
    }

    var visibleInterval: TimeInterval {
        switch self {
        case .auto, .tenSeconds: return 10
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .twoMinutes: return 120
        }
    }

    var backgroundInterval: TimeInterval {
        switch self {
        case .auto: return 60
        case .tenSeconds: return 10
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .twoMinutes: return 120
        }
    }

    var helpDetail: String {
        switch self {
        case .auto:
            return L.zh ? "菜单打开 10s，后台 1m" : "10s while open, 1m in background"
        default:
            return label
        }
    }
}

@MainActor
final class RefreshFrequencySettings: ObservableObject {
    static let shared = RefreshFrequencySettings()

    @Published private(set) var selection: RefreshFrequencyOption

    private let defaultsKey = "refreshFrequencyOption"

    private init() {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey),
           let option = RefreshFrequencyOption(rawValue: saved) {
            selection = option
        } else {
            selection = .auto
        }
    }

    var buttonLabel: String {
        selection.label
    }

    var helpText: String {
        L.refreshFrequencyHelp(selection.helpDetail)
    }

    func cycle() {
        let options = RefreshFrequencyOption.allCases
        let currentIndex = options.firstIndex(of: selection) ?? 0
        let nextIndex = options.index(after: currentIndex)
        selection = nextIndex == options.endIndex ? options[0] : options[nextIndex]
        UserDefaults.standard.set(selection.rawValue, forKey: defaultsKey)
        BackgroundRefresher.shared.start(interval: selection.backgroundInterval, runImmediately: false)
    }
}
