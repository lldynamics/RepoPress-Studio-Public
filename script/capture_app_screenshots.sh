#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/docs/app-store-screenshots}"
MANIFEST_FILE="${SCREENSHOT_MANIFEST_FILE:-$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md}"
APP_PRODUCT="PersonalSitePublisherMac"
APP_BUNDLE_ID="com.jinfang.PersonalSitePublisherMac"
SCREENSHOT_BUILD_DIST_DIR="${SCREENSHOT_BUILD_DIST_DIR:-$ROOT_DIR/dist/app-store-screenshot}"
APP_BUNDLE="$SCREENSHOT_BUILD_DIST_DIR/$APP_PRODUCT.app"
SKIP_BUILD=0
DEMO_DATA=1
FORCE_RELAUNCH=0
AUTO_WINDOW=0
CAPTURE_DELAY=4
ONLY_ID=""
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_PRODUCT"
CAPTURE_PROVENANCE_SCRIPT="$ROOT_DIR/script/screenshot_capture_provenance.py"
NORMALIZE_SCREENSHOT_SCRIPT="$ROOT_DIR/script/normalize_app_store_screenshot.sh"
COMPOSE_MARKETING_SCREENSHOT_SCRIPT="$ROOT_DIR/script/compose_app_store_marketing_screenshot.sh"
WINDOW_ID_HELPER="$ROOT_DIR/script/app_store_window_id.swift"
MARKETING=0
MARKETING_SCREENSHOT_DIR="${SCREENSHOT_MARKETING_DIR:-$SCREENSHOT_DIR/marketing}"
RAW_SCREENSHOT_DIR="${SCREENSHOT_RAW_DIR:-$SCREENSHOT_DIR/sources}"
marketing_only_ids=()

required_ids=()

usage() {
  cat <<'USAGE'
Usage: script/capture_app_screenshots.sh [--skip-build] [--only <id>] [--force-relaunch] [--auto-window] [--marketing] [--list]

Captures the App Store screenshot set listed in
docs/app-store-screenshots/SCREENSHOT_MANIFEST.md. By default it uses the
macOS interactive capture picker; --auto-window captures the frontmost app
window for each isolated demo surface. Standard captures are losslessly fitted
onto a 2880x1800 canvas. --marketing preserves the native Retina source and
renders a separate 2880x1800 promotional layout without replacing the existing set.

Options:
  --skip-build   Do not build or launch the app before capture.
  --real-data    Launch without the isolated screenshot demo workbench.
  --only <id>    Capture just one required screenshot id and open that demo surface.
  --force-relaunch
                 Quit an already-running app before opening the requested demo surface.
  --auto-window  Automatically capture the frontmost app window with screencapture -l.
                 Requires Screen Recording and Accessibility permissions.
  --marketing    Preserve the native Retina source under sources/ and render the
                 promotional asset under marketing/ without replacing current screenshots.
  --capture-delay <seconds>
                 Seconds to wait after launching a demo surface before auto capture.
  --list         Print required screenshot ids and exit.
USAGE
}

fail() {
  echo "screenshot capture: $*" >&2
  exit 1
}

load_required_ids() {
  local id
  [[ -f "$MANIFEST_FILE" ]] || fail "SCREENSHOT_MANIFEST.md is missing"
  while IFS= read -r id; do
    [[ -n "$id" ]] && required_ids+=("$id")
  done < <(sed -nE 's/^\| `([^`]+)` \|.*/\1/p' "$MANIFEST_FILE")
  [[ "${#required_ids[@]}" -gt 0 ]] || fail "screenshot manifest contains no required screenshot IDs"
}

screen_title() {
  case "$1" in
    writing) echo "Writing workspace" ;;
    ai-chat) echo "BYOK AI writing assistant" ;;
    sync-api-publish) echo "Sync/API publishing workspace" ;;
    seo-social-preview) echo "SEO and social preview" ;;
    deployment-status) echo "Deployment status" ;;
    maintenance) echo "Site maintenance" ;;
    general-drafts) echo "General drafts" ;;
    privacy-lock) echo "Quick hide" ;;
    knowledge-library) echo "Local knowledge library" ;;
    *) echo "$1" ;;
  esac
}

