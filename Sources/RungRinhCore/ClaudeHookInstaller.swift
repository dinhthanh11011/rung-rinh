import Foundation

/// Adds / removes our entries in Claude Code's settings.json, leaving every other hook untouched.
public struct ClaudeHookInstaller: Sendable {
    public static let events = ["UserPromptSubmit", "Stop", "Notification"]

    public let settingsURL: URL

    public init(settingsURL: URL? = nil) {
        if let settingsURL {
            self.settingsURL = settingsURL
        } else {
            let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            let dir = env.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
            self.settingsURL = dir.appendingPathComponent("settings.json")
        }
    }

    public var backupURL: URL { settingsURL.appendingPathExtension("rungrinh-backup") }

    public static func command(forBinary path: String) -> String {
        "\"\(path)\" hook claude"
    }

    static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let cmd = hook["command"] as? String else { return false }
        return cmd.contains("rungrinh") && cmd.hasSuffix(" hook claude")
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: settingsURL, to: backupURL)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Returns `settings["hooks"]` with all of our entries removed (and emptied groups dropped).
    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var out = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return group }
                let kept = inner.filter { !isOurs($0) }
                if kept.isEmpty && !inner.isEmpty { return nil }
                var g = group
                g["hooks"] = kept
                return g
            }
            if cleaned.isEmpty { out.removeValue(forKey: event) } else { out[event] = cleaned }
        }
        return out
    }

    public func isInstalled() -> Bool {
        guard let hooks = (try? readSettings())?["hooks"] as? [String: Any] else { return false }
        return Self.events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains { group in
                ((group["hooks"] as? [[String: Any]]) ?? []).contains(where: Self.isOurs)
            }
        }
    }

    public func install(binaryPath: String) throws {
        var settings = try readSettings()
        var hooks = Self.strip(settings["hooks"] as? [String: Any] ?? [:])
        let entry: [String: Any] = [
            "type": "command",
            "command": Self.command(forBinary: binaryPath),
            "timeout": 15,
        ]
        for event in Self.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [entry]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    public func uninstall() throws {
        var settings = try readSettings()
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        let stripped = Self.strip(hooks)
        if stripped.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = stripped }
        try writeSettings(settings)
    }
}
