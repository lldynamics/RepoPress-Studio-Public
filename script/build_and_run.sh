#!/usr/bin/env bash
set -euo pipefail

MODE="run"
BUILD_CONFIGURATION="debug"
APP_STORE_BUILD=0
DIRECT_DISTRIBUTION_BUILD="${DIRECT_DISTRIBUTION_BUILD:-0}"
APP_NAME="PersonalSitePublisherMac"
BUNDLE_ID="com.jinfang.PersonalSitePublisherMac"
MIN_SYSTEM_VERSION="14.0"
APP_CATEGORY="${APP_CATEGORY:-public.app-category.developer-tools}"
HUMAN_READABLE_COPYRIGHT="${APP_COPYRIGHT:-Copyright © 2026 Jinfang. All rights reserved.}"
SCREENSHOT_SURFACE="writing"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_CONFIG="${BUILD_VERSION_CONFIG:-$ROOT_DIR/Packaging/BuildVersion.xcconfig}"
VERSION_VALUES="$(
  bash "$ROOT_DIR/script/check_build_version.sh" \
    --config "$VERSION_CONFIG" \
    --print-values
)"
IFS=$'\t' read -r MARKETING_VERSION BUILD_NUMBER <<<"$VERSION_VALUES"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
NATIVE_HOST_NAME="KnowledgeNativeMessagingHost"
NATIVE_HOST_BINARY="$APP_MACOS/$NATIVE_HOST_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Sources/PersonalSitePublisherMac/Resources/AppIcon.icns"
LOCALIZATION_SOURCE="$ROOT_DIR/Sources/PersonalSitePublisherMac/Resources"
LOCALIZATION_CATALOG="$LOCALIZATION_SOURCE/Localizable.xcstrings"
BROWSER_EXTENSION_SOURCE="$ROOT_DIR/BrowserExtension"
LOCAL_DEVELOPMENT_ENTITLEMENTS="$ROOT_DIR/Packaging/LocalDevelopment.entitlements"
APP_STORE_ENTITLEMENTS="$ROOT_DIR/Sources/PersonalSitePublisherMac/AppStore.entitlements"
DIRECT_DISTRIBUTION_ENTITLEMENTS="$ROOT_DIR/Packaging/DirectDistribution.entitlements"
CODESIGN_TOOL="${CODESIGN_TOOL:-/usr/bin/codesign}"
SECURITY_TOOL="${SECURITY_TOOL:-/usr/bin/security}"

RUNTIME_HOME="${PERSONAL_SITE_PUBLISHER_RUNTIME_HOME:-${HOME:?HOME is required to launch the app}}"
SWIFT_BUILD_HOME="${SWIFT_BUILD_HOME:-/private/tmp/personal-site-publisher-swift-home}"
SWIFT_BUILD_XDG_CACHE_HOME="${SWIFT_BUILD_XDG_CACHE_HOME:-$SWIFT_BUILD_HOME/.cache}"
SWIFT_BUILD_CLANG_MODULE_CACHE_PATH="${SWIFT_BUILD_CLANG_MODULE_CACHE_PATH:-$SWIFT_BUILD_HOME/.swift-clang-cache}"
SWIFT_BUILD_MODULE_CACHE_PATH="${SWIFT_BUILD_MODULE_CACHE_PATH:-$SWIFT_BUILD_HOME/.swift-module-cache}"

mkdir -p \
  "$SWIFT_BUILD_HOME" \
  "$SWIFT_BUILD_XDG_CACHE_HOME" \
  "$SWIFT_BUILD_CLANG_MODULE_CACHE_PATH" \
  "$SWIFT_BUILD_MODULE_CACHE_PATH" \
  "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/configuration" \
  "$SWIFT_BUILD_HOME/Library/org.swift.swiftpm/security" \
  "$SWIFT_BUILD_HOME/Library/Caches/org.swift.swiftpm"

swift_build() {
  env \
    HOME="$SWIFT_BUILD_HOME" \
    XDG_CACHE_HOME="$SWIFT_BUILD_XDG_CACHE_HOME" \
    CLANG_MODULE_CACHE_PATH="$SWIFT_BUILD_CLANG_MODULE_CACHE_PATH" \
    SWIFT_MODULE_CACHE_PATH="$SWIFT_BUILD_MODULE_CACHE_PATH" \
    swift "$@"
}

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
  knowledge-library
)

