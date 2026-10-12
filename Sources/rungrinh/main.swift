import Foundation
import RungRinhCore

let usage = """
rungrinh: push notifications to your phone / watch (Bark or ntfy)

Usage:
  rungrinh notify <message> [--title T] [--priority low|normal|high] [--url U] [--tag T]
  rungrinh run [--title T] -- <command> [args...]   run a command, push when it finishes
  rungrinh test                                     send a test push (ignores all rules)
  rungrinh status                                   show config and state
  rungrinh on | off                                 enable / disable pushes
  rungrinh snooze <30m|1h|2h30m|morning|off>        pause pushes for a while
  rungrinh history [N]                              last N pushes, including skipped ones
  rungrinh config show | path | set <key> <value>   e.g. config set bark.key XXXX
  rungrinh install-hooks | uninstall-hooks          Claude Code hooks in ~/.claude/settings.json
  rungrinh shell-init zsh|bash                      auto-push for long shell commands
  rungrinh version | update                         show version / install the latest release
  rungrinh hook claude                              (called by Claude Code, reads JSON on stdin)

Config keys: enabled, provider (bark|ntfy), bark.key, bark.server, bark.sound, bark.level,
  ntfy.server, ntfy.topic, ntfy.token, ntfy.priority, minTaskSeconds, cooldownSeconds,
  onlyWhenIdle, idleSeconds, quietHours.enabled, quietHours.start, quietHours.end (minutes),
  events.stop, events.notification, doneDelaySeconds, askDelaySeconds, askReminderSeconds (0 = no reminder), autoUpdate
"""

func fail(_ text: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("rungrinh: \(text)\n".utf8))
    exit(code)
}

/// Absolute path of this binary with symlinks resolved, so hooks point into the app bundle.
func selfPath() -> String {
    let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
}

struct Options {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var tags: [String] = []
    var rest: [String] = []

    init(_ args: ArraySlice<String>, valued: Set<String>) {
        var it = args.makeIterator()
        while let a = it.next() {
            if a == "--" {
                while let r = it.next() { rest.append(r) }
                break
            }
            if a.hasPrefix("--"), valued.contains(String(a.dropFirst(2))) {
                let key = String(a.dropFirst(2))
                guard let v = it.next() else { fail("missing value for \(a)") }
                if key == "tag" { tags.append(v) } else { flags[key] = v }
            } else {
                positional.append(a)
            }
        }
    }
}

let store = ConfigStore()
let dispatcher = Dispatcher()
let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "help"
let tail = args.dropFirst()

func printResult(_ r: DispatchResult) {
    switch r.decision {
    case .send where r.error == nil: print("sent")
    case .send: fail("send failed: \(r.error ?? "")")
    case .skip(let reason): print("skipped: \(reason)")
    }
}