screen_guidance() {
  case "$1" in
    writing) echo "Show the writing workspace with editor, preview, metadata, and contextual writing actions." ;;
    ai-chat) echo "Show the in-app BYOK AI writing assistant with safe demo conversation, model selection, and user-supplied API-key guidance." ;;
    sync-api-publish) echo "Show GitHub/GitLab token check, remote conflict preview, direct API publish, and PR/MR controls." ;;
    seo-social-preview) echo "Show search/Open Graph/Twitter card previews, cache state, manual refresh, and external debug links." ;;
    deployment-status) echo "Show GitHub Pages/Actions, Netlify, Vercel, Cloudflare Pages, or custom endpoint validation status." ;;
    maintenance) echo "Show content calendar, taxonomy governance, stale articles, links, and operation log." ;;
    general-drafts) echo "Show general drafts in the writing workspace with move and copy to site actions." ;;
    privacy-lock) echo "Show the manually hidden workbench and private-content masking state." ;;
    knowledge-library) echo "Show the local knowledge library with import, search, cleaned reading content, source details, and annotations." ;;
    *) echo "Arrange the app for this required App Store screenshot." ;;
  esac
}

contains_required_id() {
  local candidate="$1"
  local id
  for id in "${required_ids[@]}"; do
    if [[ "$candidate" == "$id" ]]; then
      return 0
    fi
  done
  return 1
}

contains_marketing_only_id() {
  local candidate="$1"
  local id
  for id in "${marketing_only_ids[@]-}"; do
    [[ "$candidate" == "$id" ]] && return 0
  done
  return 1
}

load_required_ids

screenshot_app_pids() {
  pgrep -f "^${APP_BINARY}([[:space:]]|$)" 2>/dev/null || true
}

screenshot_app_pid() {
  screenshot_app_pids | head -n 1
}

stop_screenshot_app() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done < <(screenshot_app_pids)
}

launch_app() {
  local surface_id="${1:-writing}"
  local should_force="$FORCE_RELAUNCH"
  local existing_pids
  [[ -x "$APP_BINARY" ]] || fail "app binary is missing after build: $APP_BINARY"

  if [[ "$AUTO_WINDOW" == "1" && "$DEMO_DATA" == "1" ]]; then
    should_force=1
  fi

  existing_pids="$(screenshot_app_pids)"
  if [[ -n "$existing_pids" ]]; then
    if [[ "$DEMO_DATA" == "0" ]]; then
      echo "screenshot capture: using existing screenshot bundle window"
      return 0
    fi
    if [[ "$DEMO_DATA" == "1" && "$should_force" == "1" ]]; then
      echo "screenshot capture: quitting existing screenshot bundle before opening $surface_id"
      stop_screenshot_app
      sleep 1
    else
      fail "$APP_PRODUCT is already running; quit it first, or pass --force-relaunch so the requested screenshot surface can be opened cleanly"
    fi
  fi

  echo "screenshot capture: launching $APP_PRODUCT"
  if [[ "$DEMO_DATA" == "1" ]]; then
      /usr/bin/open -F -n "$APP_BUNDLE" \
        --env PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO=1 \
        --env PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE="$surface_id" \
        --env PERSONAL_SITE_PUBLISHER_SCREENSHOT_WINDOW_ID_FILE="$SCREENSHOT_WINDOW_ID_FILE"
      # A fresh SwiftUI scene can launch without restoring or creating its
      # default window. Send one reopen event after the process has registered
      # so WindowGroup deterministically creates the requested workbench.
      sleep 1
      /usr/bin/open -a "$APP_BUNDLE"
    else
      /usr/bin/open -n "$APP_BUNDLE"
    fi
  sleep "$CAPTURE_DELAY"
}

configure_screenshot_window() {
  local app_pid
  if [[ -s "$SCREENSHOT_WINDOW_ID_FILE" ]]; then
    return
  fi
  app_pid="$(screenshot_app_pid)"
  [[ -n "$app_pid" ]] || fail "could not find the screenshot bundle process"
  osascript - "$app_pid" <<'OSA'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set matchingProcesses to every application process whose unix id is targetPID
    if (count of matchingProcesses) is 0 then error "screenshot bundle process is unavailable"
    set targetProcess to item 1 of matchingProcesses
    set frontmost of targetProcess to true
    tell targetProcess
      if not (exists window 1) then error "no visible screenshot bundle window"
      set position of window 1 to {64, 56}
    end tell
  end tell
  delay 0.6
end run
OSA
}