usage() {
  cat >&2 <<'EOF'
usage: script/build_and_run.sh [mode] [options]

Modes:
  run                       Build and open the app bundle.
  --debug | debug           Build, then start lldb with the app binary.
  --logs | logs             Build, open, then stream process logs.
  --telemetry | telemetry   Build, open, then stream app telemetry logs.
  --verify | verify         Build, open, and verify the window when System Events is available.
  --verify-process          Build, open, and verify only that the process starts.
  --launch-baseline        Build, then measure bundle-open to visible-window time.
  --package-only | package  Build the .app bundle and print its path.
  --screenshot-demo [id]    Build and launch screenshot demo data for a surface.

Options:
  --release                 Build with SwiftPM's Release configuration. Direct packages require a verified Mozilla-signed Firefox XPI.
  --app-store               Build the Mac App Store Release variant without browser-extension assets.
  --configuration <name>   Select debug or release (default: debug).
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
    --release)
      BUILD_CONFIGURATION="release"
      shift
      ;;
    --app-store)
      APP_STORE_BUILD=1
      BUILD_CONFIGURATION="release"
      shift
      ;;
    --configuration)
      [[ "$#" -ge 2 ]] || { usage; exit 2; }
      BUILD_CONFIGURATION="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--verify-process|verify-process|--launch-baseline|launch-baseline|--package-only|package)
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

case "$BUILD_CONFIGURATION" in
  debug)
    BUILD_CONFIGURATION_DISPLAY_NAME="Debug"
    ;;
  release)
    BUILD_CONFIGURATION_DISPLAY_NAME="Release"
    ;;
  *)
    echo "unsupported build configuration: $BUILD_CONFIGURATION (expected debug or release)" >&2
    exit 2
    ;;
esac

if [[ "$APP_STORE_BUILD" == "1" && "$BUILD_CONFIGURATION" != "release" ]]; then
  echo "App Store builds require the Release configuration" >&2
  exit 2
fi
if [[ "$DIRECT_DISTRIBUTION_BUILD" != "0" && "$DIRECT_DISTRIBUTION_BUILD" != "1" ]]; then
  echo "DIRECT_DISTRIBUTION_BUILD must be 0 or 1" >&2
  exit 2
fi
if [[ "$DIRECT_DISTRIBUTION_BUILD" == "1" ]]; then
  if [[ "$APP_STORE_BUILD" == "1" || "$BUILD_CONFIGURATION" != "release" ]]; then
    echo "Developer ID distribution mode requires a non-App-Store Release build" >&2
    exit 2
  fi
  if [[ -z "${CODE_SIGN_IDENTITY:-}" || "${CODE_SIGN_IDENTITY:-}" == "-" \
    || "${CODE_SIGN_IDENTITY:-}" == *$'\n'* || "${CODE_SIGN_IDENTITY:-}" == *$'\r'* ]]; then
    echo "Developer ID distribution mode requires an explicit CODE_SIGN_IDENTITY" >&2
    exit 2
  fi
  direct_distribution_identity_count="$(
    "$SECURITY_TOOL" find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/awk -v identity="$CODE_SIGN_IDENTITY" '
          index($0, identity) > 0 && index($0, "\"Developer ID Application:") > 0 { count += 1 }
          END { print count + 0 }
        ' \
      || true
  )"
  if [[ "$direct_distribution_identity_count" != "1" ]]; then
    echo "Developer ID distribution mode requires one unique valid Developer ID Application identity" >&2
    exit 2
  fi
fi

if [[ "$APP_STORE_BUILD" == "1" ]]; then
  DISTRIBUTION_CHANNEL="AppStore"
  BROWSER_EXTENSION_AVAILABLE_PLIST="  <false/>"
else
  DISTRIBUTION_CHANNEL="Direct"
  BROWSER_EXTENSION_AVAILABLE_PLIST="  <true/>"
fi
FIREFOX_SIGNED_PACKAGE_AVAILABLE_PLIST="  <false/>"
HARDENED_RUNTIME_ENABLED_PLIST="  <false/>"
firefox_extension_version=""
signed_firefox_xpi=""
signed_firefox_xpi_verified=0

