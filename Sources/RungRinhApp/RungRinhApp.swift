import AppKit
import Combine
import RungRinhCore
import SwiftUI

/// Plain AppKit status item + popover instead of SwiftUI's MenuBarExtra: MenuBarExtra creates the model lazily
/// with its UI, which didn't happen when install.sh relaunched the app from the background, so the startup work
/// (version bookkeeping, update checks) never ran. This also lets us open the popover ourselves after an update.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var iconSubscription: AnyCancellable?
    private var shownIcon = ""

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon even when launched outside the bundle (swift run).
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        Log().write("app started v\(model.currentVersion?.description ?? "dev")")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.setAccessibilityLabel("Rung Rinh")
        iconSubscription = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshIcon() }
        refreshIcon()

        let host = NSHostingController(rootView: SettingsView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        // Right after an update, show what happened instead of silently swapping the app.
        if model.justUpdatedTo != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showPopover() }
        }
    }

    private func refreshIcon() {
        // objectWillChange fires before the change lands; read the new state on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button, self.model.menuIcon != self.shownIcon else { return }
            self.shownIcon = self.model.menuIcon
            let image = NSImage(systemSymbolName: self.model.menuIcon, accessibilityDescription: "Rung Rinh")
            image?.isTemplate = true
            button.image = image
        }
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.reload()
        model.checkForUpdateIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Accessory apps aren't active by default, and text fields need key focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
}
