import CoreGraphics
import Foundation

/// Remembers when each Claude Code session started its current task, and when we last pushed.
public struct StateStore: Sendable {
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    static func safeName(_ id: String) -> String {
        let safe = id.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }
            .joined()
        return safe.isEmpty ? "default" : safe
    }

    private func sessionFile(_ id: String) -> URL {
        paths.sessions.appendingPathComponent(Self.safeName(id))
    }

    public func markStart(session: String, at date: Date = Date()) {
        try? paths.ensureDirs()
        try? String(date.timeIntervalSince1970).write(to: sessionFile(session), atomically: true, encoding: .utf8)
        pruneSessions(olderThan: 7 * 24 * 3600, now: date)
    }

    public func start(session: String) -> Date? {
        guard let s = try? String(contentsOf: sessionFile(session), encoding: .utf8),
              let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    public func clear(session: String) {
        try? FileManager.default.removeItem(at: sessionFile(session))
    }

    public func pruneSessions(olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        let files = [paths.sessions, paths.waits, paths.calls, paths.interrupted].flatMap {
            (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        for f in files {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(m) > age { try? fm.removeItem(at: f) }
        }
    }

    public var lastSentAt: Date? {
        guard let s = try? String(contentsOf: paths.lastSent, encoding: .utf8),
              let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    public func markSent(at date: Date = Date()) {
        try? paths.ensureDirs()
        try? String(date.timeIntervalSince1970).write(to: paths.lastSent, atomically: true, encoding: .utf8)
    }
}

public enum IdleTime {
    /// Seconds since the last keyboard / mouse / trackpad event in this login session.
    public static func seconds() -> TimeInterval {
        let anyEvent = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent)
    }
}

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var date: Date
    public var source: String
    public var title: String
    public var sent: Bool
    /// Skip reason or error text.
    public var detail: String?

    public init(date: Date = Date(), source: String, title: String, sent: Bool, detail: String? = nil) {
        self.date = date
        self.source = source
        self.title = title
        self.sent = sent
        self.detail = detail
    }
}

public struct History: Sendable {
    public let paths: Paths
    public var keep = 200

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    public func append(_ entry: HistoryEntry) {
        try? paths.ensureDirs()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let line = try? enc.encode(entry) else { return }

        var lines = (try? String(contentsOf: paths.history, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        lines.append(String(decoding: line, as: UTF8.self))
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        try? (lines.joined(separator: "\n") + "\n").write(to: paths.history, atomically: true, encoding: .utf8)
    }

    /// Most recent first.
    public func recent(_ limit: Int = 10) -> [HistoryEntry] {
        guard let text = try? String(contentsOf: paths.history, encoding: .utf8) else { return [] }
        let dec = JSONCoding.decoder
        return text.split(separator: "\n").reversed().prefix(limit).compactMap {
            try? dec.decode(HistoryEntry.self, from: Data($0.utf8))
        }
    }
}

public struct Log: Sendable {
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    public func write(_ text: String) {
        try? paths.ensureDirs()
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let h = try? FileHandle(forWritingTo: paths.log) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: paths.log, atomically: true, encoding: .utf8)
        }
    }
}