if [[ "$MODE" == "screenshot-demo" ]] && ! contains_screenshot_surface "$SCREENSHOT_SURFACE"; then
  echo "unknown screenshot surface: $SCREENSHOT_SURFACE" >&2
  echo "known screenshot surfaces:" >&2
  list_screenshot_surfaces >&2
  exit 2
fi

app_process_pids() {
  # On macOS, pgrep -x can compare against a truncated process name for this
  # 24-character executable. Match the absolute executable command instead so
  # restart and verification do not miss a still-running older build.
  pgrep -f "^${APP_BINARY}([[:space:]]|$)" 2>/dev/null || true
}

app_process_is_running() {
  [[ -n "$(app_process_pids)" ]]
}

stop_running_app_processes() {
  local pid=""
  while IFS= read -r pid; do
    [[ -z "$pid" ]] || kill "$pid" >/dev/null 2>&1 || true
  done < <(app_process_pids)
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--verify-process|verify-process|--launch-baseline|launch-baseline|screenshot-demo)
    stop_running_app_processes
    ;;
esac

swift_build_options=(
  -c "$BUILD_CONFIGURATION"
  --disable-sandbox
)
if [[ "$APP_STORE_BUILD" == "1" ]]; then
  swift_build_options+=(
    -Xswiftc -D
    -Xswiftc APP_STORE_BUILD
  )
fi
if [[ "$DIRECT_DISTRIBUTION_BUILD" == "1" ]]; then
  HARDENED_RUNTIME_ENABLED_PLIST="  <true/>"
fi
python3 "$ROOT_DIR/script/generate_browser_extension_protocol.py" --check
if [[ "$APP_STORE_BUILD" != "1" && "${PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD:-0}" != "1" ]]; then
  [[ -f "$BROWSER_EXTENSION_SOURCE/manifest.json" ]] || {
    echo "browser extension manifest is missing: $BROWSER_EXTENSION_SOURCE/manifest.json" >&2
    exit 1
  }
  "$ROOT_DIR/script/sync_firefox_browser_extension.sh" --check
  firefox_extension_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("version", ""))' "$BROWSER_EXTENSION_SOURCE/Firefox/manifest.json")"
  [[ -n "$firefox_extension_version" ]] || {
    echo "Firefox extension manifest version is missing" >&2
    exit 1
  }
  signed_firefox_xpi="$DIST_DIR/browser-extension/knowledge-capture-firefox-$firefox_extension_version.xpi"
  if [[ -f "$signed_firefox_xpi" ]]; then
    "$ROOT_DIR/script/firefox_extension_release.py" verify-signed --signed-xpi "$signed_firefox_xpi"
    signed_firefox_xpi_verified=1
  elif [[ "$BUILD_CONFIGURATION" == "release" ]]; then
    echo "Direct Release packaging requires a verified Mozilla-signed Firefox XPI: $signed_firefox_xpi" >&2
    echo "Run script/sign_firefox_extension.sh before building the Direct Release package." >&2
    exit 1
  else
    echo "Debug Direct package: signed Firefox XPI is absent; Firefox long-term installation is not bundled." >&2
  fi
elif [[ "${PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD:-0}" == "1" ]]; then
  echo "Screenshot capture build: skipping browser-extension release synchronization." >&2
fi
swift_build build "${swift_build_options[@]}" --disable-index-store --product "$APP_NAME"
if [[ "$APP_STORE_BUILD" != "1" ]]; then
  swift_build build "${swift_build_options[@]}" --disable-index-store --product "$NATIVE_HOST_NAME"
fi
BUILD_BIN_DIR="$(swift_build build "${swift_build_options[@]}" --show-bin-path)"
case "$BUILD_BIN_DIR" in
  */"$BUILD_CONFIGURATION") ;;
  *)
    echo "SwiftPM returned a non-$BUILD_CONFIGURATION binary directory: $BUILD_BIN_DIR" >&2
    exit 1
    ;;
