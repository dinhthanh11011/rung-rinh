import Foundation

/// Claude is blocked on the user: a question (AskUserQuestion / ExitPlanMode) or a permission prompt.
/// Or Claude finished and the "done" push waits to see whether the user is already on it.
public struct PendingQuestion: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case question, done
    }

    /// Identifies this wait, so a waiter only ever pushes for the question it was spawned for.
    public var token: String
    public var kind: Kind
    public var since: Date
    public var project: String
    /// The text shown to the user, e.g. the question or "Claude needs your permission to use Bash".
    /// For `.done`, the end of Claude's answer.
    public var text: String
    public var tool: String?
    /// The tool calls the prompt blocks. Once each has a result the prompt was answered (or denied).
    /// Empty when Claude Code didn't send ids; then only the tool's PostToolUse or the turn ending clears it.
    public var toolUseIds: [String]
    /// Lets the waiter see a denial, which fires no hook but writes a tool_result.
    public var transcriptPath: String?
    /// `.done`: how long the task took.
    public var duration: TimeInterval?
    /// The hook process and its ancestors, one of which is the app Claude runs in (see HostApp).
    public var hostPids: [Int32]

    public init(
        token: String = UUID().uuidString, kind: Kind = .question, since: Date, project: String, text: String,
        tool: String? = nil, toolUseIds: [String] = [], transcriptPath: String? = nil,
        duration: TimeInterval? = nil, hostPids: [Int32] = []
    ) {
        self.token = token
        self.kind = kind
        self.since = since
        self.project = project
        self.text = text
        self.tool = tool
        self.toolUseIds = toolUseIds
        self.transcriptPath = transcriptPath
        self.duration = duration
        self.hostPids = hostPids
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .question
        since = try c.decode(Date.self, forKey: .since)
        project = try c.decode(String.self, forKey: .project)
        text = try c.decode(String.self, forKey: .text)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        toolUseIds = try c.decodeIfPresent([String].self, forKey: .toolUseIds) ?? []
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        hostPids = try c.decodeIfPresent([Int32].self, forKey: .hostPids) ?? []
    }
}

/// One file per wait, per session, so concurrent hook processes never overwrite each other.
public struct PendingStore: Sendable {
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    private func dir(_ session: String) -> URL {
        paths.waits.appendingPathComponent(StateStore.safeName(session))
    }

    private func file(_ session: String, _ token: String) -> URL {
        dir(session).appendingPathComponent(StateStore.safeName(token) + ".json")
    }

    public func all(session: String) -> [PendingQuestion] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(session), includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { f in
            (try? Data(contentsOf: f)).flatMap { try? JSONCoding.decoder.decode(PendingQuestion.self, from: $0) }
        }
    }

    public func get(session: String, token: String) -> PendingQuestion? {
        guard let data = try? Data(contentsOf: file(session, token)) else { return nil }
        return try? JSONCoding.decoder.decode(PendingQuestion.self, from: data)
    }

    public func add(_ q: PendingQuestion, session: String) {
        try? FileManager.default.createDirectory(at: dir(session), withIntermediateDirectories: true)
        guard let data = try? JSONCoding.encoder.encode(q) else { return }
        try? data.write(to: file(session, q.token), options: .atomic)
    }

    public func remove(session: String, token: String) {
        try? FileManager.default.removeItem(at: file(session, token))
    }

    /// A tool call finished: drop the waits it was blocking.
    public func toolFinished(session: String, toolUseId: String?, tool: String?) {
        for q in all(session: session) {
            let done = q.toolUseIds.isEmpty ? q.tool == nil || q.tool == tool : toolUseId.map(q.toolUseIds.contains) ?? false
            if done { remove(session: session, token: q.token) }
        }
    }

    public func clear(session: String) {
        try? FileManager.default.removeItem(at: dir(session))
    }
}

/// Tool calls in flight per session (PreToolUse without a PostToolUse yet), to tell which
/// call a permission prompt belongs to; the Notification hook carries no tool_use_id.
public struct ToolCallStore: Sendable {
    public let paths: Paths

    public init(paths: Paths = Paths()) {
        self.paths = paths
    }

    private func dir(_ session: String) -> URL {
        paths.calls.appendingPathComponent(StateStore.safeName(session))
    }

    public func started(session: String, id: String, tool: String) {
        try? FileManager.default.createDirectory(at: dir(session), withIntermediateDirectories: true)
        try? tool.write(to: dir(session).appendingPathComponent(StateStore.safeName(id)), atomically: true, encoding: .utf8)
    }

