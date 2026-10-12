import AppKit
import RungRinhCore
import SwiftUI

// MARK: - Thông báo

struct PushTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Gửi qua", selection: model.binding(\.provider)) {
                    Text("Bark").tag(Provider.bark)
                    Text("ntfy").tag(Provider.ntfy)
                }
                .pickerStyle(.segmented)
            }

            switch model.config.provider {
            case .bark:
                Section {
                    TextField("Device key", text: model.binding(\.bark.key), prompt: Text("Dán key từ app Bark"))
                    TextField("Server", text: model.binding(\.bark.server), prompt: Text("https://api.day.app"))
                    Picker("Mức ưu tiên", selection: model.binding(\.bark.level)) {
                        Text("Time-sensitive").tag("timeSensitive")
                        Text("Bình thường").tag("active")
                        Text("Im lặng").tag("passive")
                        Text("Critical").tag("critical")
                    }
                    TextField("Âm thanh", text: model.binding(\.bark.sound), prompt: Text("mặc định"))
                } header: {
                    Text("Bark")
                } footer: {
                    FormFooter("Mở app Bark trên iPhone, key là phần nằm trong URL api.day.app/<KEY>/…")
                }
            case .ntfy:
                Section {
                    TextField("Topic", text: model.binding(\.ntfy.topic), prompt: Text("tên khó đoán, vd rungrinh-x7k2"))
                    TextField("Server", text: model.binding(\.ntfy.server), prompt: Text("https://ntfy.sh"))
                    SecureField("Token", text: model.binding(\.ntfy.token), prompt: Text("tuỳ chọn"))
                    Picker("Mức ưu tiên", selection: model.binding(\.ntfy.priority)) {
                        Text("1 · Thấp nhất").tag(1)
                        Text("2 · Thấp").tag(2)
                        Text("3 · Bình thường").tag(3)
                        Text("4 · Cao").tag(4)
                        Text("5 · Khẩn").tag(5)
                    }
                } header: {
                    Text("ntfy")
                } footer: {
                    FormFooter("Cài app ntfy trên điện thoại và subscribe đúng topic này.")
                }
            }

            Section {
                HStack {
                    Button {
                        model.sendTest()
                    } label: {
                        Label("Gửi thử", systemImage: "paperplane")
                    }
                    .disabled(model.sending || !model.config.isConfigured)
                    Spacer()
                    if !model.config.isConfigured {
                        Text("Nhập \(model.config.provider == .bark ? "device key" : "topic") trước")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                NoticeView(notice: model.pushNotice)
            }
        }
    }
}

// MARK: - Quy tắc

struct RulesTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                SecondsStepper(title: "Chỉ báo khi task chạy ≥", value: model.binding(\.minTaskSeconds), range: 0...3600, step: 10)
                SecondsStepper(title: "Hai lần báo cách nhau ≥", value: model.binding(\.cooldownSeconds), range: 0...3600, step: 10)
            } header: {
                Text("Chống spam")
            } footer: {
                FormFooter("Task ngắn hơn ngưỡng sẽ không báo. Lần nào bị bỏ qua cũng được ghi lý do ở tab Lịch sử.")
            }

            Section {
                Toggle("Chỉ báo khi tôi rời máy", isOn: model.binding(\.onlyWhenIdle))
                if model.config.onlyWhenIdle {
                    SecondsStepper(title: "Không chạm phím/chuột ≥", value: model.binding(\.idleSeconds), range: 10...3600, step: 10)
                }
            } header: {
                Text("Khi đang ngồi máy")
            } footer: {
                FormFooter("Đang ngồi trước máy thì bạn đã thấy kết quả rồi, không cần rung cổ tay.")
            }

            Section("Giờ yên tĩnh") {
                Toggle("Không báo trong khung giờ", isOn: model.binding(\.quietHours.enabled))
                if model.config.quietHours.enabled {
                    HourPicker(title: "Từ", minutes: model.binding(\.quietHours.start))
                    HourPicker(title: "Đến", minutes: model.binding(\.quietHours.end))
                }
            }
        }
    }
}

