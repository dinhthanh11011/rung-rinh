#!/usr/bin/env bash
# Builds RungRinh.app (menu bar app + bundled `rungrinh` CLI).
#   scripts/build-app.sh                 build + install to ~/Applications, link CLI into ~/.local/bin
#   scripts/build-app.sh --no-install    build only
#   scripts/build-app.sh --release       universal (arm64 + x86_64) build + build/RungRinh.zip, no install
# VERSION=1.2.3 sets CFBundleShortVersionString in the built bundle.
set -euo pipefail

cd "$(dirname "$0")/.."
INSTALL=1
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --release) RELEASE=1; INSTALL=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ARCH_FLAGS=()
[[ $RELEASE == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product rungrinh
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product RungRinhApp
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/RungRinh.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "${VERSION#v}" "$APP/Contents/Info.plist"
fi
# Not "RungRinh": APFS is case-insensitive and it would clobber the `rungrinh` CLI.
cp "$BIN/RungRinhApp" "$APP/Contents/MacOS/RungRinhBar"
cp "$BIN/rungrinh" "$APP/Contents/MacOS/rungrinh"
codesign --force --deep --sign - "$APP" >/dev/null
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/rungrinh"))"

if [[ $RELEASE == 1 ]]; then
  rm -f build/RungRinh.zip
  ditto -c -k --keepParent "$APP" build/RungRinh.zip
  echo "packed build/RungRinh.zip"
fi

if [[ $INSTALL == 1 ]]; then
  DEST="$HOME/Applications/RungRinh.app"
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  pkill -x RungRinhBar 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  ln -sf "$DEST/Contents/MacOS/rungrinh" "$HOME/.local/bin/rungrinh"
  echo "installed $DEST"
  echo "CLI: ~/.local/bin/rungrinh (make sure ~/.local/bin is on your PATH)"
  open "$DEST"
fi
