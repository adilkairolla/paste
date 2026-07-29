import Foundation
import ServiceManagement

/// "Start at login", with a LaunchAgent fallback for builds `SMAppService`
/// refuses (it wants a satisfying code signature, which ad-hoc local builds
/// don't always have).
enum LoginItem {
    private static let agentLabel = "app.pastedeck.launcher"

    private static var agentPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// Returns the error, if any, so the UI can explain itself.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
                removeLaunchAgent()
                return nil
            } catch {
                // Fall through to the LaunchAgent route.
                if enabled {
                    return writeLaunchAgent() ? nil : error.localizedDescription
                }
                removeLaunchAgent()
                return nil
            }
        }

        if enabled { return writeLaunchAgent() ? nil : "Could not write the launch agent." }
        removeLaunchAgent()
        return nil
    }

    // MARK: LaunchAgent fallback

    private static func writeLaunchAgent() -> Bool {
        let executable = Bundle.main.bundleURL.path
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: agentPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: agentPlistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: agentPlistURL)
    }
}
