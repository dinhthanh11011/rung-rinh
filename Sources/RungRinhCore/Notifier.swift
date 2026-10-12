import Foundation

public enum Priority: String, Codable, CaseIterable, Sendable {
    case low, normal, high
}

public struct Message: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var priority: Priority
    public var url: String?
    public var tags: [String]

    public init(title: String, body: String, priority: Priority = .normal, url: String? = nil, tags: [String] = []) {
        self.title = title
        self.body = body
        self.priority = priority
        self.url = url
        self.tags = tags
    }
}

public protocol Notifier: Sendable {
    func send(_ message: Message) async throws
}

public enum Notifiers {
    public static func make(for config: Config, session: URLSession = .rungrinh) throws -> Notifier {
        guard config.isConfigured else { throw RungRinhError.notConfigured(config.provider) }
        switch config.provider {
        case .bark: return BarkNotifier(config: config.bark, session: session)
        case .ntfy: return NtfyNotifier(config: config.ntfy, session: session)
        }
    }
}

extension URLSession {
    /// Short timeouts: hooks must never hold Claude Code up for long.
    public static let rungrinh: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        return URLSession(configuration: c)
    }()
}

func trimmedServer(_ s: String) -> String {
    var s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
}

func checkHTTP(_ data: Data, _ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
        throw RungRinhError.http(http.statusCode, String(decoding: data, as: UTF8.self))
    }
}

public struct BarkNotifier: Notifier {
    public let config: BarkConfig
    public let session: URLSession

    public init(config: BarkConfig, session: URLSession = .rungrinh) {
        self.config = config
        self.session = session
    }

    public func request(for message: Message) throws -> URLRequest {
        let server = trimmedServer(config.server)
        guard let url = URL(string: server + "/push") else { throw RungRinhError.badURL(server) }
        var payload: [String: Any] = [
            "device_key": config.key.trimmingCharacters(in: .whitespacesAndNewlines),
            "title": message.title,
            "body": message.body.isEmpty ? " " : message.body,
            "group": config.group,
        ]
        switch message.priority {
        case .low: payload["level"] = "passive"
        case .normal: payload["level"] = config.level
        case .high: payload["level"] = config.level == "critical" ? "critical" : "timeSensitive"
        }
        if !config.sound.isEmpty { payload["sound"] = config.sound }
        if let link = message.url, !link.isEmpty { payload["url"] = link }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    public func send(_ message: Message) async throws {
        let (data, response) = try await session.data(for: try request(for: message))
        try checkHTTP(data, response)
    }
}

public struct NtfyNotifier: Notifier {
    public let config: NtfyConfig
    public let session: URLSession

    public init(config: NtfyConfig, session: URLSession = .rungrinh) {
        self.config = config
        self.session = session
    }

    /// Uses ntfy's JSON publish endpoint (POST to the server root) so UTF-8 titles work without header encoding.
    public func request(for message: Message) throws -> URLRequest {
        let server = trimmedServer(config.server)
        guard let url = URL(string: server) else { throw RungRinhError.badURL(server) }
        let priority: Int
        switch message.priority {
        case .low: priority = 2
        case .normal: priority = min(max(config.priority, 1), 5)
        case .high: priority = 5
        }
        var payload: [String: Any] = [
            "topic": config.topic.trimmingCharacters(in: .whitespacesAndNewlines),
            "title": message.title,
            "message": message.body.isEmpty ? message.title : message.body,
            "priority": priority,
        ]
        if !message.tags.isEmpty { payload["tags"] = message.tags }
        if let link = message.url, !link.isEmpty { payload["click"] = link }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let token = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    public func send(_ message: Message) async throws {
        let (data, response) = try await session.data(for: try request(for: message))
        try checkHTTP(data, response)
    }
}
