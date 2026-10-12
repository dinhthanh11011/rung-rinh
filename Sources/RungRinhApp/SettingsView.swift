import AppKit
import RungRinhCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let update = model.update, !model.installingUpdate {
                updateBanner(update)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    providerSection
                    Divider()
                    rulesSection
                    Divider()
                    claudeSection
                    Divider()
                    updateSection
                    Divider()
                    historySection
                }
                .padding(.trailing, 6)
            }
            // Fixed height: a MenuBarExtra window sizes to the ScrollView's ideal height, which is ~0.
            .frame(height: 520)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            model.reload()
            model.checkForUpdateIfStale()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: model.menuIcon)
                .font(.title2)
                .foregroundStyle(model.config.enabled && !model.config.isSnoozed() ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rung Rinh").font(.headline)
                Text(model.stateLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("30 phút") { model.snooze("30m") }
                Button("1 giờ") { model.snooze("1h") }
                Button("2 giờ") { model.snooze("2h") }
                Button("Tới 8h sáng") { model.snooze("morning") }
                if model.config.isSnoozed() {
                    Divider()
                    Button("Bỏ tạm dừng") { model.snooze("off") }
                }
            } label: {
                Image(systemName: "moon.zzz")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Tạm dừng")
            Toggle("", isOn: model.binding(\.enabled))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dịch vụ push").font(.subheadline.bold())
            Picker("", selection: model.binding(\.provider)) {
                Text("Bark").tag(Provider.bark)
                Text("ntfy").tag(Provider.ntfy)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.config.provider {
            case .bark:
                LabeledField("Device key") {
                    TextField("Lấy trong app Bark", text: model.binding(\.bark.key))
                }
                LabeledField("Server") {
                    TextField("https://api.day.app", text: model.binding(\.bark.server))
                }
                LabeledField("Mức") {
                    Picker("", selection: model.binding(\.bark.level)) {
                        Text("Time-sensitive").tag("timeSensitive")
                        Text("Bình thường").tag("active")
                        Text("Im lặng").tag("passive")
                        Text("Critical").tag("critical")
                    }
                    .labelsHidden()
                }
                LabeledField("Âm thanh") {
                    TextField("mặc định (vd: bell, minuet)", text: model.binding(\.bark.sound))
                }
                Text("Mở app Bark trên iPhone → copy phần key trong URL https://api.day.app/<KEY>/…")
                    .font(.caption2).foregroundStyle(.secondary)
            case .ntfy:
                LabeledField("Topic") {
                    TextField("vd: rungrinh-abc123 (khó đoán)", text: model.binding(\.ntfy.topic))
                }
                LabeledField("Server") {
                    TextField("https://ntfy.sh", text: model.binding(\.ntfy.server))
                }
                LabeledField("Token") {
                    SecureField("tuỳ chọn", text: model.binding(\.ntfy.token))
                }
                LabeledField("Priority") {
                    Picker("", selection: model.binding(\.ntfy.priority)) {
                        ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                }
                Text("Cài app ntfy trên điện thoại và subscribe đúng topic này.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Button(model.sending ? "Đang gửi…" : "Gửi thử") { model.sendTest() }
                    .disabled(model.sending || !model.config.isConfigured)
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chống spam").font(.subheadline.bold())
            SecondsStepper(title: "Chỉ báo khi task ≥", value: model.binding(\.minTaskSeconds), range: 0...3600, step: 10)
            SecondsStepper(title: "Cách nhau tối thiểu", value: model.binding(\.cooldownSeconds), range: 0...3600, step: 10)
            Toggle("Chỉ báo khi tôi rời máy", isOn: model.binding(\.onlyWhenIdle))
            if model.config.onlyWhenIdle {
                SecondsStepper(title: "   rảnh tay ≥", value: model.binding(\.idleSeconds), range: 10...3600, step: 10)
            }
            Toggle("Giờ yên tĩnh", isOn: model.binding(\.quietHours.enabled))
            if model.config.quietHours.enabled {
                HStack {
                    Text("Từ")
                    HourPicker(minutes: model.binding(\.quietHours.start))
                    Text("đến")
                    HourPicker(minutes: model.binding(\.quietHours.end))
                }
                .font(.callout)
            }
        }
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code").font(.subheadline.bold())
            HStack {
                Image(systemName: model.hooksInstalled ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.hooksInstalled ? .green : .orange)
                Text(model.hooksInstalled ? "Hook đã cài" : "Chưa cài hook")
                Spacer()
                Button(model.hooksInstalled ? "Gỡ" : "Cài hook") { model.toggleHooks() }
            }
            Toggle("Báo khi task xong (Stop)", isOn: model.binding(\.events.stop))
            Toggle("Báo khi Claude cần quyền / chờ input", isOn: model.binding(\.events.notification))
        }
    }

    private func updateBanner(_ update: Release) -> some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text("Có bản mới \(update.tag)").font(.callout)
            Spacer()
            Button("Cập nhật") { model.installUpdate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cập nhật").font(.subheadline.bold())
            HStack {
                Text("Phiên bản \(model.currentVersion?.description ?? "dev")")
                Spacer()
                if model.update != nil {
                    Button(model.installingUpdate ? "Đang cập nhật…" : "Cập nhật lên \(model.update!.tag)") { model.installUpdate() }
                        .disabled(model.installingUpdate)
                } else {
                    Button(model.checkingUpdate ? "Đang kiểm tra…" : "Kiểm tra") {
                        Task { await model.checkForUpdate(manual: true) }
                    }
                    .disabled(model.checkingUpdate || model.currentVersion == nil)
                }
            }
            if let status = model.updateStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Toggle("Tự động cài bản mới", isOn: model.binding(\.autoUpdate))
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gần đây").font(.subheadline.bold())
            if model.history.isEmpty {
                Text("Chưa có gì").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.history.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: e.sent ? "paperplane.fill" : "minus.circle")
                        .foregroundStyle(e.sent ? Color.accentColor : .secondary)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.caption).lineLimit(1)
                        Text("\(e.date.formatted(date: .omitted, time: .shortened)) · \(e.source)\(e.detail.map { " · \($0)" } ?? "")")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Mở cùng máy", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Button("Mở config") {
                NSWorkspace.shared.activateFileViewerSelecting([model.store.paths.config])
            }
            .font(.caption)
            Button("Thoát") { NSApp.terminate(nil) }
                .font(.caption)
        }
    }
}

// MARK: - Small controls

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading).font(.callout)
            content.textFieldStyle(.roundedBorder)
        }
    }
}

private struct SecondsStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(formatDuration(TimeInterval(value))).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

private struct HourPicker: View {
    @Binding var minutes: Int

    var body: some View {
        Picker("", selection: Binding(get: { minutes / 60 }, set: { minutes = $0 * 60 })) {
            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
        }
        .labelsHidden()
        .frame(width: 90)
    }
}
