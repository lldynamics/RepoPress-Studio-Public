#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="$ROOT_DIR/docs/app-store-screenshots"
MANIFEST_FILE="${SCREENSHOT_MANIFEST_FILE:-$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md}"
APP_PRODUCT="PersonalSitePublisherMac"
APP_BUNDLE_ID="com.jinfang.PersonalSitePublisherMac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_PRODUCT.app"
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
WINDOW_CAPTURE_HELPER="$ROOT_DIR/script/run_app_store_window_capture.sh"
MARKETING=0
MARKETING_SCREENSHOT_DIR="${SCREENSHOT_MARKETING_DIR:-$SCREENSHOT_DIR/marketing}"
RAW_SCREENSHOT_DIR="${SCREENSHOT_RAW_DIR:-$SCREENSHOT_DIR/sources}"
marketing_only_ids=(knowledge-library)

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
    ai-chat) echo "AI assistant Inspector" ;;
    sync-api-publish) echo "Sync/API publishing workspace" ;;
    seo-social-preview) echo "SEO and social preview" ;;
    deployment-status) echo "Deployment status" ;;
    maintenance) echo "Site maintenance" ;;
    general-drafts) echo "Cross-site copy" ;;
    pro-settings) echo "Pro settings" ;;
    privacy-lock) echo "Quick hide" ;;
    knowledge-library) echo "Local knowledge library" ;;
    *) echo "$1" ;;
  esac
}

screen_guidance() {
  case "$1" in
    writing) echo "Show the writing workspace with editor, preview, metadata, and contextual writing actions." ;;
    ai-chat) echo "Keep the article editor visible while showing the AI assistant Inspector with conversation, context, quick prompts, and apply actions." ;;
    sync-api-publish) echo "Show GitHub/GitLab token check, remote conflict preview, direct API publish, and PR/MR controls." ;;
    seo-social-preview) echo "Show search/Open Graph/Twitter card previews, cache state, manual refresh, and external debug links." ;;
    deployment-status) echo "Show GitHub Pages/Actions, Netlify, Vercel, Cloudflare Pages, or custom endpoint validation status." ;;
    maintenance) echo "Show content calendar, taxonomy governance, stale articles, links, and operation log." ;;
    general-drafts) echo "Show cross-site copy across publishing sites with the copy to site action." ;;
    pro-settings) echo "Show free quota, Pro unlock, purchase, and restore state without real payment or account secrets." ;;
    privacy-lock) echo "Show the manually hidden workbench and private-content masking state." ;;
    knowledge-library) echo "Show the local knowledge library with imported sources, search, and related content." ;;
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
  for id in "${marketing_only_ids[@]}"; do
    [[ "$candidate" == "$id" ]] && return 0
  done
  return 1
}

load_required_ids

launch_app() {
  local surface_id="${1:-writing}"
  local should_force="$FORCE_RELAUNCH"
  [[ -x "$APP_BINARY" ]] || fail "app binary is missing after build: $APP_BINARY"

  if [[ "$AUTO_WINDOW" == "1" && "$DEMO_DATA" == "1" ]]; then
    should_force=1
  fi

  if pgrep -x "$APP_PRODUCT" >/dev/null 2>&1; then
    if [[ "$DEMO_DATA" == "0" ]]; then
      echo "screenshot capture: using existing $APP_PRODUCT window"
      return 0
    fi
    if [[ "$DEMO_DATA" == "1" && "$should_force" == "1" ]]; then
      echo "screenshot capture: quitting existing $APP_PRODUCT before opening $surface_id"
      pkill -TERM -x "$APP_PRODUCT" || true
      sleep 1
    else
      fail "$APP_PRODUCT is already running; quit it first, or pass --force-relaunch so the requested screenshot surface can be opened cleanly"
    fi
  fi

  echo "screenshot capture: launching $APP_PRODUCT"
  if [[ "$DEMO_DATA" == "1" ]]; then
      /usr/bin/open -n "$APP_BUNDLE" \
        --env PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO=1 \
        --env PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE="$surface_id" \
        --env PERSONAL_SITE_PUBLISHER_SCREENSHOT_WINDOW_ID_FILE="$SCREENSHOT_WINDOW_ID_FILE" \
        --env PERSONAL_SITE_PUBLISHER_SCREENSHOT_SOURCE_FILE="$SCREENSHOT_SELF_CAPTURE_FILE"
    else
      /usr/bin/open -n "$APP_BUNDLE"
    fi
  sleep "$CAPTURE_DELAY"
}

