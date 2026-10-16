import Foundation

/// A Claude Code turn that ended on an API error (StopFailure): login expired, usage limit, overload…
/// Kept until the session moves on by itself (next prompt, Stop, SessionEnd).
public struct Interrupted: Codable, Equatable, Sendable {
    public var session: String
    public var project: String
    public var cwd: String?
    public var transcriptPath: String?
    /// StopFailure `error`: rate_limit, authentication_failed, overloaded…
    public var error: String
    /// The error text Claude Code showed, e.g. "You've hit your session limit · resets 3:45pm".
    public var message: String
    public var since: Date
    public var hostPids: [Int32]
    /// The session's inbox (CLAUDE_CODE_MESSAGING_SOCKET / _TOKEN), to post into it later.
    public var socket: String?
    public var token: String?

    public init(
        session: String, project: String, cwd: String? = nil, transcriptPath: String? = nil,
        error: String, message: String, since: Date, hostPids: [Int32] = [],
        socket: String? = nil, token: String? = nil
    ) {
        self.session = session
        self.project = project
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.error = error
        self.message = message
        self.since = since
        self.hostPids = hostPids
        self.socket = socket
        self.token = token
    }

    /// Push title for this error.
    public var title: String {
        switch error {
        case "authentication_failed", "cloud_credential_error":
            return "🔑 \(project): Claude dừng, cần /login"
        case "rate_limit":
            let reset = UsageLimit.resetDate(from: message, now: since).map { " tới \(UsageLimit.clock($0))" } ?? ""
            return "⛔ \(project): hết quota\(reset)"
        case "overloaded", "server_error":
            return "⚠️ \(project): lỗi server, Claude dừng"
        case "billing_error", "account_on_hold", "oauth_org_not_allowed":
            return "💳 \(project): tài khoản có vấn đề"
        default:
            return "❌ \(project): Claude dừng vì lỗi"
        }
    }
}

/// One file per session; 0600 because it holds the session's messaging token.
public struct InterruptedStore: Sendable {
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    private func file(_ session: String) -> URL {
        paths.interrupted.appendingPathComponent(StateStore.safeName(session) + ".json")
    }

    public func save(_ r: Interrupted) {
        try? FileManager.default.createDirectory(at: paths.interrupted, withIntermediateDirectories: true)
        guard let data = try? JSONCoding.encoder.encode(r) else { return }
        let url = file(r.session)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func get(session: String) -> Interrupted? {
        guard let data = try? Data(contentsOf: file(session)) else { return nil }
        return try? JSONCoding.decoder.decode(Interrupted.self, from: data)
    }

    public func all() -> [Interrupted] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.interrupted, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONCoding.decoder.decode(Interrupted.self, from: $0) } }
    }

    public func clear(session: String) {
        try? FileManager.default.removeItem(at: file(session))
    }
}

public enum UsageLimit {
    /// "You've hit your session limit · resets 3:45pm" / "… resets Mon 12:00am" -> the next such time
    /// after `now`, in this Mac's time zone.
    public static func resetDate(from message: String, now: Date, calendar: Calendar = .current) -> Date? {
        let pattern = #"resets\s+(?:(mon|tue|wed|thu|fri|sat|sun)[a-z]*\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return nil }
        func group(_ i: Int) -> String? {
            Range(m.range(at: i), in: message).map { String(message[$0]).lowercased() }
        }
        guard let h = group(2).flatMap(Int.init), (1...12).contains(h), let ampm = group(4) else { return nil }
        var comps = DateComponents()
        comps.hour = h % 12 + (ampm == "pm" ? 12 : 0)
        comps.minute = group(3).flatMap(Int.init) ?? 0
        comps.second = 0
        if let day = group(1) {
            let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            comps.weekday = (days.firstIndex(of: day) ?? 0) + 1
        }
        return calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
    }

    /// "15:45", or "T2 00:00" when it isn't today.
    static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        guard !calendar.isDate(date, inSameDayAs: now) else { return f.string(from: date) }
        let wd = calendar.component(.weekday, from: date)
        return (wd == 1 ? "CN" : "T\(wd)") + " " + f.string(from: date)
    }
}
