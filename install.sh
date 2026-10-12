#!/bin/bash
# Rung Rinh: one-line installer. Installs the latest release (or builds from source if there is none).
#
#   curl -fsSL https://raw.githubusercontent.com/dinhthanh11011/rung-rinh/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/dinhthanh11011/rung-rinh/main/install.sh | bash -s -- --hooks       # also install the Claude Code hooks
#   curl -fsSL https://raw.githubusercontent.com/dinhthanh11011/rung-rinh/main/install.sh | bash -s -- --uninstall
#
# Run it again any time to update. Env: RUNGRINH_VERSION=v0.1.0 pins a release.
set -euo pipefail

REPO="dinhthanh11011/rung-rinh"
APP="RungRinh.app"
DEST="${HOME}/Applications"
BIN_DIR="${HOME}/.local/bin"
HOOKS=0
UNINSTALL=0
for arg in "$@"; do
  case "${arg}" in
    --hooks) HOOKS=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "unknown option: ${arg}" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "❌ Rung Rinh chỉ chạy trên macOS"; exit 1; }

if [ "${UNINSTALL}" = 1 ]; then
  [ -x "${DEST}/${APP}/Contents/MacOS/rungrinh" ] && "${DEST}/${APP}/Contents/MacOS/rungrinh" uninstall-hooks || true
  pkill -x RungRinhBar 2>/dev/null || true
  rm -rf "${DEST:?}/${APP}"
  rm -f "${BIN_DIR}/rungrinh"
  echo "✅ Đã gỡ Rung Rinh (config vẫn giữ ở ~/.config/rungrinh)"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

if [ -n "${RUNGRINH_VERSION:-}" ]; then
  API="https://api.github.com/repos/${REPO}/releases/tags/${RUNGRINH_VERSION}"
else
  API="https://api.github.com/repos/${REPO}/releases/latest"
fi

echo "==> Đang tìm bản mới nhất…"
JSON=$(/usr/bin/curl -fsSL -H "Accept: application/vnd.github+json" "${API}" 2>/dev/null || true)
TAG=$(printf '%s' "${JSON}" | /usr/bin/sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
ZIPURL=$(printf '%s' "${JSON}" \
  | /usr/bin/grep -o '"browser_download_url": *"[^"]*RungRinh\.zip"' | head -1 \
  | /usr/bin/sed 's/.*"\(https[^"]*\)"/\1/' || true)

if [ -n "${ZIPURL}" ]; then
  echo "==> Tải ${TAG}…"
  /usr/bin/curl -fsSL -o "${TMP}/app.zip" "${ZIPURL}"
  /usr/bin/ditto -x -k "${TMP}/app.zip" "${TMP}/x"
  SRC=$(/usr/bin/find "${TMP}/x" -maxdepth 3 -name "${APP}" | head -1)
else
  echo "==> Chưa có release, build từ source (cần Command Line Tools)…"
  if ! xcrun --find swift >/dev/null 2>&1; then
    echo "❌ Không tìm thấy Swift. Chạy: xcode-select --install, rồi chạy lại lệnh cài."
    exit 1
  fi
  /usr/bin/curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/refs/heads/main" | tar -xz -C "${TMP}"
  SRCDIR=$(/usr/bin/find "${TMP}" -maxdepth 1 -type d -name 'rung-rinh-*' | head -1)
  (cd "${SRCDIR}" && scripts/build-app.sh --no-install)
  SRC="${SRCDIR}/build/${APP}"
fi
[ -n "${SRC:-}" ] && [ -d "${SRC}" ] || { echo "❌ Không tìm thấy ${APP}"; exit 1; }

echo "==> Cài vào ${DEST}/${APP}"
mkdir -p "${DEST}" "${BIN_DIR}"
pkill -x RungRinhBar 2>/dev/null || true
# Wait for the old app to exit, otherwise `open` below can fail with -600.
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x RungRinhBar >/dev/null || break; sleep 0.3; done
rm -rf "${DEST:?}/${APP}"
/usr/bin/ditto "${SRC}" "${DEST}/${APP}"
/usr/bin/xattr -dr com.apple.quarantine "${DEST}/${APP}" 2>/dev/null || true
ln -sf "${DEST}/${APP}/Contents/MacOS/rungrinh" "${BIN_DIR}/rungrinh"

if [ "${HOOKS}" = 1 ]; then
  "${DEST}/${APP}/Contents/MacOS/rungrinh" install-hooks
fi

open "${DEST}/${APP}"

echo ""
echo "✅ Xong! Bấm icon 🔔 trên menu bar → nhập Bark key hoặc ntfy topic → Gửi thử → Cài hook."
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "ℹ️  Thêm CLI vào PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
