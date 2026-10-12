import AppKit
import RungRinhCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case push, rules, claude, history, app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .push: return "Thông báo"
        case .rules: return "Quy tắc"
        case .claude: return "Claude"
        case .history: return "Lịch sử"
        case .app: return "Ứng dụng"
        }
    }

    var icon: String {
        switch self {
        case .push: return "paperplane"
        case .rules: return "slider.horizontal.3"
        case .claude: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        case .app: return "gearshape"
        }
    }

    /// Not every symbol has a .fill variant.
    var selectedIcon: String {
        switch self {
        case .push, .app: return icon + ".fill"
        default: return icon
        }
    }
}

/// Root of the menu bar popover: header, banners, tab bar, then the selected tab.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("selectedTab") private var tab: SettingsTab = .push

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.m)

            UpdateBanner(model: model)

            TabBar(selection: $tab, badges: badges)
                .padding(.horizontal, Spacing.m)
                .padding(.bottom, Spacing.s)

            Divider()

            Group {
                switch tab {
                case .push: PushTab(model: model)
                case .rules: RulesTab(model: model)
                case .claude: ClaudeTab(model: model)
                case .history: HistoryTab(model: model) { tab = .push }
                case .app: AppTab(model: model)
                }
            }
            .formStyle(.grouped)
            .frame(height: 400)
        }
        .frame(width: 400)
    }

    /// Small dots on tabs that need attention.
    private var badges: [SettingsTab: Color] {
        var b: [SettingsTab: Color] = [:]
        if !model.config.isConfigured { b[.push] = .orange }
        if !model.hooksInstalled { b[.claude] = .orange }
        if model.update != nil { b[.app] = .accentColor }
        return b
    }
}

// MARK: - Header

private struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Rung Rinh").font(.headline)
                StatusPill(text: model.stateLabel, color: stateColor)
            }

            Spacer()

            Menu {
                Section("Tạm dừng thông báo") {
                    Button("30 phút") { model.snooze("30m") }
                    Button("1 giờ") { model.snooze("1h") }
                    Button("2 giờ") { model.snooze("2h") }
                    Button("Tới 8 giờ sáng") { model.snooze("morning") }
                }
                if model.config.isSnoozed() {
                    Divider()
                    Button("Bỏ tạm dừng") { model.snooze("off") }
                }
            } label: {
                Image(systemName: model.config.isSnoozed() ? "moon.zzz.fill" : "moon.zzz")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Tạm dừng")
            .accessibilityLabel("Tạm dừng thông báo")

            Toggle("Bật thông báo", isOn: model.binding(\.enabled))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.config.enabled ? "Tắt thông báo" : "Bật thông báo")
        }
    }

    private var stateColor: Color {
        if !model.config.enabled { return .secondary }
        if model.config.isSnoozed() { return .purple }
        if !model.config.isConfigured { return .orange }
        return .green
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @Binding var selection: SettingsTab
    let badges: [SettingsTab: Color]
    // @StateObject, not @State: @State is a macro in the current SDK and its plugin ships only with Xcode.
    @StateObject private var hover = HoverState()

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: selected ? tab.selectedIcon : tab.icon)
                            .font(.system(size: 15, weight: .medium))
                            .frame(height: 18)
                            .overlay(alignment: .topTrailing) {
                                if let color = badges[tab] {
                                    Circle().fill(color).frame(width: 7, height: 7).offset(x: 5, y: -2)
                                }
                            }
                        Text(tab.title).font(.caption2.weight(selected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.14)
                                  : hover.tab == tab ? Color.primary.opacity(0.06) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hover.tab = tab } else if hover.tab == tab { hover.tab = nil }
                }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

private final class HoverState: ObservableObject {
    @Published var tab: SettingsTab?
}

// MARK: - Update banner

/// Shown above the tabs while an update is available / installing, and once right after updating.
private struct UpdateBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.installingUpdate {
            Banner(tint: .accentColor) {
                ProgressView().controlSize(.small)
                Text(model.updateNotice?.text ?? "Đang cập nhật…").font(.callout)
                Spacer()
            }
        } else if let update = model.update {
            Banner(tint: .accentColor) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Có bản mới \(update.tag)").font(.callout.weight(.medium))
                    if let url = update.url {
                        Link("Xem thay đổi", destination: url).font(.caption)
                    }
                }
                Spacer()
                Button("Cập nhật") { model.installUpdate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        } else if let version = model.justUpdatedTo {
            Banner(tint: .green) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Đã cập nhật lên v\(version.description)").font(.callout.weight(.medium))
                    Link("Xem có gì mới", destination: Updater.releaseURL(version))
                        .font(.caption)
                }
                Spacer()
                Button {
                    model.justUpdatedTo = nil
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Đóng")
            }
        }
    }
}

private struct Banner<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Spacing.s) { content }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.m)
    }
}