esac
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
[[ -x "$BUILD_BINARY" ]] || {
  echo "$BUILD_CONFIGURATION app executable is missing or not executable: $BUILD_BINARY" >&2
  exit 1
}
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ "$APP_STORE_BUILD" != "1" ]]; then
  BUILD_NATIVE_HOST="$BUILD_BIN_DIR/$NATIVE_HOST_NAME"
  [[ -x "$BUILD_NATIVE_HOST" ]] || {
    echo "$BUILD_CONFIGURATION native messaging host is missing or not executable: $BUILD_NATIVE_HOST" >&2
    exit 1
  }
  cp "$BUILD_NATIVE_HOST" "$NATIVE_HOST_BINARY"
  chmod +x "$NATIVE_HOST_BINARY"
fi
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
cp -R "$LOCALIZATION_SOURCE"/*.lproj "$APP_RESOURCES"/
if [[ "$APP_STORE_BUILD" != "1" ]]; then
  cp -R "$BROWSER_EXTENSION_SOURCE" "$APP_RESOURCES/BrowserExtension"
  firefox_release_resources="$APP_RESOURCES/BrowserExtension/Release"
  rm -rf "$firefox_release_resources"
  if [[ "$signed_firefox_xpi_verified" == "1" ]]; then
    firefox_release_resources="$APP_RESOURCES/BrowserExtension/Release"
    mkdir -p "$firefox_release_resources"
    cp "$signed_firefox_xpi" "$firefox_release_resources/"
    "$ROOT_DIR/script/firefox_extension_release.py" updates \
      --signed-xpi "$signed_firefox_xpi" \
      --output "$firefox_release_resources/updates.json"
    "$ROOT_DIR/script/firefox_extension_release.py" verify-updates \
      --signed-xpi "$firefox_release_resources/$(basename "$signed_firefox_xpi")" \
      --updates "$firefox_release_resources/updates.json"
    FIREFOX_SIGNED_PACKAGE_AVAILABLE_PLIST="  <true/>"
  fi
fi
xcrun xcstringstool compile "$LOCALIZATION_CATALOG" --output-directory "$APP_RESOURCES"

# Keep the Core target's localization bundle inside Contents/Resources so the
# assembled app follows the standard macOS bundle layout and can be sealed by
# codesign. CoreL10n resolves this packaged location before SwiftPM's build path.
core_resource_bundle="$BUILD_BIN_DIR/${APP_NAME}_PublishingWorkbenchCore.bundle"
[[ -d "$core_resource_bundle" ]] || {
  echo "SwiftPM Core resource bundle is missing: $core_resource_bundle" >&2
  exit 1
}
cp -R "$core_resource_bundle" "$APP_RESOURCES/"
core_resource_info="$APP_RESOURCES/${APP_NAME}_PublishingWorkbenchCore.bundle/Info.plist"
python3 - "$core_resource_info" "$BUNDLE_ID.PublishingWorkbenchCoreResources" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib
from pathlib import Path
import sys

info_path = Path(sys.argv[1])
bundle_identifier = sys.argv[2]
marketing_version = sys.argv[3]
build_number = sys.argv[4]
if info_path.exists():
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
else:
    info = {}
info.update({
    "CFBundleDevelopmentRegion": info.get("CFBundleDevelopmentRegion", "zh-Hans"),
    "CFBundleIdentifier": bundle_identifier,
    "CFBundleName": "PublishingWorkbenchCoreResources",
    "CFBundlePackageType": "BNDL",
    "CFBundleShortVersionString": marketing_version,
    "CFBundleVersion": build_number,
})
with info_path.open("wb") as handle:
    plistlib.dump(info, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PY

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
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>PersonalSitePublisherBuildConfiguration</key>
  <string>$BUILD_CONFIGURATION_DISPLAY_NAME</string>
  <key>PersonalSitePublisherDistributionChannel</key>
  <string>$DISTRIBUTION_CHANNEL</string>
  <key>PersonalSitePublisherBrowserExtensionAvailable</key>
$BROWSER_EXTENSION_AVAILABLE_PLIST
  <key>PersonalSitePublisherFirefoxSignedPackageAvailable</key>
$FIREFOX_SIGNED_PACKAGE_AVAILABLE_PLIST
  <key>PersonalSitePublisherHardenedRuntimeEnabled</key>
$HARDENED_RUNTIME_ENABLED_PLIST
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>$APP_CATEGORY</string>
  <key>NSHumanReadableCopyright</key>
  <string>$HUMAN_READABLE_COPYRIGHT</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>com.jinfang.personalsitepublisher.knowledge-library-backup</string>
      <key>UTTypeDescription</key>
      <string>Personal Site Knowledge Library Backup</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>com.apple.package</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>pslibrarybackup</string>
        </array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Personal Site Knowledge Library Backup</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.jinfang.personalsitepublisher.knowledge-library-backup</string>
      </array>
      <key>LSTypeIsPackage</key>
      <true/>
    </dict>
  </array>
</dict>
</plist>
PLIST

resolved_code_sign_identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$resolved_code_sign_identity" && "$BUILD_CONFIGURATION" == "debug" ]]; then
  # Ad-hoc signing derives its designated requirement from the binary cdhash,
  # so every rebuild loses access to generic-password items saved by the
  # previous build. Prefer an installed Apple Development identity to keep the
  # requirement stable across local rebuilds. Release packaging is still
  # re-signed by package_app_store.sh with the explicitly selected identity.
  resolved_code_sign_identity="$(
    "$SECURITY_TOOL" find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/awk '/"Apple Development:/{print $2; exit}' \
      || true
  )"
fi
resolved_code_sign_identity="${resolved_code_sign_identity:--}"
code_sign_arguments=(
  --force
  --sign "$resolved_code_sign_identity"
  --identifier "$BUNDLE_ID"
)
if [[ "$BUILD_CONFIGURATION" == "debug" ]]; then
  [[ -f "$LOCAL_DEVELOPMENT_ENTITLEMENTS" ]] || {
    echo "local development entitlements are missing: $LOCAL_DEVELOPMENT_ENTITLEMENTS" >&2
    exit 1
  }
  code_sign_arguments+=(--entitlements "$LOCAL_DEVELOPMENT_ENTITLEMENTS")
elif [[ "$APP_STORE_BUILD" == "1" ]]; then
  [[ -f "$APP_STORE_ENTITLEMENTS" ]] || {
    echo "App Store entitlements are missing: $APP_STORE_ENTITLEMENTS" >&2
    exit 1
  }
  code_sign_arguments+=(--entitlements "$APP_STORE_ENTITLEMENTS")
elif [[ "$DIRECT_DISTRIBUTION_BUILD" == "1" ]]; then
  [[ -f "$DIRECT_DISTRIBUTION_ENTITLEMENTS" ]] || {
    echo "Direct distribution entitlements are missing: $DIRECT_DISTRIBUTION_ENTITLEMENTS" >&2
    exit 1
  }
  code_sign_arguments+=(
    --options runtime
    --timestamp
    --entitlements "$DIRECT_DISTRIBUTION_ENTITLEMENTS"
  )
fi
if [[ "$APP_STORE_BUILD" != "1" ]]; then
  native_code_sign_arguments=(
    --force \
    --sign "$resolved_code_sign_identity" \
    --identifier "$BUNDLE_ID.KnowledgeNativeMessagingHost"
  )
  if [[ "$DIRECT_DISTRIBUTION_BUILD" == "1" ]]; then
    native_code_sign_arguments+=(
      --options runtime
      --timestamp
      --entitlements "$DIRECT_DISTRIBUTION_ENTITLEMENTS"
    )
  fi
  "$CODESIGN_TOOL" "${native_code_sign_arguments[@]}" "$NATIVE_HOST_BINARY"
fi
"$CODESIGN_TOOL" "${code_sign_arguments[@]}" "$APP_BUNDLE"
"$CODESIGN_TOOL" --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if [[ "$resolved_code_sign_identity" == "-" ]]; then
  echo "local app signing identity: ad hoc"
else
  echo "local app signing identity: $resolved_code_sign_identity"
fi

wait_for_main_window() {
  local attempts="${1:-20}"
  local count=""
  local app_pid=""
  local query_output=""
  while [[ "$attempts" -gt 0 ]]; do
    app_pid="$(app_process_pids | head -n 1)"
    if [[ -z "$app_pid" ]]; then
      sleep 0.5
      attempts="$((attempts - 1))"
      continue
    fi
    if ! query_output="$(osascript - "$app_pid" <<'OSA' 2>&1
on run argv
  set targetPID to (item 1 of argv) as integer
tell application "System Events"
  set matchingProcesses to every process whose unix id is targetPID
  if (count of matchingProcesses) is 0 then return "0"
  tell item 1 of matchingProcesses to return count of windows
end tell
end run
OSA
)"; then
      echo "System Events window query unavailable: ${query_output%%$'\n'*}" >&2
      return 2
    fi
    count="$query_output"
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

verify_main_window_or_process() {
  local status=0
  # Correctness verification allows slower development workspaces to restore
  # state without weakening the separate five-second launch baseline gate.
  if wait_for_main_window 60; then
    return 0
  else
    status="$?"
  fi
  if [[ "$status" == "2" ]]; then
    echo "window visibility query unavailable; running process verification passed" >&2
    return 0
  fi
  return "$status"
}

can_query_main_window() {
  local enabled=""
  enabled="$(osascript -e 'tell application "System Events" to return UI elements enabled' 2>/dev/null || true)"
  [[ "$enabled" == "true" ]]
}

is_console_session_locked() {
  ioreg -n Root -d1 2>/dev/null | grep -F '"CGSSessionScreenIsLocked"=Yes' >/dev/null
}

wait_for_running_process() {
  local attempts=50
  while [[ "$attempts" -gt 0 ]]; do
    if app_process_is_running; then
      return 0
    fi
    sleep 0.1
    attempts="$((attempts - 1))"
  done
  return 1
}

run_bundle() {
  /usr/bin/xattr -cr "$APP_BUNDLE"
  if env HOME="$RUNTIME_HOME" /usr/bin/open -n "$APP_BUNDLE" >/tmp/personal-site-publisher-open.log 2>&1; then
    return 0
  fi

  echo "open dist app failed; refusing to launch the SwiftUI GUI as a raw executable." >&2
  cat /tmp/personal-site-publisher-open.log >&2
  return 1
}

case "$MODE" in
  run)
    run_bundle
    ;;
  --debug|debug)
    env HOME="$RUNTIME_HOME" lldb -- "$APP_BINARY"
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
    if app_process_is_running; then
      verify_main_window_or_process || {
        echo "启动校验失败：进程存活，但在可查询窗口的环境中未检测到可见主窗口。" >&2
        exit 1
      }
      exit 0
    fi

    echo "启动校验失败：未检测到运行中的进程（请确认运行环境）" >&2
    exit 1
    ;;
  --verify-process|verify-process)
    run_bundle
    wait_for_running_process || {
      echo "进程启动校验失败：未检测到运行中的进程" >&2
      exit 1
    }
    echo "process launch verification: running process detected; window visibility was not checked"
    ;;
  --launch-baseline|launch-baseline)
    max_launch_seconds="${LAUNCH_BASELINE_MAX_SECONDS:-5.0}"
    launch_started_at="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
    run_bundle
    wait_for_running_process || {
      echo "launch performance gate: process did not become ready" >&2
      exit 1
    }
    launch_readiness="visible window"
    if is_console_session_locked; then
      echo "launch performance gate: console session is locked; visible-window evidence is unavailable" >&2
      exit 1
    elif can_query_main_window; then
      wait_for_main_window || {
        echo "launch performance gate: visible window was not detected" >&2
        exit 1
      }
      launch_readiness="visible window"
    else
      echo "launch performance gate: System Events window query unavailable; visible-window evidence is required" >&2
      exit 1
    fi
    launch_finished_at="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
    launch_elapsed="$(awk -v start="$launch_started_at" -v finish="$launch_finished_at" 'BEGIN { printf "%.3f", finish - start }')"
    if ! awk -v elapsed="$launch_elapsed" -v maximum="$max_launch_seconds" 'BEGIN { exit !(elapsed <= maximum) }'; then
      echo "launch performance gate: ${launch_elapsed}s exceeded ${max_launch_seconds}s baseline" >&2
      exit 1
    fi
    echo "launch performance gate: ${launch_readiness} in ${launch_elapsed}s (baseline <= ${max_launch_seconds}s)"
    ;;
  --package-only|package)
    echo "$APP_BUNDLE"
    ;;
  --screenshot-demo|screenshot-demo)
    HOME="$RUNTIME_HOME" \
      PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO=1 \
      PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE="$SCREENSHOT_SURFACE" \
      "$APP_BINARY" >/tmp/personal-site-publisher-screenshot-demo.log 2>&1 &
    ;;
  *)
    usage
    exit 2
    ;;
esac
