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
    /// Notification hook: permission_prompt, idle_prompt, elicitation_dialog, auth_success…
    public var notificationType: String?
    public var lastAssistantMessage: String?
    /// PreToolUse / PostToolUse.
    public var toolName: String?
    public var toolInput: ToolInput?
    public var toolUseId: String?

    /// The parts of AskUserQuestion / ExitPlanMode input we show in a push.
    public struct ToolInput: Decodable, Sendable {
        public struct Question: Decodable, Sendable {
            public var question: String?
        }
        public var questions: [Question]?
        public var plan: String?
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case stopHookActive = "stop_hook_active"
        case message
        case notificationType = "notification_type"
        case lastAssistantMessage = "last_assistant_message"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        hookEventName = try? c.decodeIfPresent(String.self, forKey: .hookEventName)
        stopHookActive = try? c.decodeIfPresent(Bool.self, forKey: .stopHookActive)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        notificationType = try? c.decodeIfPresent(String.self, forKey: .notificationType)
        lastAssistantMessage = try? c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
        // Other tools' input has arbitrary shapes; never let it fail the whole decode.
        toolInput = try? c.decodeIfPresent(ToolInput.self, forKey: .toolInput)
        toolUseId = try? c.decodeIfPresent(String.self, forKey: .toolUseId)
    }
}

public struct ClaudeHookHandler: Sendable {
    /// Tools that block until the user answers.
    public static let askingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public let paths: Paths
    public let dispatcher: Dispatcher
    /// Starts the background waiter for (session, token). Tests replace it.
    public let spawnWaiter: @Sendable (String, String) -> Void

    public init(
        paths: Paths = Paths(),
        dispatcher: Dispatcher? = nil,
        spawnWaiter: (@Sendable (String, String) -> Void)? = nil
    ) {
        self.paths = paths
        self.dispatcher = dispatcher ?? Dispatcher(paths: paths)
        self.spawnWaiter = spawnWaiter ?? { session, token in
            if !Detached.spawn(Detached.selfPath, ["hook", "wait", session, token]) {
                Log(paths: paths).write("[hook] could not start waiter")
            }
        }
    }

    public func handle(_ data: Data, now: Date = Date()) async {
        guard let input = try? JSONDecoder().decode(ClaudeHookInput.self, from: data) else {
            Log(paths: paths).write("[hook] could not parse stdin: \(String(decoding: data.prefix(300), as: UTF8.self))")
            return
        }
        let state = StateStore(paths: paths)
        let pending = PendingStore(paths: paths)
        let calls = ToolCallStore(paths: paths)
        let session = input.sessionId ?? "default"
        let project = input.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude Code"

        /// Records that Claude is blocked on the user and lets a detached process push later if it still is.
        func startWaiting(text: String, tool: String?, toolUseIds: [String]) {
            let q = PendingQuestion(since: now, project: project, text: text, tool: tool,
                                    toolUseIds: toolUseIds, transcriptPath: input.transcriptPath)
            pending.add(q, session: session)
            spawnWaiter(session, q.token)
        }

        /// The turn is over (or never started), so nothing in it is still waiting.
        func endTurn() {
            pending.clear(session: session)
            calls.clear(session: session)
        }

        switch input.hookEventName {
        case "UserPromptSubmit":
            endTurn()
            state.markStart(session: session, at: now)

        case "Stop":
            endTurn()
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

        case "SessionEnd":
            endTurn()

        case "PreToolUse":
            let tool = input.toolName ?? ""
            if let id = input.toolUseId { calls.started(session: session, id: id, tool: tool) }
            if Self.askingTools.contains(tool) {
                let text = input.toolInput?.questions?.compactMap(\.question).first
                    ?? input.toolInput?.plan.map { "Duyệt plan: \($0)" }
                    ?? "Claude đang hỏi bạn"
                startWaiting(text: text, tool: tool, toolUseIds: input.toolUseId.map { [$0] } ?? [])
            }

        case "PostToolUse", "PostToolUseFailure":
            if let id = input.toolUseId { calls.finished(session: session, id: id) }
            // Only the prompt's own call answers it; parallel calls finishing don't.
            pending.toolFinished(session: session, toolUseId: input.toolUseId, tool: input.toolName)

        case "Notification":
            switch input.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", nil:
                let text = input.message ?? "Claude đang chờ bạn"
                let tool = Self.permissionTool(in: text)
                // The call(s) this prompt is for: in flight, of that tool, not already waited on.
                let waited = Set(pending.all(session: session).flatMap(\.toolUseIds))
                let inFlight = calls.inFlight(session: session).filter { !waited.contains($0.key) }
                let ids = inFlight.filter { tool == nil || $0.value == tool }.map(\.key).sorted()
                if ids.isEmpty, !pending.all(session: session).isEmpty { return } // already covered
                startWaiting(text: text, tool: tool, toolUseIds: ids)
            case "idle_prompt":
                // Claude has already waited ~60s by itself; a question in flight has its own waiter.
                if !pending.all(session: session).isEmpty { return }
                await dispatcher.dispatch(
                    .claudeNotification,
                    Message(title: "⏳ \(project): Claude cần bạn", body: Transcript.excerpt(input.message ?? "Claude đang chờ bạn"), priority: .high, tags: ["hourglass"])
                )
            default:
                // auth_success, agent_completed, quota notices…: not a question.
                return
            }

        default:
            break
        }
    }

    /// "Claude needs your permission to use Bash" -> "Bash".
    static func permissionTool(in message: String) -> String? {
        guard let r = message.range(of: "permission to use ") else { return nil }
        let name = message[r.upperBound...].prefix { !$0.isWhitespace && $0 != "." }
        return name.isEmpty ? nil : String(name)
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

    /// Which of `ids` already have a tool_result in the transcript (approved and run, or denied).
    public static func resolvedToolUseIds(path: String, among ids: Set<String>, tailBytes: Int = 1024 * 1024) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return [] }

        var found = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains("tool_result") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for b in blocks where b["type"] as? String == "tool_result" {
                if let id = b["tool_use_id"] as? String, ids.contains(id) { found.insert(id) }
            }
        }
        return found
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
