import Foundation

/// File locations. Everything lives under ~/.config/rungrinh unless RUNGRINH_HOME is set (used by tests).
public struct Paths: Sendable {
    public let base: URL

    public init(base: URL? = nil) {
        if let base {
            self.base = base
        } else if let env = ProcessInfo.processInfo.environment["RUNGRINH_HOME"], !env.isEmpty {
            self.base = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            self.base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/rungrinh")
        }
    }

    public var config: URL { base.appendingPathComponent("config.json") }
    public var history: URL { base.appendingPathComponent("history.jsonl") }
    public var log: URL { base.appendingPathComponent("rungrinh.log") }
    public var state: URL { base.appendingPathComponent("state") }
    public var sessions: URL { state.appendingPathComponent("sessions") }
    public var lastSent: URL { state.appendingPathComponent("last_sent") }

    public func ensureDirs() throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public struct ConfigStore: Sendable {
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    public func load() -> Config {
        guard let data = try? Data(contentsOf: paths.config),
              let config = try? JSONCoding.decoder.decode(Config.self, from: data) else {
            return Config()
        }
        return config
    }

    public func save(_ config: Config) throws {
        try paths.ensureDirs()
        let data = try JSONCoding.encoder.encode(config)
        try data.write(to: paths.config, options: .atomic)
        // The file holds push keys/tokens.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.config.path)
    }

    @discardableResult
    public func update(_ change: (inout Config) -> Void) throws -> Config {
        var config = load()
        change(&config)
        try save(config)
        return config
    }

    /// Sets a dotted key such as `bark.key` or `minTaskSeconds`. The value is parsed as
    /// bool / int / string in that order and the result must still decode as a Config.
    @discardableResult
    public func set(_ dottedKey: String, to raw: String) throws -> Config {
        let current = try JSONCoding.encoder.encode(load())
        guard var root = try JSONSerialization.jsonObject(with: current) as? [String: Any] else {
            throw RungRinhError.invalidConfigKey(dottedKey)
        }
        let parts = dottedKey.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { throw RungRinhError.invalidConfigKey(dottedKey) }

        let value: Any
        switch raw.lowercased() {
        case "true", "on", "yes": value = true
        case "false", "off", "no": value = false
        default: value = Int(raw).map { $0 as Any } ?? raw
        }

        func assign(_ dict: inout [String: Any], _ path: ArraySlice<String>) throws {
            let head = path.first!
            if path.count == 1 {
                guard dict[head] != nil || head == "snoozeUntil" else {
                    throw RungRinhError.invalidConfigKey(dottedKey)
                }
                dict[head] = value
                return
            }
            guard var child = dict[head] as? [String: Any] else {
                throw RungRinhError.invalidConfigKey(dottedKey)
            }
            try assign(&child, path.dropFirst())
            dict[head] = child
        }
        try assign(&root, parts[...])

        let data = try JSONSerialization.data(withJSONObject: root)
        let config: Config
        do {
            config = try JSONCoding.decoder.decode(Config.self, from: data)
        } catch {
            throw RungRinhError.invalidConfigValue(dottedKey, raw)
        }
        try save(config)
        return config
    }
}

public enum RungRinhError: LocalizedError {
    case notConfigured(Provider)
    case invalidConfigKey(String)
    case invalidConfigValue(String, String)
    case http(Int, String)
    case badURL(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(.bark): return "Bark chưa có device key (rungrinh config set bark.key <KEY>)"
        case .notConfigured(.ntfy): return "ntfy chưa có topic (rungrinh config set ntfy.topic <TOPIC>)"
        case .invalidConfigKey(let k): return "Không có key cấu hình '\(k)'"
        case .invalidConfigValue(let k, let v): return "Giá trị '\(v)' không hợp lệ cho '\(k)'"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .badURL(let u): return "URL không hợp lệ: \(u)"
        }
    }
}
