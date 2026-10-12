import Foundation
import RungRinhCore

struct GateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func ctx(last: Date? = nil, idle: TimeInterval = 999) -> GateContext {
        GateContext(now: now, lastSentAt: last, idleSeconds: { idle })
    }

    func configured() -> Config {
        var c = Config()
        c.bark.key = "abc"
        return c
    }

    func testSendsLongTask() {
        check(Gate.decide(.claudeStop(duration: 120), config: configured(), context: ctx()) == .send)
    }

    func testDisabled() {
        var c = configured()
        c.enabled = false
        check(Gate.decide(.claudeStop(duration: 120), config: c, context: ctx()) == .skip("disabled"))
    }

    func testSnoozed() {
        var c = configured()
        c.snoozeUntil = now.addingTimeInterval(60)
        check(Gate.decide(.manual, config: c, context: ctx()) == .skip("snoozed"))
        c.snoozeUntil = now.addingTimeInterval(-60)
        check(Gate.decide(.manual, config: c, context: ctx()) == .send)
    }

    func testQuietHoursWrapMidnight() {
        var q = QuietHours()
        q.enabled = true
        q.start = 22 * 60
        q.end = 7 * 60
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h))! }
        check(q.contains(at(23), calendar: cal))
        check(q.contains(at(3), calendar: cal))
        check(!q.contains(at(12), calendar: cal))
    }

    func testTooShort() {
        check(Gate.decide(.claudeStop(duration: 12), config: configured(), context: ctx()) == .skip("too short (12s < 60s)"))
        check(Gate.decide(.command(duration: 5), config: configured(), context: ctx()) == .skip("too short (5s < 60s)"))
    }

    func testNotificationIgnoresMinDuration() {
        check(Gate.decide(.claudeNotification, config: configured(), context: ctx()) == .send)
    }

    func testIdleOnly() {
        var c = configured()
        c.onlyWhenIdle = true
        check(Gate.decide(.claudeStop(duration: 120), config: c, context: ctx(idle: 5)) == .skip("user at Mac (idle 5s < 120s)"))
        check(Gate.decide(.claudeStop(duration: 120), config: c, context: ctx(idle: 300)) == .send)
    }

    func testCooldown() {
        let c = configured()
        check(Gate.decide(.claudeStop(duration: 120), config: c, context: ctx(last: now.addingTimeInterval(-10))) == .skip("cooldown (10s < 30s)"))
        check(Gate.decide(.claudeStop(duration: 120), config: c, context: ctx(last: now.addingTimeInterval(-40))) == .send)
    }

    func testEventToggles() {
        var c = configured()
        c.events.stop = false
        c.events.notification = false
        check(Gate.decide(.claudeStop(duration: 120), config: c, context: ctx()) == .skip("stop event off"))
        check(Gate.decide(.claudeNotification, config: c, context: ctx()) == .skip("notification event off"))
    }

    func testTestAlwaysSends() {
        var c = configured()
        c.enabled = false
        check(Gate.decide(.test, config: c, context: ctx(last: now)) == .send)
    }

    func testFormatDuration() {
        check(formatDuration(42) == "42s")
        check(formatDuration(252) == "4m12s")
        check(formatDuration(3720) == "1h02m")
    }
}

struct ConfigTests {
    func tempPaths() -> Paths {
        Paths(base: FileManager.default.temporaryDirectory.appendingPathComponent("rungrinh-\(UUID().uuidString)"))
    }

