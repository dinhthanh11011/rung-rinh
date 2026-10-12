import AppKit
import Foundation
import RungRinhCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var config: Config
    @Published var history: [HistoryEntry] = []
    @Published var hooksInstalled = false
    @Published var status: String?
    @Published var sending = false
    @Published var launchAtLogin = false
    @Published var update: Release?
    @Published var updateStatus: String?
    @Published var checkingUpdate = false
    @Published var installingUpdate = false

    let store = ConfigStore()
    private let installer = ClaudeHookInstaller()
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private var timer: Timer?
    private var updateTimer: Timer?
    private let updater = Updater()
    private var lastUpdateCheck: Date?
    private var wakeObserver: NSObjectProtocol?
    let currentVersion = Updater.currentVersion

    init() {
        config = store.load()
        reload()
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
        history = History().recent(10)
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
        status = nil
        let config = self.config
        Task {
            try? store.save(config)
            let r = await Dispatcher().dispatch(.test, Message(title: "🔔 Rung Rinh", body: "Test push từ menu bar ✅"), config: config)
            sending = false
            status = r.sent ? "Đã gửi ✓" : "Lỗi: \(r.error ?? "?")"
            reload()
        }
    }

    func toggleHooks() {
        do {
            if hooksInstalled {
                try installer.uninstall()
                status = "Đã gỡ hook Claude Code"
            } else {
                try installer.install(binaryPath: cliPath)
                status = "Đã cài hook (backup: settings.json.rungrinh-backup)"
            }
        } catch {
            status = "Lỗi: \(error.localizedDescription)"
        }
        reload()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Updates

    /// Called when the popover opens; cheap enough but no need to hit GitHub on every click.
    func checkForUpdateIfStale() {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 30 * 60 { return }
        Task { await checkForUpdate(manual: false) }
    }

    func checkForUpdate(manual: Bool) async {
        guard let current = currentVersion else {
            if manual { updateStatus = "Đang chạy ngoài app bundle, không kiểm tra được" }
            return
        }
        guard !checkingUpdate, !installingUpdate else { return }
        checkingUpdate = true
        lastUpdateCheck = Date()
        defer { checkingUpdate = false }
        do {
            update = try await updater.availableUpdate(current: current)
            if let update {
                updateStatus = "Có bản mới \(update.tag)"
                if config.autoUpdate && !manual { installUpdate() }
            } else if manual {
                updateStatus = "Đang dùng bản mới nhất"
            }
        } catch {
            if manual { updateStatus = "Lỗi kiểm tra: \(error.localizedDescription)" }
        }
    }

    /// install.sh quits this app and relaunches the new one, so nothing after this needs to run.
    func installUpdate() {
        guard let update else { return }
        do {
            try updater.install(tag: update.tag, log: store.paths.log) { code in
                Task { @MainActor [weak self] in
                    self?.installingUpdate = false
                    self?.updateStatus = "Cập nhật lỗi (exit \(code)), xem rungrinh.log"
                }
            }
            installingUpdate = true
            updateStatus = "Đang cập nhật lên \(update.tag)…"
        } catch {
            updateStatus = "Lỗi cập nhật: \(error.localizedDescription)"
        }
    }
}