configure_screenshot_window() {
  if [[ -s "$SCREENSHOT_WINDOW_ID_FILE" ]]; then
    return
  fi
  osascript <<OSA
tell application "$APP_PRODUCT" to activate
delay 0.5
tell application "System Events"
  tell process "$APP_PRODUCT"
    if not (exists window 1) then error "no visible $APP_PRODUCT window"
    set frontmost to true
    set position of window 1 to {64, 56}
    set size of window 1 to {1280, 800}
  end tell
end tell
delay 0.6
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
    app_pid="$(pgrep -f "^${APP_BINARY}([[:space:]]|$)" 2>/dev/null | head -n 1 || true)"
    if helper_window_id="$(xcrun swift \
      -module-cache-path "${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/personal-site-publisher-clang-cache}" \
      "$WINDOW_ID_HELPER" "$app_pid" 2>/dev/null | tr -d '[:space:]')" \
      && [[ "$helper_window_id" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$helper_window_id"
      return
    fi
  fi
  osascript <<OSA
tell application "$APP_PRODUCT" to activate
delay 0.4
tell application "System Events"
  tell process "$APP_PRODUCT"
    if not (exists window 1) then error "no visible $APP_PRODUCT window"
    set frontmost to true
    return value of attribute "AXWindowNumber" of window 1
  end tell
end tell
OSA
}

frontmost_app_window_rect() {
  osascript <<OSA
tell application "$APP_PRODUCT" to activate
delay 0.4
tell application "System Events"
  tell process "$APP_PRODUCT"
    if not (exists window 1) then error "no visible $APP_PRODUCT window"
    set frontmost to true
    set windowPosition to position of window 1
    set windowSize to size of window 1
    return (item 1 of windowPosition as text) & "," & (item 2 of windowPosition as text) & "," & (item 1 of windowSize as text) & "," & (item 2 of windowSize as text)
  end tell
end tell
OSA
}

capture_current_app_window() {
  local output="$1"
  local window_id rect attempt
  for attempt in {1..40}; do
    [[ -s "$SCREENSHOT_SELF_CAPTURE_FILE" ]] && break
    sleep 0.25
  done
  if [[ -s "$SCREENSHOT_SELF_CAPTURE_FILE" ]]; then
    cp "$SCREENSHOT_SELF_CAPTURE_FILE" "$output"
    echo "screenshot capture: used the app's native 2x window render."
    return
  fi
  command -v osascript >/dev/null 2>&1 || fail "osascript is required for --auto-window"
  if window_id="$(frontmost_app_window_id 2>/dev/null | tr -d '[:space:]')" && [[ -n "$window_id" ]]; then
    bash "$WINDOW_CAPTURE_HELPER" "$window_id" "$APP_BUNDLE_ID" "$output" 2
    return
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
[[ -f "$WINDOW_CAPTURE_HELPER" ]] || fail "ScreenCaptureKit window capture helper is missing"
CAPTURE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/personal-site-publisher-capture.XXXXXX")"
SCREENSHOT_WINDOW_ID_FILE="$CAPTURE_TEMP_DIR/window-id"
SCREENSHOT_SELF_CAPTURE_FILE="$CAPTURE_TEMP_DIR/window-self.png"
trap 'rm -rf "$CAPTURE_TEMP_DIR"' EXIT

if [[ "$SKIP_BUILD" == "0" ]]; then
  echo "screenshot capture: building $APP_PRODUCT app bundle"
  PERSONAL_SITE_PUBLISHER_CAPTURE_BUILD=1 \
    bash "$ROOT_DIR/script/build_and_run.sh" --package-only >/dev/null
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
    rm -f "$SCREENSHOT_WINDOW_ID_FILE" "$SCREENSHOT_SELF_CAPTURE_FILE"
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