    func testPartialConfigDecodesWithDefaults() throws {
        let c = try JSONCoding.decoder.decode(Config.self, from: Data(#"{"bark":{"key":"k"}}"#.utf8))
        check(c.bark.key == "k")
        check(c.bark.server == "https://api.day.app")
        check(c.minTaskSeconds == 60)
    }

    func testSetDottedKey() throws {
        let store = ConfigStore(paths: tempPaths())
        _ = try store.set("bark.key", to: "XYZ")
        _ = try store.set("minTaskSeconds", to: "90")
        _ = try store.set("provider", to: "ntfy")
        let c = store.load()
        check(c.bark.key == "XYZ")
        check(c.minTaskSeconds == 90)
        check(c.provider == .ntfy)
        expectThrows { try store.set("nope", to: "1") }
        expectThrows { try store.set("provider", to: "pigeon") }
    }

    func testSnoozeParsing() {
        let now = Date(timeIntervalSince1970: 0)
        check(Snooze.until("30m", from: now) == now.addingTimeInterval(1800))
        check(Snooze.until("1h30m", from: now) == now.addingTimeInterval(5400))
        check(Snooze.until("soon", from: now) == nil)
    }
}

struct HookInstallerTests {
    func tempSettings(_ json: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let json { try Data(json.utf8).write(to: url) }
        return url
    }

    func read(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    let existing = """
    {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],
     "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"lint"}]}]}}
    """

    func testInstallIsIdempotentAndKeepsOtherHooks() throws {
        let url = try tempSettings(existing)
        let installer = ClaudeHookInstaller(settingsURL: url)
        try installer.install(binaryPath: "/Apps/RungRinh.app/Contents/MacOS/rungrinh")
        try installer.install(binaryPath: "/Apps/RungRinh.app/Contents/MacOS/rungrinh")
        check(installer.isInstalled())

        let s = try read(url)
        check(s["model"] as? String == "opus")
        let hooks = s["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        check(stop.count == 2, "user's hook + exactly one of ours")
        check(hooks["PreToolUse"] != nil)
        check((hooks["UserPromptSubmit"] as! [[String: Any]]).count == 1)
        check(FileManager.default.fileExists(atPath: installer.backupURL.path))
    }

    func testUninstallRemovesOnlyOurs() throws {
        let url = try tempSettings(existing)
        let installer = ClaudeHookInstaller(settingsURL: url)
        try installer.install(binaryPath: "/x/rungrinh")
        try installer.uninstall()
        check(!installer.isInstalled())

        let hooks = try read(url)["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        check(stop.count == 1)
        check(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String) == "say done")
        check(hooks["UserPromptSubmit"] == nil)
        check(hooks["Notification"] == nil)
    }

    func testInstallIntoMissingFile() throws {
        let url = try tempSettings(nil)
        let installer = ClaudeHookInstaller(settingsURL: url)
        try installer.install(binaryPath: "/x/rungrinh")
        check(installer.isInstalled())
    }
}

struct HookHandlerTests {
    final class Recorder: Notifier, @unchecked Sendable {
        var messages: [Message] = []
        func send(_ message: Message) async throws { messages.append(message) }
    }

    func testPromptThenStopPushesWithDuration() async throws {
        let paths = Paths(base: FileManager.default.temporaryDirectory.appendingPathComponent("rungrinh-\(UUID().uuidString)"))
        var c = Config()
        c.bark.key = "k"
        try ConfigStore(paths: paths).save(c)

        let rec = Recorder()
        let handler = ClaudeHookHandler(paths: paths, dispatcher: Dispatcher(paths: paths, idleSeconds: { 999 }, makeNotifier: { _ in rec }))
        let t0 = Date()
        await handler.handle(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p/my-app"}"#.utf8), now: t0)
        await handler.handle(Data(#"{"hook_event_name":"Stop","session_id":"s1","cwd":"/p/my-app","last_assistant_message":"All **done**"}"#.utf8), now: t0.addingTimeInterval(252))

        check(rec.messages.count == 1)
        check(rec.messages.first?.title == "✅ my-app xong sau 4m12s")
        check(rec.messages.first?.body == "All done")

        // A quick follow-up turn is skipped and logged.
        await handler.handle(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/p/my-app"}"#.utf8), now: t0.addingTimeInterval(300))
        await handler.handle(Data(#"{"hook_event_name":"Stop","session_id":"s1","cwd":"/p/my-app"}"#.utf8), now: t0.addingTimeInterval(305))
        check(rec.messages.count == 1)
        let last = History(paths: paths).recent(1).first?.detail
        check(last == "too short (5s < 60s)", "got \(last ?? "nil")")
    }

    func testTranscriptLastAssistantText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"final answer"}]}}"#,
            #"{"type":"system","subtype":"stop"}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        check(Transcript.lastAssistantText(path: url.path) == "final answer")
    }
}

// MARK: - Runner

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var current = ""
func check(_ ok: @autoclosure () -> Bool, _ note: String = "", line: Int = #line) {
    if !ok() { failures += 1; print("  ✘ \(current) (line \(line)) \(note)") }
}
func expectThrows(line: Int = #line, _ body: () throws -> Void) {
    do { try body(); failures += 1; print("  ✘ \(current) (line \(line)) expected an error") } catch {}
}
func run(_ name: String, _ body: () async throws -> Void) async {
    current = name
    let before = failures
    do { try await body() } catch { failures += 1; print("  ✘ \(name) threw \(error)") }
    if failures == before { print("  ✔ \(name)") }
}

print("GateTests")
await run("testSendsLongTask") { GateTests().testSendsLongTask() }
await run("testDisabled") { GateTests().testDisabled() }
await run("testSnoozed") { GateTests().testSnoozed() }
await run("testQuietHoursWrapMidnight") { GateTests().testQuietHoursWrapMidnight() }
await run("testTooShort") { GateTests().testTooShort() }
await run("testNotificationIgnoresMinDuration") { GateTests().testNotificationIgnoresMinDuration() }
await run("testIdleOnly") { GateTests().testIdleOnly() }
await run("testCooldown") { GateTests().testCooldown() }
await run("testEventToggles") { GateTests().testEventToggles() }
await run("testTestAlwaysSends") { GateTests().testTestAlwaysSends() }
await run("testFormatDuration") { GateTests().testFormatDuration() }
print("ConfigTests")
await run("testPartialConfigDecodesWithDefaults") { try ConfigTests().testPartialConfigDecodesWithDefaults() }
await run("testSetDottedKey") { try ConfigTests().testSetDottedKey() }
await run("testSnoozeParsing") { ConfigTests().testSnoozeParsing() }
print("HookInstallerTests")
await run("testInstallIsIdempotentAndKeepsOtherHooks") { try HookInstallerTests().testInstallIsIdempotentAndKeepsOtherHooks() }
await run("testUninstallRemovesOnlyOurs") { try HookInstallerTests().testUninstallRemovesOnlyOurs() }
await run("testInstallIntoMissingFile") { try HookInstallerTests().testInstallIntoMissingFile() }
print("HookHandlerTests")
await run("testPromptThenStopPushesWithDuration") { try await HookHandlerTests().testPromptThenStopPushesWithDuration() }
await run("testTranscriptLastAssistantText") { try HookHandlerTests().testTranscriptLastAssistantText() }

print(failures == 0 ? "\nAll tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
