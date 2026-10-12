import AppKit
import RungRinhCore
import SwiftUI

@main
struct RungRinhApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Menu bar only: no Dock icon even when launched outside the bundle (swift run).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            SettingsView(model: model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
