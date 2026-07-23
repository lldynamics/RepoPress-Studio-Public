#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PersonalSitePublisherMac"
APP_BUNDLE="${APP_STORE_APP_BUNDLE_PATH:-}"
ARCHIVE_PATH="${APP_STORE_ARCHIVE_PATH:-}"
INFO_PLIST=""
APP_BINARY=""
ENTITLEMENTS="$ROOT_DIR/Sources/PersonalSitePublisherMac/AppStore.entitlements"
SAFARI_EXTENSION_ENTITLEMENTS="$ROOT_DIR/Packaging/SafariWebExtension.entitlements"
SAFARI_EXTENSION_BUNDLE_ID="com.jinfang.PersonalSitePublisherMac.SafariExtension"
ARCHIVE_EVIDENCE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md}"
STRICT=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: script/check_app_store_archive_readiness.sh [--strict] [--dry-run]
       [--archive <path.xcarchive> | --app-bundle <path.app>]

Checks local App Store archive readiness without pretending that local package
checks prove App Store Connect upload readiness. Default mode verifies the
local .app package, Info.plist, sandbox entitlements, and reports signing and
Transporter/App Store Connect evidence status. Strict mode also requires
signed/hardened-runtime evidence and completed archive-validation evidence.

Options:
  --strict             Require an explicit signed archive/app artifact plus completed evidence.
  --archive <path>     Validate Products/Applications/PersonalSitePublisherMac.app in this archive.
  --app-bundle <path>  Validate this exact app bundle without rebuilding it.
  --dry-run            Validate that required scripts/evidence templates exist only.

The paths may also be provided through APP_STORE_ARCHIVE_PATH or
APP_STORE_APP_BUNDLE_PATH. Without an explicit artifact, non-strict mode builds
a fresh local unsigned Release package for local-only readiness checks.
USAGE
}

fail() {
  echo "app store archive readiness: $*" >&2
  exit 1
}

warn() {
  echo "app store archive readiness warning: $*" >&2
}

validate_archive_evidence() {
  local require_complete="$1"
  python3 - "$ARCHIVE_EVIDENCE" "$require_complete" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
require_complete = sys.argv[2] == "1"
text = path.read_text()
required_titles = [
    "Clean Release archive produced from a clean checkout.",
    "Distribution signing and hardened runtime verified on the archive.",
    "Archive validated with App Store Connect or Transporter before upload.",
]
private_pattern = re.compile(
    r"(/Users/|/Volumes/|file:///Users/|file:///Volumes/|"
    r"github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|"
    r"Authorization:[ \t]*Bearer[ \t]+[A-Za-z0-9._-]{20,}|"
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|"
    r"Apple[ \t]*ID|TeamIdentifier=|Receipt[ \t]*ID|receipt[ \t]*id)"
)
lines = text.splitlines()
checked = {}
private_evidence_lines = []
for index, line in enumerate(lines):
    match = re.match(r"^- \[[xX]\] (.+)$", line.strip())
    if not match:
        continue
    title = match.group(1)
    evidence = ""
    if index + 1 < len(lines):
        evidence_match = re.match(r"^\s*Evidence:\s*(.*)$", lines[index + 1])
        if evidence_match:
            evidence = evidence_match.group(1).strip()
            if evidence and private_pattern.search(evidence):
                private_evidence_lines.append(title)
    checked[title] = evidence

if private_evidence_lines:
    print(
        "app store archive readiness: archive validation Evidence contains private-looking content for: "
        + "; ".join(private_evidence_lines),
        file=sys.stderr,
    )
    sys.exit(1)

missing = []
empty_evidence = []
for title in required_titles:
    if title not in checked:
        missing.append(title)
    elif not checked[title]:
        empty_evidence.append(title)

if empty_evidence:
    print(
        "app store archive readiness: checked archive validation item(s) need non-empty Evidence: "
        + "; ".join(empty_evidence),
        file=sys.stderr,
    )
    sys.exit(1)
if require_complete and missing:
    print(
        "app store archive readiness: strict mode requires completed archive validation item(s): "
        + "; ".join(missing),
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --archive)
      [[ "$#" -ge 2 ]] || fail "--archive requires a path"
      [[ -z "$APP_BUNDLE" ]] || fail "--archive cannot be combined with --app-bundle"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --app-bundle)
      [[ "$#" -ge 2 ]] || fail "--app-bundle requires a path"
      [[ -z "$ARCHIVE_PATH" ]] || fail "--app-bundle cannot be combined with --archive"
      APP_BUNDLE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$ROOT_DIR/script/build_and_run.sh" ]] || fail "missing script/build_and_run.sh"