frontmost_app_window_id() {
  if [[ -s "$SCREENSHOT_WINDOW_ID_FILE" ]]; then
    local recorded_window_id
    recorded_window_id="$(tr -d '[:space:]' <"$SCREENSHOT_WINDOW_ID_FILE")"
    if [[ "$recorded_window_id" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$recorded_window_id"
      return
    fi
  fi
  if [[ -f "$WINDOW_ID_HELPER" ]]; then
    local app_pid helper_window_id
    app_pid="$(screenshot_app_pid)"
    if helper_window_id="$(xcrun swift \
      -module-cache-path "${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/personal-site-publisher-clang-cache}" \
      "$WINDOW_ID_HELPER" "$app_pid" 2>/dev/null | tr -d '[:space:]')" \
      && [[ "$helper_window_id" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$helper_window_id"
      return
    fi
  fi
  local app_pid
  app_pid="$(screenshot_app_pid)"
  [[ -n "$app_pid" ]] || fail "could not find the screenshot bundle process"
  osascript - "$app_pid" <<'OSA'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set matchingProcesses to every application process whose unix id is targetPID
    if (count of matchingProcesses) is 0 then error "screenshot bundle process is unavailable"
    set targetProcess to item 1 of matchingProcesses
    set frontmost of targetProcess to true
    tell targetProcess
      if not (exists window 1) then error "no visible screenshot bundle window"
      return value of attribute "AXWindowNumber" of window 1
    end tell
  end tell
end run
OSA
}

frontmost_app_window_rect() {
  local app_pid
  app_pid="$(screenshot_app_pid)"
  [[ -n "$app_pid" ]] || fail "could not find the screenshot bundle process"
  osascript - "$app_pid" <<'OSA'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set matchingProcesses to every application process whose unix id is targetPID
    if (count of matchingProcesses) is 0 then error "screenshot bundle process is unavailable"
    set targetProcess to item 1 of matchingProcesses
    set frontmost of targetProcess to true
    tell targetProcess
      if not (exists window 1) then error "no visible screenshot bundle window"
      set windowPosition to position of window 1
      set windowSize to size of window 1
      return (item 1 of windowPosition as text) & "," & (item 2 of windowPosition as text) & "," & (item 1 of windowSize as text) & "," & (item 2 of windowSize as text)
    end tell
  end tell
end run
OSA
}

capture_current_app_window() {
  local output="$1"
  local window_id rect
  command -v osascript >/dev/null 2>&1 || fail "osascript is required for --auto-window"
  if window_id="$(frontmost_app_window_id 2>/dev/null | tr -d '[:space:]')" && [[ -n "$window_id" ]]; then
    if screencapture -x -l"$window_id" "$output"; then
      return
    fi
    rm -f "$output"
    echo "screenshot capture: window-id capture failed; falling back to the accessible window bounds." >&2
  fi

  rect="$(frontmost_app_window_rect | tr -d '[:space:]')" \
    || fail "could not read $APP_PRODUCT window bounds; grant Accessibility permission or use interactive capture"
  [[ "$rect" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]] \
    || fail "could not read valid $APP_PRODUCT window bounds: $rect"
  echo "screenshot capture: window id unavailable; capturing window bounds $rect."
  screencapture -x -R"$rect" "$output"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --real-data)
      DEMO_DATA=0
      shift
      ;;
    --force-relaunch)
      FORCE_RELAUNCH=1
      shift
      ;;
    --auto-window)
      AUTO_WINDOW=1
      shift
      ;;
    --marketing)
      MARKETING=1
      shift
      ;;
    --capture-delay)
      [[ "$#" -ge 2 ]] || fail "--capture-delay requires a number of seconds"
      CAPTURE_DELAY="$2"
      [[ "$CAPTURE_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "--capture-delay must be numeric"
      shift 2
      ;;
    --only)
      [[ "$#" -ge 2 ]] || fail "--only requires a screenshot id"
      ONLY_ID="$2"
      contains_required_id "$ONLY_ID" || contains_marketing_only_id "$ONLY_ID" \
        || fail "unknown screenshot id: $ONLY_ID"
      shift 2
      ;;
    --list)
      printf '%s\n' "${required_ids[@]}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

if [[ -n "$ONLY_ID" ]] && contains_marketing_only_id "$ONLY_ID"; then
  [[ "$MARKETING" == "1" ]] || fail "$ONLY_ID is available only with --marketing"
  required_ids+=("$ONLY_ID")
fi

mkdir -p "$SCREENSHOT_DIR"
command -v screencapture >/dev/null 2>&1 || fail "screencapture is not available"
[[ -f "$NORMALIZE_SCREENSHOT_SCRIPT" ]] || fail "screenshot normalization script is missing"
[[ -f "$COMPOSE_MARKETING_SCREENSHOT_SCRIPT" ]] || fail "marketing screenshot compositor is missing"
CAPTURE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/personal-site-publisher-capture.XXXXXX")"
APP_CAPTURE_TEMP_PARENT="${HOME:?HOME is required}/Library/Containers/$APP_BUNDLE_ID/Data/tmp"
mkdir -p "$APP_CAPTURE_TEMP_PARENT"
APP_CAPTURE_TEMP_DIR="$(mktemp -d "$APP_CAPTURE_TEMP_PARENT/app-store-screenshot.XXXXXX")"
SCREENSHOT_WINDOW_ID_FILE="$APP_CAPTURE_TEMP_DIR/window-id"
trap 'rm -rf "$CAPTURE_TEMP_DIR" "$APP_CAPTURE_TEMP_DIR"' EXIT

