# Rung Rinh 🔔

App trên menu bar macOS kèm CLI, đẩy thông báo lên iPhone qua **Bark** hoặc **ntfy**. Thông báo trên iPhone sẽ hiện tiếp lên đồng hồ, nên đồng hồ của bạn thành cái *pager*: Claude Code chạy xong task, build xong hay CI fail là cổ tay rung.

## Cài đặt

```bash
curl -fsSL https://raw.githubusercontent.com/dinhthanh11011/rung-rinh/main/install.sh | bash
```

Lệnh này tải bản release mới nhất (universal, chạy được trên cả Apple Silicon lẫn Intel), cài vào `~/Applications/RungRinh.app` và link CLI vào `~/.local/bin/rungrinh`.

**Cập nhật:** app tự kiểm tra GitHub release lúc mở và mỗi 6 giờ. Có bản mới thì nó tự cài rồi mở lại (tắt được bằng ô "Tự động cài bản mới" trong popover), hoặc bạn bấm nút **Cập nhật**. Từ terminal thì dùng `rungrinh update`, hoặc chạy lại lệnh cài ở trên.

```bash
curl -fsSL https://raw.githubusercontent.com/dinhthanh11011/rung-rinh/main/install.sh | bash -s -- --hooks       # cài luôn hook Claude Code
curl -fsSL https://raw.githubusercontent.com/dinhthanh11011/rung-rinh/main/install.sh | bash -s -- --uninstall   # gỡ app, CLI và hook (vẫn giữ config)
```

Nếu muốn build từ source: `scripts/build-app.sh` (chỉ cần Command Line Tools: `xcode-select --install`).

1. Bấm icon 🔔 trên menu bar.
2. Tab **Thông báo**: chọn Bark và dán device key (key là phần nằm trong URL `https://api.day.app/<KEY>/...` hiện trong app Bark), hoặc chọn ntfy và nhập topic. Bấm **Gửi thử**.
3. Tab **Claude**: bấm **Cài hook** để gắn vào Claude Code. App ghi vào `~/.claude/settings.json` và backup bản cũ thành `settings.json.rungrinh-backup`.
4. Tab **Quy tắc** chỉnh chống spam, giờ yên tĩnh; **Lịch sử** xem các lần push (kể cả bị bỏ qua và lý do); **Ứng dụng** để cập nhật, mở cùng máy, thoát.

## Chống spam

| Luật | Mặc định |
|---|---|
| Chỉ báo khi task chạy ≥ N giây | 120s |
| Hai lần push cách nhau tối thiểu | 30s |
| Chỉ báo khi bạn rời máy (không chạm phím/chuột ≥ N giây) | tắt |
| Claude hỏi / xin quyền: chỉ báo khi chưa trả lời sau N giây, nhắc lại 1 lần | 5 phút, +10 phút |
| Giờ yên tĩnh | tắt |
| Tạm dừng 30 phút / 1 giờ / tới sáng | — |

Lần push nào bị bỏ qua cũng được ghi lý do vào phần "Gần đây" và vào `rungrinh history`.

## Claude Code

`rungrinh hook claude` được gọi ở các event:
- `UserPromptSubmit`: ghi lại thời điểm bắt đầu task.
- `Stop`: tính thời lượng rồi push `✅ <project> xong sau 4m12s` kèm trích đoạn câu trả lời cuối.
- `PreToolUse` (`AskUserQuestion`, `ExitPlanMode`) và `Notification` (xin quyền): Claude hỏi bạn. Hook **không push ngay** mà chạy một tiến trình nền. Nếu sau `askDelaySeconds` (5 phút) câu hỏi vẫn chưa được trả lời thì push `⏳ <project>: Claude chờ bạn 5m00s` kèm nội dung câu hỏi. Còn chưa trả lời thì nhắc lại **đúng 1 lần** sau `askReminderSeconds` (10 phút, đặt 0 để tắt).
- Mỗi câu hỏi được theo dõi riêng theo session và `tool_use_id` của tool call đang chờ. `PostToolUse` của đúng tool call đó (bạn trả lời hoặc duyệt quyền) sẽ huỷ push. Các tool chạy song song bắt đầu hay xong đều không ảnh hưởng. Khi bạn từ chối thì không có hook nào chạy, nên trước khi push, tiến trình nền đọc transcript xem tool call đã có `tool_result` chưa. `UserPromptSubmit`, `Stop`, `SessionEnd` xoá mọi câu hỏi đang chờ của session đó.
- `Notification` `idle_prompt`: Claude tự chờ khoảng 60s ở cuối lượt rồi mới báo, nên lúc này push `⏳ Claude cần bạn` luôn.

Bản cũ chỉ cài 3 hook đầu. App sẽ tự cài thêm các hook còn thiếu khi mở; nếu dùng CLI thì chạy lại `rungrinh install-hooks`.

Hook không cần app đang chạy và luôn exit 0, nên không bao giờ làm Claude Code bị chặn. Lỗi được ghi vào `~/.config/rungrinh/rungrinh.log`.

## CLI

```bash
rungrinh notify "Deploy xong" --title "🚀 prod" --priority high --url https://...
rungrinh run -- npm test             # chạy lệnh, xong thì push ✅/❌ (chỉ khi chạy lâu hơn ngưỡng)
rungrinh run -- gh run watch         # CI xong là đồng hồ rung
eval "$(rungrinh shell-init zsh)"    # trong ~/.zshrc: lệnh nào chạy > $RUNGRINH_MIN (30s) cũng tự push
rungrinh on | off | snooze 1h | snooze morning | snooze off
rungrinh status | history 20
rungrinh version | update            # xem phiên bản / cài bản release mới nhất
rungrinh config set bark.key XXXX    # cấu hình không cần mở app (dotfiles, máy CI)
rungrinh install-hooks | uninstall-hooks
```

Config lưu ở `~/.config/rungrinh/config.json` (quyền 600), dùng chung cho app và CLI.

## Dev

```bash
swift build
swift run selftest      # test (dạng executable, vì XCTest / swift-testing cần Xcode)
swift run RungRinhApp   # chạy app trực tiếp
RUNGRINH_DEBUG_WINDOW=1 swift run RungRinhApp   # mở popover trong cửa sổ thường (để chụp màn hình)
swift scripts/make-icon.swift         # vẽ lại Resources/AppIcon.icns
scripts/release.sh v0.2.0 "ghi chú"   # build universal + tạo GitHub release cho install.sh
```

## Ý tưởng tiếp theo
- `rungrinh wait-pid <pid>`: báo khi một process đang chạy sẵn kết thúc.
- `cmd | rungrinh pipe --match "ERROR"`: theo dõi log, có giới hạn tần suất.
- `rungrinh watch-url <url>`: uptime check, chỉ báo khi trạng thái đổi.
- `rungrinh watch-json <url> --path .price --above N`: cảnh báo giá crypto/vàng, chạy bằng LaunchAgent.