    public func finished(session: String, id: String) {
        try? FileManager.default.removeItem(at: dir(session).appendingPathComponent(StateStore.safeName(id)))
    }

    /// id -> tool name.
    public func inFlight(session: String) -> [String: String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(session), includingPropertiesForKeys: nil)) ?? []
        var out: [String: String] = [:]
        for f in files {
            out[f.lastPathComponent] = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        }
        return out
    }

    public func clear(session: String) {
        try? FileManager.default.removeItem(at: dir(session))
    }
}

/// Runs in a detached `rungrinh hook wait` process: sleeps, and pushes only if the
/// question is still unanswered. At most one reminder follows, so nothing is spammed.
public struct QuestionWaiter: Sendable {
    public let paths: Paths
    public let dispatcher: Dispatcher
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (TimeInterval) async -> Void
    public let presence: Presence

    public init(
        paths: Paths = Paths(),
        dispatcher: Dispatcher? = nil,
        presence: Presence = Presence(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { secs in
            try? await Task.sleep(nanoseconds: UInt64(max(0, secs) * 1_000_000_000))
        }
    ) {
        self.paths = paths
        self.dispatcher = dispatcher ?? Dispatcher(paths: paths)
        self.presence = presence
        self.now = now
        self.sleep = sleep
    }

    public func run(session: String, token: String) async {
        let store = PendingStore(paths: paths)
        let config = ConfigStore(paths: paths).load()
        if store.get(session: session, token: token)?.kind == .done {
            await runDone(session: session, token: token, delay: TimeInterval(max(0, config.doneDelaySeconds)))
            return
        }
        let first = TimeInterval(max(0, config.askDelaySeconds))
        var offsets = [first]
        if config.askReminderSeconds > 0 { offsets.append(first + TimeInterval(config.askReminderSeconds)) }

        for offset in offsets {
            guard let since = store.get(session: session, token: token)?.since else { return }
            await sleep(since.addingTimeInterval(offset).timeIntervalSince(now()))
            // Gone = answered, or Claude's turn / session ended.
            guard let pending = store.get(session: session, token: token) else { return }
            if !pending.toolUseIds.isEmpty, let path = pending.transcriptPath,
               Transcript.resolvedToolUseIds(path: path, among: Set(pending.toolUseIds)).count == Set(pending.toolUseIds).count {
                // Denied (no hook fires for that) or answered before PostToolUse ran.
                store.remove(session: session, token: token)
                return
            }
            let waited = formatDuration(now().timeIntervalSince(pending.since))
            await dispatcher.dispatch(
                .claudeNotification,
                Message(
                    title: "⏳ \(pending.project): Claude chờ bạn \(waited)",
                    body: Transcript.excerpt(pending.text),
                    priority: .high,
                    tags: ["hourglass"]
                )
            )
        }
    }

    /// Claude finished: push unless the user moved on by themselves within `delay`.
    /// The record stays until the next prompt so an idle_prompt doesn't push the same thing again.
    func runDone(session: String, token: String, delay: TimeInterval) async {
        let store = PendingStore(paths: paths)
        guard let since = store.get(session: session, token: token)?.since else { return }
        await sleep(since.addingTimeInterval(delay).timeIntervalSince(now()))
        // Gone = the user sent another prompt (or closed the session).
        guard let done = store.get(session: session, token: token) else { return }
        let title = done.duration.map { "✅ \(done.project) xong sau \(formatDuration($0))" } ?? "✅ \(done.project) xong"
        // Typed or clicked in Claude's window since it finished: they've seen it.
        if presence.isActive(in: done.hostPids, within: now().timeIntervalSince(done.since)) {
            History(paths: paths).append(HistoryEntry(source: Event.claudeStop(duration: nil).source, title: title, sent: false, detail: "user in Claude's window"))
            return
        }
        await dispatcher.dispatch(
            .claudeStop(duration: done.duration),
            Message(title: title, body: Transcript.excerpt(done.text), tags: ["white_check_mark"])
        )
    }
}

public enum Detached {
    /// Starts `executable args...` in its own session with stdio on /dev/null and no inherited fds,
    /// so Claude Code (which waits for the hook's pipes to close) doesn't wait for it.
    @discardableResult
    public static func spawn(_ executable: String, _ args: [String]) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        let argv = ([executable] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attr, argv, environ) == 0
    }

    /// This binary with symlinks resolved.
    public static var selfPath: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }
}