[[ -f "$ROOT_DIR/script/check_build_version.sh" ]] || fail "missing script/check_build_version.sh"
[[ -f "$ROOT_DIR/script/check_app_store_metadata.sh" ]] || fail "missing script/check_app_store_metadata.sh"
[[ -f "$ROOT_DIR/script/package_app_store.sh" ]] || fail "missing script/package_app_store.sh"
[[ -f "$ENTITLEMENTS" ]] || fail "missing Sources/PersonalSitePublisherMac/AppStore.entitlements"
[[ -f "$SAFARI_EXTENSION_ENTITLEMENTS" ]] \
  || fail "missing Packaging/SafariWebExtension.entitlements"
[[ -f "$ARCHIVE_EVIDENCE" ]] || fail "missing docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md"
bash "$ROOT_DIR/script/check_build_version.sh" >/dev/null

if [[ "$DRY_RUN" == "1" ]]; then
  validate_archive_evidence "${STRICT_ARCHIVE_EVIDENCE_ONLY:-0}"
  echo "app store archive readiness: required scripts and evidence template are present"
  exit 0
fi

if [[ -n "$ARCHIVE_PATH" ]]; then
  [[ "$ARCHIVE_PATH" == *.xcarchive ]] || fail "--archive must point to a .xcarchive"
  [[ -d "$ARCHIVE_PATH" ]] || fail "archive does not exist: $ARCHIVE_PATH"
  APP_BUNDLE="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
elif [[ -z "$APP_BUNDLE" ]]; then
  [[ "$STRICT" == "0" ]] \
    || fail "strict mode requires --archive/APP_STORE_ARCHIVE_PATH or --app-bundle/APP_STORE_APP_BUNDLE_PATH"
  # Local readiness may build a fresh unsigned Release package. It is never
  # treated as evidence for the signed distribution archive boundary.
  bash "$ROOT_DIR/script/build_and_run.sh" --package-only --app-store >/dev/null
  APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
fi

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
CORE_RESOURCE_INFO="$APP_BUNDLE/Contents/Resources/${APP_NAME}_PublishingWorkbenchCore.bundle/Info.plist"
SAFARI_EXTENSION="$APP_BUNDLE/Contents/PlugIns/RepoPressSafariExtension.appex"
SAFARI_EXTENSION_INFO="$SAFARI_EXTENSION/Contents/Info.plist"
SAFARI_EXTENSION_MANIFEST="$SAFARI_EXTENSION/Contents/Resources/manifest.json"

[[ -d "$APP_BUNDLE" ]] || fail "app bundle does not exist: $APP_BUNDLE"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing from app bundle"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable"
[[ -d "$SAFARI_EXTENSION" ]] || fail "embedded Safari Web Extension is missing"
[[ -f "$SAFARI_EXTENSION_INFO" ]] || fail "Safari Web Extension Info.plist is missing"
[[ -f "$SAFARI_EXTENSION_MANIFEST" ]] || fail "Safari Web Extension manifest is missing"
plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
plutil -lint "$SAFARI_EXTENSION_INFO" >/dev/null \
  || fail "Safari Web Extension Info.plist is invalid"
python3 -m json.tool "$SAFARI_EXTENSION_MANIFEST" >/dev/null \
  || fail "Safari Web Extension manifest is invalid"
[[ -f "$CORE_RESOURCE_INFO" ]] || fail "PublishingWorkbenchCore resource bundle Info.plist is missing"
plutil -lint "$CORE_RESOURCE_INFO" >/dev/null || fail "PublishingWorkbenchCore resource bundle Info.plist is invalid"
plutil -lint "$ENTITLEMENTS" >/dev/null || fail "AppStore.entitlements is invalid"
plutil -lint "$SAFARI_EXTENSION_ENTITLEMENTS" >/dev/null \
  || fail "SafariWebExtension.entitlements is invalid"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$INFO_PLIST" 2>/dev/null || true)"
application_category="$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$INFO_PLIST" 2>/dev/null || true)"
human_readable_copyright="$(/usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' "$INFO_PLIST" 2>/dev/null || true)"
uses_non_exempt_encryption="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$INFO_PLIST" 2>/dev/null || true)"

[[ "$bundle_id" == "com.jinfang.PersonalSitePublisherMac" ]] || fail "unexpected bundle identifier: $bundle_id"
core_resource_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CORE_RESOURCE_INFO" 2>/dev/null || true)"
[[ "$core_resource_bundle_id" == "$bundle_id.PublishingWorkbenchCoreResources" ]] \
  || fail "PublishingWorkbenchCore resource bundle is missing its expected CFBundleIdentifier"
