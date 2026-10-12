import AppKit
import Foundation
import RungRinhCore
import ServiceManagement
import SwiftUI

/// One-line feedback shown under the control that caused it.
struct Notice: Equatable {
    enum Kind { case success, error, info, progress }
    let kind: Kind
    let text: String

    static func success(_ t: String) -> Notice { Notice(kind: .success, text: t) }
    static func error(_ t: String) -> Notice { Notice(kind: .error, text: t) }
    static func info(_ t: String) -> Notice { Notice(kind: .info, text: t) }
    static func progress(_ t: String) -> Notice { Notice(kind: .progress, text: t) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var config: Config
    @Published var history: [HistoryEntry] = []
    @Published var hooksInstalled = false
    /// Feedback for the push test (Push tab).
    @Published var pushNotice: Notice?
    /// Feedback for hooks / login item (Claude and App tabs).
    @Published var notice: Notice?
    @Published var sending = false
    @Published var launchAtLogin = false
    @Published var update: Release?
    @Published var updateNotice: Notice?
    @Published var checkingUpdate = false
    @Published var installingUpdate = false
    @Published private(set) var lastUpdateCheck: Date?
    /// Set on the first launch after the version changed, i.e. right after an update.
    @Published var justUpdatedTo: Version?

    let store = ConfigStore()
    private let installer = ClaudeHookInstaller()
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private var timer: Timer?
    private var updateTimer: Timer?
    private let updater = Updater()
    private var wakeObserver: NSObjectProtocol?
    private var debugWindow: NSWindow?
    let currentVersion = Updater.currentVersion

    init() {
        config = store.load()
        reload()
        noteVersionChange()
        if ProcessInfo.processInfo.environment["RUNGRINH_DEBUG_WINDOW"] != nil {
            DispatchQueue.main.async { self.openDebugWindow() }
        }
        // Pick up changes made from the CLI (rungrinh off, snooze, ...) and snooze expiry.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        Task { await checkForUpdate(manual: false) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdate(manual: false) }
        }
        // Lid opened / Mac woke up: the 6h timer may have been asleep the whole time.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdate(manual: false) }
        }
    }

    /// Path of the CLI shipped next to the app binary inside the bundle.
    var cliPath: String {
        let dir = (Bundle.main.executablePath.map { ($0 as NSString).deletingLastPathComponent }) ?? ""
        return (dir as NSString).appendingPathComponent("rungrinh")
    }

    func reload() {
        let fresh = store.load()
        if !dirty, fresh != config { config = fresh }
        history = History().recent(30)
        hooksInstalled = installer.isInstalled()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Debounced save so typing a key doesn't rewrite the file on every keystroke.
    func save() {
        saveTask?.cancel()
        dirty = true
        let snapshot = config
        saveTask = Task { [weak self, store] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? store.save(snapshot)
            self?.dirty = false
        }
    }

    func binding<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.config[keyPath: keyPath] = $0; self.save() }
        )
    }

    var menuIcon: String {
        if !config.enabled { return "bell.slash" }
        if config.isSnoozed() { return "moon.zzz" }
        if !config.isConfigured { return "bell.badge" }
        return "bell.and.waves.left.and.right"
    }

    var stateLabel: String {
        if !config.enabled { return "Đang tắt" }
        if let until = config.snoozeUntil, config.isSnoozed() {
            return "Tạm dừng tới \(until.formatted(date: .omitted, time: .shortened))"
        }
        if !config.isConfigured { return "Chưa cấu hình \(config.provider == .bark ? "Bark key" : "ntfy topic")" }
        return "Đang bật"
    }

    func snooze(_ spec: String) {
        config.snoozeUntil = spec == "off" ? nil : Snooze.until(spec)
        save()
    }

    func sendTest() {
        sending = true
        pushNotice = .progress("Đang gửi…")
        let config = self.config
        Task {
            try? store.save(config)
            let r = await Dispatcher().dispatch(.test, Message(title: "🔔 Rung Rinh", body: "Test push từ menu bar ✅"), config: config)
            sending = false
            pushNotice = r.sent ? .success("Đã gửi, kiểm tra điện thoại") : .error(r.error ?? "Không gửi được")
            reload()
        }
    }

    func toggleHooks() {
        do {
            if hooksInstalled {
                try installer.uninstall()
                notice = .success("Đã gỡ hook Claude Code")
            } else {
                try installer.install(binaryPath: cliPath)
                notice = .success("Đã cài hook, bản cũ lưu ở settings.json.rungrinh-backup")
            }
        } catch {
            notice = .error(error.localizedDescription)
        }
        reload()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = .error("Mở cùng máy: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Updates

    private static let lastRunVersionKey = "lastRunVersion"

    private func noteVersionChange() {
        guard let current = currentVersion else { return }
        let defaults = UserDefaults.standard
        if let previous = defaults.string(forKey: Self.lastRunVersionKey).flatMap(Version.init) {
            if previous < current { justUpdatedTo = current }
        } else if FileManager.default.fileExists(atPath: store.paths.config.path) {
            // Versions before 0.3.0 didn't record themselves; an existing config means this isn't a fresh install.
            justUpdatedTo = current
        }
        defaults.set(current.description, forKey: Self.lastRunVersionKey)
    }

    /// Called when the popover opens; cheap enough but no need to hit GitHub on every click.
    func checkForUpdateIfStale() {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 30 * 60 { return }
        Task { await checkForUpdate(manual: false) }
    }

    func checkForUpdate(manual: Bool) async {
        guard let current = currentVersion else {
            if manual { updateNotice = .info("Bản dev (chạy ngoài app bundle) không tự cập nhật") }
            return
        }
        guard !checkingUpdate, !installingUpdate else { return }
        checkingUpdate = true
        lastUpdateCheck = Date()
        if manual { updateNotice = .progress("Đang kiểm tra…") }
        defer { checkingUpdate = false }
        do {
            update = try await updater.availableUpdate(current: current)
            if let update {
                updateNotice = .info("Có bản mới \(update.tag)")
                if config.autoUpdate && !manual { installUpdate() }
            } else {
                updateNotice = .success("Đang dùng bản mới nhất (\(current))")
            }
        } catch {
            updateNotice = .error("Không kiểm tra được: \(error.localizedDescription)")
        }
    }

    /// install.sh quits this app and relaunches the new one, so nothing after this needs to run.
    func installUpdate() {
        guard let update else { return }
        do {
            try updater.install(tag: update.tag, log: store.paths.log) { code in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if code == 0 {
                        // Installed, but the script couldn't quit us (older install.sh): restart into the new build.
                        self.relaunch()
                    } else {
                        self.installingUpdate = false
                        self.updateNotice = .error("Cập nhật lỗi (exit \(code)), xem rungrinh.log")
                    }
                }
            }
            installingUpdate = true
            updateNotice = .progress("Đang tải \(update.tag). App sẽ tự đóng rồi mở lại…")
        } catch {
            updateNotice = .error("Không chạy được trình cập nhật: \(error.localizedDescription)")
        }
    }

    /// Dev aid: RUNGRINH_DEBUG_WINDOW=1 shows the popover content in a normal window, e.g. for screenshots.
    private func openDebugWindow() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: self)))
        window.title = "Rung Rinh"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                       "relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
