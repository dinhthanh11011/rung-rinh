# Rung Rinh 🔔

App trên menu bar macOS kèm CLI, đẩy thông báo lên iPhone qua **Bark** hoặc **ntfy**. Thông báo trên iPhone sẽ hiện tiếp lên đồng hồ, nên đồng hồ của bạn thành cái *pager*: Claude Code chạy xong task, build xong hay CI fail là cổ tay rung.

## Cài đặt

```bash
curl -fsSL https://raw.githubusercontent.com/dinhthanh11011/rung-rinh/main/install.sh | bash
```

Lệnh này tải bản release mới nhất (universal, chạy được trên cả Apple Silicon lẫn Intel), cài vào `~/Applications/RungRinh.app` và link CLI vào `~/.local/bin/rungrinh`. Muốn cập nhật thì chạy lại đúng lệnh đó.

```bash
curl -fsSL .../install.sh | bash -s -- --hooks       # cài luôn hook Claude Code
curl -fsSL .../install.sh | bash -s -- --uninstall   # gỡ app, CLI và hook (vẫn giữ config)
```

Nếu muốn build từ source: `scripts/build-app.sh` (chỉ cần Command Line Tools: `xcode-select --install`).

1. Bấm icon 🔔 trên menu bar.
2. Chọn Bark và dán device key (key là phần nằm trong URL `https://api.day.app/<KEY>/...` hiện trong app Bark), hoặc chọn ntfy và nhập topic.
3. Bấm **Gửi thử**.
4. Bấm **Cài hook** để gắn vào Claude Code. App ghi vào `~/.claude/settings.json` và backup bản cũ thành `settings.json.rungrinh-backup`.

## Chống spam

| Luật | Mặc định |
|---|---|
| Chỉ báo khi task chạy ≥ N giây | 60s |
| Hai lần push cách nhau tối thiểu | 30s |
| Chỉ báo khi bạn rời máy (không chạm phím/chuột ≥ N giây) | tắt |
| Giờ yên tĩnh | tắt |
| Tạm dừng 30 phút / 1 giờ / tới sáng | — |

Lần push nào bị bỏ qua cũng được ghi lý do vào phần "Gần đây" và vào `rungrinh history`.

## Claude Code

`rungrinh hook claude` được gọi ở 3 event:
- `UserPromptSubmit`: ghi lại thời điểm bắt đầu task.
- `Stop`: tính thời lượng rồi push `✅ <project> xong sau 4m12s` kèm trích đoạn câu trả lời cuối.
- `Notification`: Claude đang chờ cấp quyền hoặc chờ input → push `⏳ Claude cần bạn`.

Hook không cần app đang chạy và luôn exit 0, nên không bao giờ làm Claude Code bị chặn. Lỗi được ghi vào `~/.config/rungrinh/rungrinh.log`.

## CLI

```bash
rungrinh notify "Deploy xong" --title "🚀 prod" --priority high --url https://...
rungrinh run -- npm test             # chạy lệnh, xong thì push ✅/❌ (chỉ khi chạy lâu hơn ngưỡng)
rungrinh run -- gh run watch         # CI xong là đồng hồ rung
eval "$(rungrinh shell-init zsh)"    # trong ~/.zshrc: lệnh nào chạy > $RUNGRINH_MIN (30s) cũng tự push
rungrinh on | off | snooze 1h | snooze morning | snooze off
rungrinh status | history 20
rungrinh config set bark.key XXXX    # cấu hình không cần mở app (dotfiles, máy CI)
rungrinh install-hooks | uninstall-hooks
```

Config lưu ở `~/.config/rungrinh/config.json` (quyền 600), dùng chung cho app và CLI.

## Dev

```bash
swift build
swift run selftest      # test (dạng executable, vì XCTest / swift-testing cần Xcode)
swift run RungRinhApp   # chạy app trực tiếp
scripts/release.sh v0.2.0 "ghi chú"   # build universal + tạo GitHub release cho install.sh
```

## Ý tưởng tiếp theo
- `rungrinh wait-pid <pid>`: báo khi một process đang chạy sẵn kết thúc.
- `cmd | rungrinh pipe --match "ERROR"`: theo dõi log, có giới hạn tần suất.
- `rungrinh watch-url <url>`: uptime check, chỉ báo khi trạng thái đổi.
- `rungrinh watch-json <url> --path .price --above N`: cảnh báo giá crypto/vàng, chạy bằng LaunchAgent.