core_resource_package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$CORE_RESOURCE_INFO" 2>/dev/null || true)"
[[ "$core_resource_package_type" == "BNDL" ]] \
  || fail "PublishingWorkbenchCore resource bundle must declare CFBundlePackageType=BNDL"
[[ "$marketing_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "invalid marketing version: $marketing_version"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "invalid build number: $build_number"
[[ "$build_configuration" == "Release" ]] || fail "archive readiness requires a Release bundle, got: ${build_configuration:-missing configuration evidence}"
[[ "$application_category" == "public.app-category.developer-tools" ]] \
  || fail "archive must use the Developer Tools category"
[[ -n "${human_readable_copyright//[[:space:]]/}" ]] || fail "archive is missing NSHumanReadableCopyright"
[[ "$uses_non_exempt_encryption" == "false" ]] \
  || fail "archive must declare ITSAppUsesNonExemptEncryption=false for the audited encryption boundary"
safari_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SAFARI_EXTENSION_INFO")"
safari_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SAFARI_EXTENSION_INFO")"
safari_bundle_basename="$(basename "$SAFARI_EXTENSION" .appex)"
safari_package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$SAFARI_EXTENSION_INFO")"
safari_extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$SAFARI_EXTENSION_INFO")"
safari_minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SAFARI_EXTENSION_INFO")"
[[ "$safari_bundle_id" == "$SAFARI_EXTENSION_BUNDLE_ID" ]] \
  || fail "unexpected Safari Web Extension bundle identifier: $safari_bundle_id"
[[ "$safari_executable" == "$safari_bundle_basename" ]] \
  || fail "Safari Web Extension CFBundleExecutable must match its bundle name"
[[ -x "$SAFARI_EXTENSION/Contents/MacOS/$safari_executable" ]] \
  || fail "Safari Web Extension executable is missing or not executable"
[[ "$safari_package_type" == "XPC!" ]] \
  || fail "Safari Web Extension must use CFBundlePackageType=XPC!"
[[ "$safari_extension_point" == "com.apple.Safari.web-extension" ]] \
  || fail "unexpected Safari Web Extension point: $safari_extension_point"
[[ "$safari_minimum_system" == "14.0" ]] \
  || fail "Safari Web Extension minimum system must be 14.0"
bash "$ROOT_DIR/script/build_safari_web_extension.sh" --check >/dev/null
bash "$ROOT_DIR/script/check_build_version.sh" --info-plist "$INFO_PLIST" >/dev/null

codesign_log="$(mktemp "${TMPDIR:-/tmp}/app-store-codesign.XXXXXX")"
safari_codesign_log="$(mktemp "${TMPDIR:-/tmp}/app-store-safari-codesign.XXXXXX")"
trap 'rm -f "$codesign_log" "$safari_codesign_log"' EXIT
signed=0
runtime_enabled=0
safari_signed=0
safari_runtime_enabled=0
identity_summary="unsigned"
safari_identity_summary="unsigned"

if /usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" >"$codesign_log" 2>&1; then
  identity_summary="$(grep -E '^Authority=|^TeamIdentifier=|^flags=' "$codesign_log" | paste -sd ';' -)"
  if /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
    signed=1
  fi
  if grep -Eq '^CodeDirectory .*flags=.*runtime' "$codesign_log"; then
    runtime_enabled=1
  fi
fi
if /usr/bin/codesign -dv --verbose=4 "$SAFARI_EXTENSION" >"$safari_codesign_log" 2>&1; then
  safari_identity_summary="$(grep -E '^Authority=|^TeamIdentifier=|^flags=' "$safari_codesign_log" | paste -sd ';' -)"
  if /usr/bin/codesign --verify --strict "$SAFARI_EXTENSION" >/dev/null 2>&1; then
    safari_signed=1
  fi
  if grep -Eq '^CodeDirectory .*flags=.*runtime' "$safari_codesign_log"; then
    safari_runtime_enabled=1
  fi
fi

unchecked_archive_items="$(grep -c '^- \[ \]' "$ARCHIVE_EVIDENCE" || true)"
checked_archive_items="$(grep -Ec '^- \[[xX]\]' "$ARCHIVE_EVIDENCE" || true)"
validate_archive_evidence 0

if [[ "$signed" == "1" ]]; then
  echo "app store archive readiness: code signature verifies ($identity_summary)"
else
  warn "app bundle is not verified with a distribution code signature"
fi

if [[ "$runtime_enabled" == "1" ]]; then
  echo "app store archive readiness: hardened runtime flag is present"
else
  warn "hardened runtime flag is not proven on the current app bundle"
fi
if [[ "$safari_signed" == "1" ]]; then
  echo "app store archive readiness: Safari Web Extension signature verifies ($safari_identity_summary)"
else
  warn "Safari Web Extension is not verified with a distribution code signature"
fi
if [[ "$safari_runtime_enabled" == "1" ]]; then
  echo "app store archive readiness: Safari Web Extension hardened runtime flag is present"
else
  warn "Safari Web Extension hardened runtime flag is not proven on the current bundle"
fi

if [[ "$unchecked_archive_items" -eq 0 && "$checked_archive_items" -gt 0 ]]; then
  echo "app store archive readiness: archive validation evidence is complete"
else
  warn "archive validation evidence still has $unchecked_archive_items unchecked item(s)"
fi

if [[ "$STRICT" == "1" ]]; then
  [[ "$signed" == "1" ]] || fail "strict mode requires a verified distribution-signed app bundle"
  [[ "$runtime_enabled" == "1" ]] || fail "strict mode requires hardened runtime evidence"
  [[ "$safari_signed" == "1" ]] \
    || fail "strict mode requires a verified Safari Web Extension signature"
  [[ "$safari_runtime_enabled" == "1" ]] \
    || fail "strict mode requires Safari Web Extension hardened runtime evidence"
  [[ -f "$SAFARI_EXTENSION/Contents/embedded.provisionprofile" ]] \
    || fail "strict mode requires an embedded Safari extension provisioning profile"
  actual_entitlements="$(mktemp "${TMPDIR:-/tmp}/app-store-entitlements.XXXXXX")"
  actual_safari_entitlements="$(mktemp "${TMPDIR:-/tmp}/app-store-safari-entitlements.XXXXXX")"
  trap 'rm -f "$codesign_log" "$safari_codesign_log" "$actual_entitlements" "$actual_safari_entitlements"' EXIT
  /usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" >"$actual_entitlements" 2>/dev/null \
    || fail "strict mode could not extract entitlements from the signed app bundle"
  plutil -lint "$actual_entitlements" >/dev/null || fail "signed app entitlements are invalid"
  actual_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$actual_entitlements" 2>/dev/null || true)"
  actual_network="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$actual_entitlements" 2>/dev/null || true)"
  actual_file_access="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$actual_entitlements" 2>/dev/null || true)"
  actual_bookmarks="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.bookmarks.app-scope' "$actual_entitlements" 2>/dev/null || true)"
  [[ "$actual_sandbox" == "true" ]] || fail "signed app is missing App Sandbox entitlement"
  [[ "$actual_network" == "true" ]] || fail "signed app is missing Network Client entitlement"
  [[ "$actual_file_access" == "true" ]] || fail "signed app is missing user-selected read/write entitlement"
  [[ "$actual_bookmarks" == "true" ]] || fail "signed app is missing app-scope bookmark entitlement"
  /usr/bin/codesign -d --entitlements :- "$SAFARI_EXTENSION" \
    >"$actual_safari_entitlements" 2>/dev/null \
    || fail "strict mode could not extract Safari Web Extension entitlements"
  plutil -lint "$actual_safari_entitlements" >/dev/null \
    || fail "signed Safari Web Extension entitlements are invalid"
  safari_actual_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$actual_safari_entitlements" 2>/dev/null || true)"
  [[ "$safari_actual_sandbox" == "true" ]] \
    || fail "signed Safari Web Extension is missing App Sandbox entitlement"
  app_team="$(sed -n 's/^TeamIdentifier=//p' "$codesign_log" | head -n 1)"
  safari_team="$(sed -n 's/^TeamIdentifier=//p' "$safari_codesign_log" | head -n 1)"
  [[ -n "$app_team" && "$safari_team" == "$app_team" ]] \
    || fail "Safari Web Extension signing team does not match the containing app"
  validate_archive_evidence 1
  [[ "$unchecked_archive_items" -eq 0 && "$checked_archive_items" -gt 0 ]] \
    || fail "strict mode requires completed docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md"
fi

if [[ -n "$ARCHIVE_PATH" ]]; then
  echo "app store archive readiness: validated explicit xcarchive app for bundle id $bundle_id, version $marketing_version ($build_number)"
elif [[ "$APP_BUNDLE" != "$ROOT_DIR/dist/$APP_NAME.app" ]]; then
  echo "app store archive readiness: validated explicit app bundle for bundle id $bundle_id, version $marketing_version ($build_number)"
else
  echo "app store archive readiness: fresh local Release package checks passed for bundle id $bundle_id, version $marketing_version ($build_number); this is not signed Release archive validation"
fi