func describe(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

switch command {
case "notify":
    let o = Options(tail, valued: ["title", "priority", "url", "tag"])
    let body = o.positional.joined(separator: " ")
    guard !body.isEmpty || o.flags["title"] != nil else { fail("notify needs a message") }
    let priority = o.flags["priority"].flatMap(Priority.init(rawValue:)) ?? .normal
    let msg = Message(title: o.flags["title"] ?? "🔔 rungrinh", body: body, priority: priority, url: o.flags["url"], tags: o.tags)
    printResult(await dispatcher.dispatch(.manual, msg))

case "test":
    let r = await dispatcher.dispatch(.test, Message(title: "🔔 Rung Rinh", body: "Test push từ \(Host.current().localizedName ?? "Mac") ✅"))
    printResult(r)

case "run":
    let o = Options(tail, valued: ["title"])
    let cmd = o.rest.isEmpty ? o.positional : o.rest
    guard !cmd.isEmpty else { fail("usage: rungrinh run -- <command> [args...]") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = cmd
    // Ctrl-C goes to the child (same process group); we stay alive to report it.
    signal(SIGINT, SIG_IGN)
    let start = Date()
    do { try p.run() } catch { fail("cannot run \(cmd[0]): \(error.localizedDescription)") }
    p.waitUntilExit()
    let elapsed = Date().timeIntervalSince(start)
    let code = p.terminationStatus
    let label = o.flags["title"] ?? cmd.joined(separator: " ")
    let ok = code == 0
    let msg = Message(
        title: "\(ok ? "✅" : "❌") \(Transcript.excerpt(label, limit: 60))",
        body: "\(ok ? "Xong" : "Lỗi (exit \(code))") sau \(formatDuration(elapsed))",
        priority: ok ? .normal : .high,
        tags: [ok ? "white_check_mark" : "x"]
    )
    await dispatcher.dispatch(.command(duration: elapsed), msg)
    exit(code)

case "command-done":
    // Called by the shell integration in the background.
    let o = Options(tail, valued: ["seconds", "exit"])
    let elapsed = TimeInterval(o.flags["seconds"] ?? "") ?? 0
    let code = Int(o.flags["exit"] ?? "") ?? 0
    let cmdline = (o.rest + o.positional).joined(separator: " ")
    let ok = code == 0
    let msg = Message(
        title: "\(ok ? "✅" : "❌") \(Transcript.excerpt(cmdline, limit: 60))",
        body: "\(ok ? "Xong" : "Lỗi (exit \(code))") sau \(formatDuration(elapsed))",
        priority: ok ? .normal : .high
    )
    await dispatcher.dispatch(.command(duration: elapsed), msg)

case "hook":
    if tail.first == "wait" {
        // Spawned detached by the Claude hook; see QuestionWaiter.
        let a = Array(tail.dropFirst())
        guard a.count == 2 else { fail("usage: rungrinh hook wait <session> <token>") }
        await QuestionWaiter().run(session: a[0], token: a[1])
        exit(0)
    }
    guard tail.first == "claude" else { fail("usage: rungrinh hook claude") }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    await ClaudeHookHandler().handle(data)
    exit(0) // never block Claude Code

case "on", "off":
    try store.update { $0.enabled = command == "on"; if command == "on" { $0.snoozeUntil = nil } }
    print(command == "on" ? "enabled" : "disabled")

case "snooze":
    guard let spec = tail.first else { fail("usage: rungrinh snooze <30m|1h|morning|off>") }
    if spec == "off" {
        try store.update { $0.snoozeUntil = nil }
        print("snooze cleared")
    } else {
        guard let until = Snooze.until(spec) else { fail("cannot parse '\(spec)'") }
        try store.update { $0.snoozeUntil = until }
        print("snoozed until \(describe(until))")
    }

case "status":
    let c = store.load()
    let state = StateStore()
    var lines = [
        "enabled:      \(c.enabled)" + (c.isSnoozed() ? " (snoozed until \(describe(c.snoozeUntil!)))" : ""),
        "provider:     \(c.provider.rawValue)" + (c.isConfigured ? "" : "  ⚠️ not configured"),
    ]
    switch c.provider {
    case .bark: lines.append("bark:         \(c.bark.server)  key=\(c.bark.key.isEmpty ? "-" : String(c.bark.key.prefix(4)) + "…")")
    case .ntfy: lines.append("ntfy:         \(c.ntfy.server)/\(c.ntfy.topic)")
    }
    lines += [
        "min task:     \(c.minTaskSeconds)s   cooldown: \(c.cooldownSeconds)s",
        "only idle:    \(c.onlyWhenIdle ? "yes (≥ \(c.idleSeconds)s)" : "no")   idle now: \(Int(IdleTime.seconds()))s",
        "done delay:   " + (c.doneDelaySeconds > 0 ? "push \(c.doneDelaySeconds)s after a task ends unless you're back on it" : "push right away"),
        "ask delay:    push after \(c.askDelaySeconds)s unanswered" + (c.askReminderSeconds > 0 ? ", remind once after +\(c.askReminderSeconds)s" : ""),
        "quiet hours:  " + (c.quietHours.enabled ? String(format: "%02d:%02d–%02d:%02d", c.quietHours.start / 60, c.quietHours.start % 60, c.quietHours.end / 60, c.quietHours.end % 60) : "off"),
        "claude hooks: \(ClaudeHookInstaller().isInstalled() ? "installed" : "not installed")",
        "last push:    \(state.lastSentAt.map(describe) ?? "-")",
        "config:       \(store.paths.config.path)",
    ]
    print(lines.joined(separator: "\n"))

case "history":
    let n = tail.first.flatMap(Int.init) ?? 20
    let entries = History().recent(n)
    if entries.isEmpty { print("(empty)") }
    for e in entries.reversed() {
        print("\(describe(e.date))  \(e.sent ? "✓" : "·") [\(e.source)] \(e.title)\(e.detail.map { "  — \($0)" } ?? "")")
    }

case "config":
    switch tail.first {
    case "path":
        print(store.paths.config.path)
    case "set":
        let rest = Array(tail.dropFirst())
        guard rest.count >= 2 else { fail("usage: rungrinh config set <key> <value>") }
        do {
            _ = try store.set(rest[0], to: rest.dropFirst().joined(separator: " "))
            print("ok")
        } catch { fail(error.localizedDescription) }
    default:
        print(String(decoding: try JSONCoding.encoder.encode(store.load()), as: UTF8.self))
    }

case "install-hooks":
    let o = Options(tail, valued: ["binary"])
    let bin = o.flags["binary"] ?? selfPath()
    let installer = ClaudeHookInstaller()
    try installer.install(binaryPath: bin)
    print("installed hooks → \(installer.settingsURL.path)\n  command: \(ClaudeHookInstaller.command(forBinary: bin))\n  backup:  \(installer.backupURL.path)")

case "uninstall-hooks":
    try ClaudeHookInstaller().uninstall()
    print("removed rungrinh hooks")

case "shell-init":
    guard let script = ShellInit.script(for: tail.first ?? "zsh", binary: selfPath()) else { fail("supported shells: zsh, bash") }
    print(script)

case "version", "--version":
    print(Updater.currentVersion?.description ?? "dev")

case "update":
    let latest = try await Updater().latestRelease()
    if let current = Updater.currentVersion, let v = latest.version, !(current < v) {
        print("already up to date (\(current))")
    } else {
        print("installing \(latest.tag)…")
        let p = Updater.installProcess(tag: latest.tag)
        try p.run()
        p.waitUntilExit()
        exit(p.terminationStatus)
    }

case "help", "-h", "--help":
    print(usage)

default:
    fail("unknown command '\(command)'\n\n\(usage)")
}