if [[ "$SKIP_BUILD" == "0" ]]; then
  echo "screenshot capture: building $APP_PRODUCT app bundle"
  PERSONAL_SITE_PUBLISHER_DIST_DIR="$SCREENSHOT_BUILD_DIST_DIR" \
    PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD=1 \
    bash "$ROOT_DIR/script/build_and_run.sh" --package-only --app-store >/dev/null
  if [[ "$AUTO_WINDOW" == "0" ]]; then
    launch_app "${ONLY_ID:-writing}"
  fi
fi

if [[ "$AUTO_WINDOW" == "1" && "$SKIP_BUILD" == "1" && -z "$ONLY_ID" ]]; then
  fail "--auto-window with --skip-build requires --only so the script does not overwrite every screenshot from the same window"
fi
if [[ "$AUTO_WINDOW" == "1" && "$DEMO_DATA" == "0" && -z "$ONLY_ID" ]]; then
  fail "--auto-window with --real-data requires --only so the script does not overwrite every screenshot from the same window"
fi

for id in "${required_ids[@]}"; do
  if [[ -n "$ONLY_ID" && "$id" != "$ONLY_ID" ]]; then
    continue
  fi

  if [[ "$MARKETING" == "1" ]]; then
    output="$MARKETING_SCREENSHOT_DIR/$id.png"
  else
    output="$SCREENSHOT_DIR/$id.png"
  fi
  raw_output="$CAPTURE_TEMP_DIR/$id.png"
  echo
  echo "screenshot capture: $id - $(screen_title "$id")"
  echo "screenshot capture: $(screen_guidance "$id")"
  echo "screenshot capture: hide private paths, real tokens, personal accounts, and unrelated windows."

  rm -f "$output" "$raw_output"
  if [[ "$AUTO_WINDOW" == "1" ]]; then
    rm -f "$SCREENSHOT_WINDOW_ID_FILE"
    launch_app "$id"
    configure_screenshot_window
    echo "screenshot capture: automatically capturing the frontmost $APP_PRODUCT window."
    capture_current_app_window "$raw_output"
  else
    echo "screenshot capture: press Return, then use the macOS capture picker to select the app window or region."
    read -r _
    screencapture -i "$raw_output"
  fi

  if [[ ! -s "$raw_output" ]]; then
    fail "capture was cancelled or empty for $id"
  fi

  if [[ "$MARKETING" == "1" ]]; then
    raw_properties="$(sips -g pixelWidth -g pixelHeight "$raw_output" 2>/dev/null)" \
      || fail "could not inspect native capture dimensions"
    raw_width="$(printf '%s\n' "$raw_properties" | awk '/pixelWidth:/ { print $2; exit }')"
    raw_height="$(printf '%s\n' "$raw_properties" | awk '/pixelHeight:/ { print $2; exit }')"
    if (( raw_width < 2400 || raw_height < 1400 )); then
      fail "native capture is only ${raw_width}x${raw_height}; move the app to a Retina display and recapture"
    fi
    mkdir -p "$RAW_SCREENSHOT_DIR" "$MARKETING_SCREENSHOT_DIR"
    cp "$raw_output" "$RAW_SCREENSHOT_DIR/$id.png"
    bash "$COMPOSE_MARKETING_SCREENSHOT_SCRIPT" "$id" "$raw_output" "$output" >/dev/null
    echo "screenshot capture: preserved Retina source $RAW_SCREENSHOT_DIR/$id.png"
  else
    bash "$NORMALIZE_SCREENSHOT_SCRIPT" "$raw_output" "$output" >/dev/null
  fi

  echo "screenshot capture: saved $output"
  if [[ "$MARKETING" == "0" ]]; then
    python3 "$CAPTURE_PROVENANCE_SCRIPT" record \
      --root "$ROOT_DIR" \
      --manifest "$MANIFEST_FILE" \
      --screenshot-dir "$SCREENSHOT_DIR" \
      --id "$id" \
      --image "$output" >/dev/null
  fi
done

if [[ "$MARKETING" == "0" ]]; then
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh"
  bash "$ROOT_DIR/script/check_screenshots.sh"
  bash "$ROOT_DIR/script/check_screenshot_privacy.sh"
else
  SCREENSHOT_DIR="$MARKETING_SCREENSHOT_DIR" bash "$ROOT_DIR/script/check_screenshot_privacy.sh"
  bash "$ROOT_DIR/script/check_app_store_marketing_quality.sh" "$MARKETING_SCREENSHOT_DIR"
fi
