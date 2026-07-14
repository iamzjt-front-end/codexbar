import AppKit

@MainActor
enum CodexApplicationActivator {
    static func activate() {
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.openai.codex"
        }) {
            _ = app.activate(options: [.activateAllWindows])
            return
        }

        guard let appURL = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }
}
