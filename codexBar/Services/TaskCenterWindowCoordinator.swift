import AppKit
import SwiftUI

@MainActor
final class TaskCenterWindowCoordinator {
    static let shared = TaskCenterWindowCoordinator()

    static let sceneID = "task-center"
    static let scheme = "xmasdong.codexappbar"
    static let host = "task-center"
    static let externalEventMatch = host

    private weak var window: NSWindow?

    private init() {}

    func register(_ window: NSWindow?) {
        self.window = window
        guard let window else { return }
        window.title = L.taskCenterTitle
        window.setFrameAutosaveName("CodexAppBar.TaskCenter")
        window.minSize = NSSize(width: 480, height: 380)
    }

    func updateLocalizedTitle() {
        window?.title = L.taskCenterTitle
    }

    func open(taskKey: String? = nil) {
        let selectedTaskKey = taskKey.flatMap { Self.isValidTaskKey($0) ? $0 : nil }
        TaskCenterService.shared.selectTask(selectedTaskKey)

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        if let selectedTaskKey {
            components.queryItems = [URLQueryItem(name: "task", value: selectedTaskKey)]
        }
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    func handle(_ url: URL) {
        guard url.scheme?.caseInsensitiveCompare(Self.scheme) == .orderedSame,
              url.host?.caseInsensitiveCompare(Self.host) == .orderedSame else { return }

        let taskKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "task" })?
            .value
        let selectedTaskKey = taskKey.flatMap { Self.isValidTaskKey($0) ? $0 : nil }
        TaskCenterService.shared.selectTask(selectedTaskKey)

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func isValidTaskKey(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102, 65...70:
                return true
            default:
                return false
            }
        }
    }
}

@MainActor
struct TaskCenterWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowResolvingView {
        WindowResolvingView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: WindowResolvingView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveWindow()
    }
}

@MainActor
final class WindowResolvingView: NSView {
    var onResolve: (NSWindow?) -> Void

    init(onResolve: @escaping (NSWindow?) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveWindow()
    }

    func resolveWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onResolve(self.window)
        }
    }
}
