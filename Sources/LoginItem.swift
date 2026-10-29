import Foundation

/// Optional LaunchAgent: starts tailscaled-gui at login and relaunches it after a crash.
enum LoginItem {
    static let label = "local.tailscaled-gui.agent"
    private static let legacyLabel = "local.tailnet.agent"
    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static var legacyURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path) || FileManager.default.fileExists(atPath: legacyURL.path)
    }

    /// Keep a previous login choice, but point it at the renamed executable.
    static func migrateLegacy() throws {
        try migrateLegacy(legacy: legacyURL, current: plistURL, create: { try enable() }, stopLegacy: {
            _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyLabel)"], timeout: 3)
        })
    }

    static func migrateLegacy(legacy: URL, current: URL, create: () throws -> Void,
                              stopLegacy: () -> Void) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        if !fm.fileExists(atPath: current.path) {
            try create()
            guard fm.fileExists(atPath: current.path) else {
                throw NSError(domain: "local.tailscaled-gui", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The new login item was not created."])
            }
        }
        stopLegacy()
        try fm.removeItem(at: legacy)
    }

    static func enable() throws {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // a normal Quit stays quit; a crash relaunches
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    /// Removing the plist is enough: the job is gone at next login.
    static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
