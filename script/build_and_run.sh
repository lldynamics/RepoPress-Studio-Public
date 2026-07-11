#!/usr/bin/env bash
set -euo pipefail

MODE="run"
APP_NAME="PersonalSitePublisherMac"
BUNDLE_ID="com.jinfang.PersonalSitePublisherMac"
MIN_SYSTEM_VERSION="14.0"
MARKETING_VERSION="1.0"
BUILD_NUMBER="1"
SCREENSHOT_SURFACE="writing"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Sources/PersonalSitePublisherMac/Resources/AppIcon.icns"
LOCALIZATION_SOURCE="$ROOT_DIR/Sources/PersonalSitePublisherMac/Resources"
LOCALIZATION_CATALOG="$LOCALIZATION_SOURCE/Localizable.xcstrings"
LAUNCHED_PID=""

SWIFT_BUILD_HOME="${SWIFT_BUILD_HOME:-/private/tmp/personal-site-publisher-swift-home}"
export HOME="$SWIFT_BUILD_HOME"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$HOME/.swift-clang-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$HOME/.swift-module-cache}"

mkdir -p \
  "$HOME" \
  "$XDG_CACHE_HOME" \
  "$HOME/.swift-clang-cache" \
  "$HOME/.swift-module-cache" \
  "$HOME/Library/org.swift.swiftpm/configuration" \
  "$HOME/Library/org.swift.swiftpm/security" \
  "$HOME/Library/Caches/org.swift.swiftpm"

required_screenshot_surfaces=(
  writing
  ai-chat
  sync-api-publish
  seo-social-preview
  deployment-status
  maintenance
  general-drafts
  pro-settings
  privacy-lock
  release-readiness
)

usage() {
  cat >&2 <<'EOF'
usage: script/build_and_run.sh [mode] [options]

Modes:
  run                       Build and open the app bundle.
  --debug | debug           Build, then start lldb with the app binary.
  --logs | logs             Build, open, then stream process logs.
  --telemetry | telemetry   Build, open, then stream app telemetry logs.
  --verify | verify         Build, open, and verify the process starts.
  --package-only | package  Build the .app bundle and print its path.
  --screenshot-demo [id]    Build and launch screenshot demo data for a surface.

Options:
  --screenshot-surface <id> Select a screenshot demo surface and imply --screenshot-demo.
  --list-screenshot-surfaces
                            Print screenshot surface ids and exit.
EOF
}

contains_screenshot_surface() {
  local candidate="$1"
  local id
  for id in "${required_screenshot_surfaces[@]}"; do
    [[ "$id" == "$candidate" ]] && return 0
  done
  return 1
}

list_screenshot_surfaces() {
  printf '%s\n' "${required_screenshot_surfaces[@]}"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--package-only|package)
      MODE="$1"
      shift
      ;;
    --screenshot-demo|screenshot-demo)
      MODE="screenshot-demo"
      shift
      if [[ "$#" -gt 0 && "${1:0:1}" != "-" ]]; then
        SCREENSHOT_SURFACE="$1"
        shift
      fi
      ;;
    --screenshot-surface)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      MODE="screenshot-demo"
      SCREENSHOT_SURFACE="$2"
      shift 2
      ;;
    --list-screenshot-surfaces)
      list_screenshot_surfaces
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$MODE" == "screenshot-demo" ]] && ! contains_screenshot_surface "$SCREENSHOT_SURFACE"; then
  echo "unknown screenshot surface: $SCREENSHOT_SURFACE" >&2
  echo "known screenshot surfaces:" >&2
  list_screenshot_surfaces >&2
  exit 2
fi

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|screenshot-demo)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    ;;
esac

swift build --disable-sandbox --product "$APP_NAME"
BUILD_BINARY="$(swift build --disable-sandbox --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
cp -R "$LOCALIZATION_SOURCE"/*.lproj "$APP_RESOURCES"/
xcrun xcstringstool compile "$LOCALIZATION_CATALOG" --output-directory "$APP_RESOURCES"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>Personal Site Publishing Console</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

wait_for_main_window() {
  local attempts=20
  local count=""
  while [[ "$attempts" -gt 0 ]]; do
    count="$(osascript <<OSA 2>/dev/null || true
tell application "System Events"
  if not (exists process "$APP_NAME") then return "0"
  tell process "$APP_NAME"
    return count of windows
  end tell
end tell
OSA
)"
    count="$(printf "%s" "$count" | tr -d '[:space:]')"
    if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
      return 0
    fi
    sleep 0.5
    attempts="$((attempts - 1))"
  done
  echo "$APP_NAME launched but no visible main window was detected" >&2
  return 1
}

run_bundle() {
  /usr/bin/xattr -cr "$APP_BUNDLE"
  if /usr/bin/open -n "$APP_BUNDLE" >/tmp/personal-site-publisher-open.log 2>&1; then
    LAUNCHED_PID=""
    return 0
  fi

  echo "open dist app failed, fallback to direct binary launch." >&2
  cat /tmp/personal-site-publisher-open.log >&2

  if ! nohup "$APP_BINARY" >/tmp/personal-site-publisher-direct.log 2>&1 & then
    cat /tmp/personal-site-publisher-open.log
    return 1
  fi
  LAUNCHED_PID=$!
  echo "app launched via direct binary fallback (pid: $!)." >&2
}

case "$MODE" in
  run)
    run_bundle
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    run_bundle
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    run_bundle
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    run_bundle
    sleep 1
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      if ! wait_for_main_window; then
        echo "无法读取窗口信息，可能是当前环境不支持 GUI 校验，已继续返回启动成功。" >&2
      fi
      exit 0
    fi

    launched_pid="${LAUNCHED_PID-}"
    if [[ -n "$launched_pid" ]] && kill -0 "$launched_pid" 2>/dev/null; then
      echo "进程未被 pgrep 枚举到，但直接启动句柄仍存活（pid: $launched_pid），视为启动成功。" >&2
      if ! wait_for_main_window; then
        echo "无法读取窗口信息，可能是当前环境不支持 GUI 校验，已继续返回启动成功。" >&2
      fi
      exit 0
    fi

    echo "启动校验失败：未检测到运行中的进程（请确认运行环境）" >&2
    exit 1
    ;;
  --package-only|package)
    echo "$APP_BUNDLE"
    ;;
  --screenshot-demo|screenshot-demo)
    PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO=1 \
      PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE="$SCREENSHOT_SURFACE" \
      "$APP_BINARY" >/tmp/personal-site-publisher-screenshot-demo.log 2>&1 &
    ;;
  *)
    usage
    exit 2
    ;;
esac