// MARK: - Claude

struct ClaudeTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Trạng thái") {
                    Label(model.hooksInstalled ? "Đã cài" : "Chưa cài",
                          systemImage: model.hooksInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(model.hooksInstalled ? .green : .orange)
                }
                HStack {
                    if model.hooksInstalled {
                        Button("Gỡ hook", role: .destructive) { model.toggleHooks() }
                    } else {
                        Button("Cài hook") { model.toggleHooks() }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                NoticeView(notice: model.notice)
            } header: {
                Text("Hook Claude Code")
            } footer: {
                FormFooter("Ghi vào ~/.claude/settings.json, bản cũ được backup. Hook luôn thoát 0 nên không bao giờ chặn Claude.")
            }

            Section("Báo khi") {
                Toggle("Claude làm xong task", isOn: model.binding(\.events.stop))
                Toggle("Claude cần cấp quyền hoặc chờ trả lời", isOn: model.binding(\.events.notification))
            }

            if model.config.events.notification {
                Section {
                    SecondsStepper(title: "Báo khi chưa trả lời sau", value: model.binding(\.askDelaySeconds), range: 0...1800, step: 15)
                    SecondsStepper(title: "Nhắc lại một lần sau thêm", value: model.binding(\.askReminderSeconds), range: 0...7200, step: 60)
                } header: {
                    Text("Claude hỏi hoặc xin quyền")
                } footer: {
                    FormFooter("Bạn trả lời kịp thì không push gì. Đặt nhắc lại = 0 để chỉ báo một lần.")
                }
            }
        }
    }
}

// MARK: - Lịch sử

struct HistoryTab: View {
    @ObservedObject var model: AppModel
    let goToPush: () -> Void

    var body: some View {
        if model.history.isEmpty {
            EmptyState(
                icon: "tray",
                title: "Chưa có thông báo nào",
                message: "Mỗi lần push, kể cả lần bị bỏ qua, sẽ hiện ở đây kèm lý do.",
                action: ("Gửi thử một thông báo", goToPush)
            )
        } else {
            Form {
                Section("Gần đây") {
                    ForEach(Array(model.history.enumerated()), id: \.offset) { _, e in
                        HistoryRow(entry: e)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: entry.sent ? "paperplane.circle.fill" : "minus.circle")
                .font(.title3)
                .foregroundStyle(entry.sent ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Text(entry.date.formatted(date: .omitted, time: .shortened))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let status = entry.sent ? "Đã gửi" : "Bỏ qua"
        return ([status, entry.source] + [entry.detail].compactMap { $0 }).joined(separator: " · ")
    }
}

// MARK: - Ứng dụng

struct AppTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Phiên bản", value: model.currentVersion.map { "v\($0)" } ?? "dev")
                LabeledContent("Kiểm tra lần cuối") {
                    if let last = model.lastUpdateCheck {
                        Text(last, style: .relative) + Text(" trước")
                    } else {
                        Text("chưa")
                    }
                }
                HStack {
                    if let update = model.update {
                        Button("Cập nhật lên \(update.tag)") { model.installUpdate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.installingUpdate)
                    } else {
                        Button {
                            Task { await model.checkForUpdate(manual: true) }
                        } label: {
                            Label("Kiểm tra cập nhật", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.checkingUpdate || model.installingUpdate || model.currentVersion == nil)
                    }
                    Spacer()
                }
                NoticeView(notice: model.updateNotice)
                Toggle("Tự động cài bản mới", isOn: model.binding(\.autoUpdate))
            } header: {
                Text("Cập nhật")
            } footer: {
                FormFooter("Tự kiểm tra khi mở app, khi máy thức dậy và mỗi 6 giờ.")
            }

            Section("Chung") {
                Toggle("Mở cùng máy", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                LabeledContent("File config") {
                    Button("Hiện trong Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.paths.config])
                    }
                }
            }

            Section {
                Button("Thoát Rung Rinh", role: .destructive) { NSApp.terminate(nil) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
