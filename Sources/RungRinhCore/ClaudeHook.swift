import Foundation

/// The JSON Claude Code writes to a hook's stdin (only the fields we use).
public struct ClaudeHookInput: Decodable, Sendable {
    public var sessionId: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var hookEventName: String?
    public var stopHookActive: Bool?
    /// Notification hook text, e.g. "Claude needs your permission to use Bash".
    public var message: String?
    public var lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case stopHookActive = "stop_hook_active"
        case message
        case lastAssistantMessage = "last_assistant_message"
    }
}

public struct ClaudeHookHandler: Sendable {
    public let paths: Paths
    public let dispatcher: Dispatcher

    public init(paths: Paths = Paths(), dispatcher: Dispatcher? = nil) {
        self.paths = paths
        self.dispatcher = dispatcher ?? Dispatcher(paths: paths)
    }

    public func handle(_ data: Data, now: Date = Date()) async {
        guard let input = try? JSONDecoder().decode(ClaudeHookInput.self, from: data) else {
            Log(paths: paths).write("[hook] could not parse stdin: \(String(decoding: data.prefix(300), as: UTF8.self))")
            return
        }
        let state = StateStore(paths: paths)
        let session = input.sessionId ?? "default"
        let project = input.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude Code"

        switch input.hookEventName {
        case "UserPromptSubmit":
            state.markStart(session: session, at: now)

        case "Stop":
            if input.stopHookActive == true { return }
            let duration = state.start(session: session).map { now.timeIntervalSince($0) }
            state.clear(session: session)
            let summary = input.lastAssistantMessage
                ?? input.transcriptPath.flatMap { Transcript.lastAssistantText(path: $0) }
                ?? "Task đã xong"
            let title = duration.map { "✅ \(project) xong sau \(formatDuration($0))" } ?? "✅ \(project) xong"
            await dispatcher.dispatch(
                .claudeStop(duration: duration),
                Message(title: title, body: Transcript.excerpt(summary), tags: ["white_check_mark"])
            )

        case "Notification":
            let body = input.message ?? "Claude đang chờ bạn"
            await dispatcher.dispatch(
                .claudeNotification,
                Message(title: "⏳ \(project): Claude cần bạn", body: Transcript.excerpt(body), priority: .high, tags: ["hourglass"])
            )

        default:
            break
        }
    }
}

public enum Transcript {
    /// Reads the tail of a Claude Code transcript (.jsonl) and returns the last assistant text block.
    public static func lastAssistantText(path: String, tailBytes: Int = 256 * 1024) -> String? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any] else { continue }
            if let text = msg["content"] as? String, !text.isEmpty { return text }
            if let blocks = msg["content"] as? [[String: Any]] {
                let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            }
        }
        return nil
    }

    /// Collapses whitespace / markdown noise and truncates for a watch-sized notification.
    public static func excerpt(_ text: String, limit: Int = 160) -> String {
        let cleaned = text
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return cleaned.count > limit ? String(cleaned.prefix(limit - 1)) + "…" : cleaned
    }
}
