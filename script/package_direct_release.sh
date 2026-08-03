#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${DIRECT_DISTRIBUTION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
APP_NAME="PersonalSitePublisherMac"
APP_DISPLAY_NAME="RepoPress Studio"
BUNDLE_ID="${PERSONAL_SITE_PUBLISHER_BUNDLE_ID:-com.jinfang.PersonalSitePublisherMac}"
SAFARI_EXTENSION_BUNDLE_ID="${SAFARI_WEB_EXTENSION_BUNDLE_ID:-$BUNDLE_ID.SafariExtension}"
DIRECT_ENTITLEMENTS="$ROOT_DIR/Packaging/DirectDistribution.entitlements"
SAFARI_ENTITLEMENTS="$ROOT_DIR/Packaging/SafariWebExtension.entitlements"
OUTPUT_DIR="${DIRECT_DISTRIBUTION_OUTPUT_DIR:-$ROOT_DIR/dist/direct}"
APPLICATION_IDENTITY="${DIRECT_DISTRIBUTION_APPLICATION_IDENTITY:-}"
NOTARY_PROFILE="${DIRECT_DISTRIBUTION_NOTARY_PROFILE:-}"
UPDATE_FEED_URL="${REPOPRESS_UPDATE_FEED_URL:-}"
UPDATE_PUBLIC_ED_KEY="${REPOPRESS_UPDATE_PUBLIC_ED_KEY:-}"
UPDATE_CHANNEL="${REPOPRESS_UPDATE_CHANNEL:-stable}"
UPDATE_DOWNLOAD_URL_PREFIX="${REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX:-}"
SPARKLE_KEY_ACCOUNT="${REPOPRESS_SPARKLE_KEY_ACCOUNT:-ed25519}"
SPARKLE_GENERATE_KEYS_TOOL="${SPARKLE_GENERATE_KEYS_TOOL:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys}"

CODESIGN_TOOL="${CODESIGN_TOOL:-/usr/bin/codesign}"
DITTO_TOOL="${DITTO_TOOL:-/usr/bin/ditto}"
GIT_TOOL="${GIT_TOOL:-/usr/bin/git}"
HDIUTIL_TOOL="${HDIUTIL_TOOL:-/usr/bin/hdiutil}"
PLISTBUDDY_TOOL="${PLISTBUDDY_TOOL:-/usr/libexec/PlistBuddy}"
PLUTIL_TOOL="${PLUTIL_TOOL:-/usr/bin/plutil}"
PYTHON_TOOL="${PYTHON_TOOL:-/usr/bin/python3}"
SECURITY_TOOL="${SECURITY_TOOL:-/usr/bin/security}"
SHASUM_TOOL="${SHASUM_TOOL:-/usr/bin/shasum}"
SPCTL_TOOL="${SPCTL_TOOL:-/usr/sbin/spctl}"
XATTR_TOOL="${XATTR_TOOL:-/usr/bin/xattr}"
XCRUN_TOOL="${XCRUN_TOOL:-/usr/bin/xcrun}"

MODE="release"
APP_BUNDLE_INPUT="${DIRECT_DISTRIBUTION_APP_BUNDLE_PATH:-}"
DMG_INPUT="${DIRECT_DISTRIBUTION_DMG_PATH:-}"
ZIP_INPUT="${DIRECT_DISTRIBUTION_ZIP_PATH:-}"
MANIFEST_INPUT="${DIRECT_DISTRIBUTION_MANIFEST_PATH:-}"
CHECKSUM_INPUT="${DIRECT_DISTRIBUTION_CHECKSUM_PATH:-}"
APPCAST_INPUT="${DIRECT_DISTRIBUTION_APPCAST_PATH:-}"
TMP_DIR=""

usage() {
  cat <<'USAGE'
Usage: script/package_direct_release.sh [mode] [options]

Builds a Developer ID signed, hardened-runtime RepoPress release, submits both
the app and DMG to Apple's notary service, staples the returned tickets, and
creates a ZIP, DMG, SHA-256 list, and source-bound JSON manifest.

Modes:
  --dry-run     Check tools, entitlements, and credential names without building,
                signing, contacting Apple, or claiming distribution readiness.
  --prepare     Build and copy an ad-hoc signed Direct Release app for inspection.
                The result is explicitly not a distributable artifact.
  --validate    Validate an existing complete signed/notarized artifact set. This
                needs no signing certificate or notary credentials.
  --release     Run the complete release workflow (default).

Options:
  --output-dir <path>       Override dist/direct.
  --identity <identity>     Developer ID Application identity. Prefer the
                            DIRECT_DISTRIBUTION_APPLICATION_IDENTITY environment.
  --notary-profile <name>   notarytool keychain profile. Prefer the
                            DIRECT_DISTRIBUTION_NOTARY_PROFILE environment.
  --app-bundle <path>       App to validate.
  --dmg <path>              DMG to validate.
  --zip <path>              ZIP to validate.
  --manifest <path>         JSON release manifest to validate.
  --checksums <path>        SHA-256 file to validate.
  --appcast <path>          Signed Sparkle appcast to validate.

Create the notary credential once without storing secrets in this repository:

  xcrun notarytool store-credentials "RepoPress-Notary"
USAGE
}

fail() {
  echo "direct release: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

canonical_path() {
  "$PYTHON_TOOL" - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

require_tool() {
  local tool="$1"
  if [[ "$tool" == */* ]]; then
    [[ -x "$tool" ]] || fail "required tool is unavailable: $tool"
  else
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
  fi
}

safe_remove_output() {
  local target="$1"
  case "$target" in
    "$OUTPUT_DIR"/*) ;;
    *) fail "refusing to remove a path outside the output directory: $target" ;;
  esac
  if [[ -d "$target" && ! -L "$target" ]]; then
    rm -rf "$target"
  else
    rm -f "$target"
  fi
}

plist_value() {
  "$PLISTBUDDY_TOOL" -c "Print :$2" "$1" 2>/dev/null || true
}

validate_bundle_structure() {
  local app_bundle="$1"
  local require_update_configuration="${2:-0}"
  local info_plist="$app_bundle/Contents/Info.plist"
  local app_binary="$app_bundle/Contents/MacOS/$APP_NAME"
  local safari_extension="$app_bundle/Contents/PlugIns/RepoPressSafariExtension.appex"
  local safari_info="$safari_extension/Contents/Info.plist"
  local safari_executable=""
  local sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
  local sparkle_license="$app_bundle/Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt"
  local update_feed_url=""
  local update_public_key=""
  local update_channel=""

  [[ -d "$app_bundle" ]] || fail "app bundle is missing: $app_bundle"
  [[ -f "$info_plist" ]] || fail "app Info.plist is missing: $info_plist"
  [[ -x "$app_binary" ]] || fail "app executable is missing: $app_binary"
  [[ -d "$sparkle_framework" ]] || fail "Sparkle.framework is missing"
  [[ -L "$sparkle_framework/Versions/Current" && -L "$sparkle_framework/Sparkle" ]] \
    || fail "Sparkle.framework symlinks were not preserved"
  [[ -s "$sparkle_license" ]] || fail "Sparkle third-party notice is missing"
  grep -Fq 'Copyright (c) 2006-2013 Andy Matuschak.' "$sparkle_license" \
    || fail "Sparkle third-party notice is incomplete"
  grep -Fq 'EXTERNAL LICENSES' "$sparkle_license" \
    || fail "Sparkle external-license notices are incomplete"
  [[ -d "$safari_extension" ]] || fail "Safari Web Extension is missing: $safari_extension"
  [[ -f "$safari_info" ]] || fail "Safari Web Extension Info.plist is missing"
  "$PLUTIL_TOOL" -lint "$info_plist" >/dev/null || fail "app Info.plist is invalid"
  "$PLUTIL_TOOL" -lint "$safari_info" >/dev/null || fail "Safari Web Extension Info.plist is invalid"

  [[ "$(plist_value "$info_plist" CFBundleIdentifier)" == "$BUNDLE_ID" ]] \
    || fail "app bundle identifier is not $BUNDLE_ID"
  [[ "$(plist_value "$info_plist" CFBundleShortVersionString)" == "$MARKETING_VERSION" ]] \
    || fail "app marketing version does not match Packaging/BuildVersion.xcconfig"
  [[ "$(plist_value "$info_plist" CFBundleVersion)" == "$BUILD_NUMBER" ]] \
    || fail "app build number does not match Packaging/BuildVersion.xcconfig"
  [[ "$(plist_value "$info_plist" PersonalSitePublisherDistributionChannel)" == "Direct" ]] \
    || fail "app is not marked as the Direct distribution channel"
  [[ "$(plist_value "$info_plist" SUEnableInstallerLauncherService)" == "true" ]] \
    || fail "SUEnableInstallerLauncherService is not enabled"
  update_feed_url="$(plist_value "$info_plist" SUFeedURL)"
  update_public_key="$(plist_value "$info_plist" SUPublicEDKey)"
  update_channel="$(plist_value "$info_plist" RepoPressUpdateChannel)"
  case "$update_channel" in
    stable|beta) ;;
    *) fail "RepoPressUpdateChannel is not stable or beta" ;;
  esac
  if [[ "$require_update_configuration" == "1" ]]; then
    [[ -n "$update_feed_url" && -n "$update_public_key" ]] \
      || fail "signed release is missing its Sparkle feed URL or EdDSA public key"
    "$PYTHON_TOOL" - "$update_feed_url" "$update_channel" <<'PY'
from urllib.parse import urlparse
import sys

parsed = urlparse(sys.argv[1])
if parsed.scheme.lower() != "https" or not parsed.netloc:
    raise SystemExit("direct release: signed app SUFeedURL must be an absolute https URL")
expected_name = f"{sys.argv[2]}-appcast.xml"
if parsed.path.rsplit("/", 1)[-1] != expected_name:
    raise SystemExit(f"direct release: signed app SUFeedURL must end in {expected_name}")
PY
  fi
  [[ "$(plist_value "$safari_info" CFBundleIdentifier)" == "$SAFARI_EXTENSION_BUNDLE_ID" ]] \
    || fail "Safari Web Extension bundle identifier is not $SAFARI_EXTENSION_BUNDLE_ID"
  safari_executable="$(plist_value "$safari_info" CFBundleExecutable)"
  [[ -n "$safari_executable" ]] || fail "Safari Web Extension executable name is missing"
  [[ -x "$safari_extension/Contents/MacOS/$safari_executable" ]] \
    || fail "Safari Web Extension executable is missing"
}

signature_report() {
  local bundle="$1"
  local report="$2"
  "$CODESIGN_TOOL" -dv --verbose=4 "$bundle" >"$report" 2>&1 \
    || fail "could not inspect code signature: $bundle"
}

signature_team() {
  sed -n 's/^TeamIdentifier=//p' "$1" | head -n 1
}

validate_signed_app() {
  local app_bundle="$1"
  local require_notary_ticket="$2"
  local validation_dir=""
  local app_report=""
  local safari_report=""
  local actual_entitlements=""
  local actual_safari_entitlements=""
  local app_team=""
  local safari_team=""
  local safari_extension="$app_bundle/Contents/PlugIns/RepoPressSafariExtension.appex"

  validate_bundle_structure "$app_bundle" 1
  validation_dir="$(mktemp -d "$TMP_DIR/signature.XXXXXX")"
  app_report="$validation_dir/app-signature.txt"
  safari_report="$validation_dir/safari-signature.txt"
  actual_entitlements="$validation_dir/app-entitlements.plist"
  actual_safari_entitlements="$validation_dir/safari-entitlements.plist"

  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$safari_extension" \
    || fail "Safari Web Extension signature verification failed"
  "$CODESIGN_TOOL" --verify --deep --strict --verbose=2 "$app_bundle" \
    || fail "app signature verification failed"
  signature_report "$app_bundle" "$app_report"
  signature_report "$safari_extension" "$safari_report"

  grep -Eq '^Authority=Developer ID Application:' "$app_report" \
    || fail "app is not signed with Developer ID Application"
  grep -Eq '^Authority=Developer ID Application:' "$safari_report" \
    || fail "Safari Web Extension is not signed with Developer ID Application"
  grep -Eq '^CodeDirectory .*flags=.*runtime' "$app_report" \
    || fail "app signature does not prove hardened runtime"
  grep -Eq '^CodeDirectory .*flags=.*runtime' "$safari_report" \
    || fail "Safari Web Extension signature does not prove hardened runtime"

  app_team="$(signature_team "$app_report")"
  safari_team="$(signature_team "$safari_report")"
  [[ -n "$app_team" && "$app_team" != "not set" ]] \
    || fail "app signature does not expose a TeamIdentifier"
  [[ "$safari_team" == "$app_team" ]] \
    || fail "app and Safari Web Extension signatures use different teams"
  bash "$ROOT_DIR/script/sign_sparkle_framework.sh" \
    --framework "$app_bundle/Contents/Frameworks/Sparkle.framework" \
    --validate-only \
    --require-developer-id \
    --expected-team "$app_team" >/dev/null

  "$CODESIGN_TOOL" -d --entitlements :- "$app_bundle" >"$actual_entitlements" 2>/dev/null \
    || fail "could not extract app entitlements"
  "$CODESIGN_TOOL" -d --entitlements :- "$safari_extension" \
    >"$actual_safari_entitlements" 2>/dev/null \
    || fail "could not extract Safari Web Extension entitlements"
  "$PLUTIL_TOOL" -lint "$actual_entitlements" >/dev/null \
    || fail "signed app entitlements are invalid"
  "$PLUTIL_TOOL" -lint "$actual_safari_entitlements" >/dev/null \
    || fail "signed Safari Web Extension entitlements are invalid"
  "$PYTHON_TOOL" - \
    "$DIRECT_ENTITLEMENTS" "$actual_entitlements" \
    "$SAFARI_ENTITLEMENTS" "$actual_safari_entitlements" <<'PY'
import plistlib
from pathlib import Path
import sys

def load(path: str) -> dict:
    with Path(path).open("rb") as handle:
        return plistlib.load(handle)

for expected_path, actual_path, label in (
    (sys.argv[1], sys.argv[2], "app"),
    (sys.argv[3], sys.argv[4], "Safari Web Extension"),
):
    expected = load(expected_path)
    actual = load(actual_path)
    for key, value in expected.items():
        if actual.get(key) != value:
            raise SystemExit(f"direct release: signed {label} entitlement mismatch: {key}")
    if actual.get("com.apple.security.get-task-allow") is True:
        raise SystemExit(f"direct release: signed {label} unexpectedly allows debugging")
PY

  if [[ "$require_notary_ticket" == "1" ]]; then
    "$XCRUN_TOOL" stapler validate "$app_bundle" \
      || fail "stapled app notarization ticket validation failed"
    "$SPCTL_TOOL" --assess --type execute --verbose=4 "$app_bundle" \
      || fail "Gatekeeper rejected the app"
  fi
  printf '%s\n' "$app_team"
}

validate_signed_disk_image() {
  local dmg_path="$1"
  local expected_team="$2"
  local validation_dir=""
  local dmg_report=""
  local dmg_team=""

  [[ -f "$dmg_path" ]] || fail "DMG is missing: $dmg_path"
  "$CODESIGN_TOOL" --verify --strict --verbose=2 "$dmg_path" \
    || fail "DMG signature verification failed"
  validation_dir="$(mktemp -d "$TMP_DIR/dmg-signature.XXXXXX")"
  dmg_report="$validation_dir/dmg-signature.txt"
  signature_report "$dmg_path" "$dmg_report"
  grep -Eq '^Authority=Developer ID Application:' "$dmg_report" \
    || fail "DMG is not signed with Developer ID Application"
  dmg_team="$(signature_team "$dmg_report")"
  [[ -n "$dmg_team" && "$dmg_team" != "not set" ]] \
    || fail "DMG signature does not expose a TeamIdentifier"
  [[ "$dmg_team" == "$expected_team" ]] \
    || fail "app and DMG signatures use different teams"
  printf '%s\n' "$dmg_team"
}

build_direct_app() {
  local destination="$1"
  local require_update_configuration="${2:-0}"
  local built_app="$ROOT_DIR/dist/$APP_NAME.app"

  CODE_SIGN_IDENTITY="-" \
    PERSONAL_SITE_PUBLISHER_DIST_DIR="$ROOT_DIR/dist" \
    REPOPRESS_UPDATE_FEED_URL="$UPDATE_FEED_URL" \
    REPOPRESS_UPDATE_PUBLIC_ED_KEY="$UPDATE_PUBLIC_ED_KEY" \
    REPOPRESS_UPDATE_CHANNEL="$UPDATE_CHANNEL" \
    bash "$ROOT_DIR/script/build_and_run.sh" --package-only --direct >/dev/null
  [[ -d "$built_app" ]] || fail "direct Release build did not create $built_app"
  safe_remove_output "$destination"
  mkdir -p "$(dirname "$destination")"
  "$DITTO_TOOL" --norsrc --noextattr "$built_app" "$destination"
  "$XATTR_TOOL" -cr "$destination"
  validate_bundle_structure "$destination" "$require_update_configuration"
}

submit_for_notarization() {
  local artifact="$1"
  local receipt="$2"
  local status=""

  if ! "$XCRUN_TOOL" notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json >"$receipt"; then
    sed -n '1,120p' "$receipt" >&2 || true
    fail "Apple notarization submission failed: $artifact"
  fi
  status="$($PYTHON_TOOL - "$receipt" <<'PY'
import json
from pathlib import Path
import sys

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("status", ""))
PY
)"
  [[ "$status" == "Accepted" ]] || {
    sed -n '1,120p' "$receipt" >&2 || true
    fail "Apple notarization did not return Accepted for $artifact"
  }
}

bundle_tree_sha256() {
  "$PYTHON_TOOL" - "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
entries = []
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        target = os.readlink(path)
        entries.append({"kind": "symlink", "path": relative, "target": target})
    elif path.is_file():
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        entries.append({"kind": "file", "path": relative, "sha256": digest.hexdigest()})
encoded = json.dumps(entries, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
print(hashlib.sha256(encoded).hexdigest())
PY
}

write_release_manifest() {
  local manifest="$1"
  local app_bundle="$2"
  local zip_path="$3"
  local dmg_path="$4"
  local appcast_path="$5"
  local app_receipt="$6"
  local dmg_receipt="$7"
  local team_identifier="$8"

  "$PYTHON_TOOL" - \
    "$manifest" "$app_bundle" "$zip_path" "$dmg_path" "$appcast_path" \
    "$app_receipt" "$dmg_receipt" "$ROOT_DIR" "$OUTPUT_DIR" \
    "$MARKETING_VERSION" "$BUILD_NUMBER" "$BUNDLE_ID" "$team_identifier" \
    "$UPDATE_DOWNLOAD_URL_PREFIX" "$UPDATE_CHANNEL" <<'PY'
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import os
import subprocess
import sys

(
    manifest_value,
    app_value,
    zip_value,
    dmg_value,
    appcast_value,
    app_receipt_value,
    dmg_receipt_value,
    root_value,
    output_value,
    version,
    build,
    bundle_id,
    team_identifier,
    download_url_prefix,
    update_channel,
) = sys.argv[1:]
manifest = Path(manifest_value)
app = Path(app_value)
zip_path = Path(zip_value)
dmg_path = Path(dmg_value)
appcast_path = Path(appcast_value)
root = Path(root_value)
output = Path(output_value)

def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def bundle_digest(bundle: Path) -> str:
    entries = []
    for path in sorted(bundle.rglob("*"), key=lambda item: item.relative_to(bundle).as_posix()):
        relative = path.relative_to(bundle).as_posix()
        if path.is_symlink():
            entries.append({"kind": "symlink", "path": relative, "target": os.readlink(path)})
        elif path.is_file():
            entries.append({"kind": "file", "path": relative, "sha256": digest(path)})
    encoded = json.dumps(entries, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()

def git_value(*arguments):
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), *arguments],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip() or None
    except (OSError, subprocess.CalledProcessError):
        return None

app_receipt = json.loads(Path(app_receipt_value).read_text(encoding="utf-8"))
dmg_receipt = json.loads(Path(dmg_receipt_value).read_text(encoding="utf-8"))
status = git_value("status", "--porcelain", "--untracked-files=all")
payload = {
    "schemaVersion": 1,
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "product": {
        "name": "RepoPress Studio",
        "bundleIdentifier": bundle_id,
        "marketingVersion": version,
        "buildNumber": build,
        "minimumSystemVersion": "14.0",
        "distributionChannel": "Direct",
    },
    "source": {
        "commit": git_value("rev-parse", "HEAD"),
        "commitTimestamp": git_value("show", "-s", "--format=%cI", "HEAD"),
        "isDirty": bool(status),
    },
    "signing": {
        "kind": "Developer ID Application",
        "teamIdentifier": team_identifier,
        "hardenedRuntime": True,
        "timestamped": True,
        "entitlements": "Packaging/DirectDistribution.entitlements",
    },
    "notarization": {
        "app": {"id": app_receipt.get("id"), "status": app_receipt.get("status")},
        "dmg": {"id": dmg_receipt.get("id"), "status": dmg_receipt.get("status")},
        "appTicketStapled": True,
        "dmgTicketStapled": True,
    },
    "updates": {
        "channel": update_channel,
        "downloadURLPrefix": download_url_prefix.rstrip("/") + "/",
        "appcast": appcast_path.relative_to(output).as_posix(),
    },
    "artifacts": {
        "app": {
            "path": app.relative_to(output).as_posix(),
            "treeSha256": bundle_digest(app),
        },
        "zip": {
            "path": zip_path.relative_to(output).as_posix(),
            "sha256": digest(zip_path),
            "sizeBytes": zip_path.stat().st_size,
        },
        "dmg": {
            "path": dmg_path.relative_to(output).as_posix(),
            "sha256": digest(dmg_path),
            "sizeBytes": dmg_path.stat().st_size,
        },
        "appcast": {
            "path": appcast_path.relative_to(output).as_posix(),
            "sha256": digest(appcast_path),
            "sizeBytes": appcast_path.stat().st_size,
        },
    },
    "reproducibility": {
        "stableArtifactNames": True,
        "sourceAndArtifactHashesRecorded": True,
        "byteForByteReproducible": False,
        "reason": "Apple secure timestamps, notarization tickets, and disk-image metadata vary between releases.",
    },
}
manifest.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

validate_manifest_and_checksums() {
  local app_bundle="$1"
  local zip_path="$2"
  local dmg_path="$3"
  local manifest="$4"
  local checksums="$5"
  local appcast="$6"

  "$PYTHON_TOOL" - \
    "$app_bundle" "$zip_path" "$dmg_path" "$manifest" "$checksums" "$appcast" \
    "$MARKETING_VERSION" "$BUILD_NUMBER" "$BUNDLE_ID" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

app, zip_path, dmg_path, manifest, checksums, appcast = map(Path, sys.argv[1:7])
version, build, bundle_id = sys.argv[7:10]

def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def bundle_digest(bundle: Path) -> str:
    entries = []
    for path in sorted(bundle.rglob("*"), key=lambda item: item.relative_to(bundle).as_posix()):
        relative = path.relative_to(bundle).as_posix()
        if path.is_symlink():
            entries.append({"kind": "symlink", "path": relative, "target": os.readlink(path)})
        elif path.is_file():
            entries.append({"kind": "file", "path": relative, "sha256": digest(path)})
    encoded = json.dumps(entries, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()

payload = json.loads(manifest.read_text(encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("direct release: unsupported direct release manifest schema")
product = payload.get("product", {})
expected_product = {
    "bundleIdentifier": bundle_id,
    "marketingVersion": version,
    "buildNumber": build,
    "distributionChannel": "Direct",
}
for key, expected in expected_product.items():
    if product.get(key) != expected:
        raise SystemExit(f"direct release: manifest product mismatch: {key}")
if payload.get("signing", {}).get("kind") != "Developer ID Application":
    raise SystemExit("direct release: manifest does not record Developer ID signing")
if payload.get("signing", {}).get("hardenedRuntime") is not True:
    raise SystemExit("direct release: manifest does not record hardened runtime")
for target in ("app", "dmg"):
    if payload.get("notarization", {}).get(target, {}).get("status") != "Accepted":
        raise SystemExit(f"direct release: manifest notarization status is not Accepted: {target}")
artifacts = payload.get("artifacts", {})
actual_values = {
    "app": bundle_digest(app),
    "zip": digest(zip_path),
    "dmg": digest(dmg_path),
    "appcast": digest(appcast),
}
if artifacts.get("app", {}).get("treeSha256") != actual_values["app"]:
    raise SystemExit("direct release: app tree hash does not match the manifest")
for target in ("zip", "dmg", "appcast"):
    if artifacts.get(target, {}).get("sha256") != actual_values[target]:
        raise SystemExit(f"direct release: {target} hash does not match the manifest")

entries = {}
for line in checksums.read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", line)
    if not match:
        raise SystemExit("direct release: malformed SHA-256 checksum line")
    entries[match.group(2)] = match.group(1).lower()
for path in (zip_path, dmg_path, manifest, appcast):
    if entries.get(path.name) != digest(path):
        raise SystemExit(f"direct release: checksum mismatch or omission: {path.name}")

updates = payload.get("updates", {})
channel = updates.get("channel")
prefix = str(updates.get("downloadURLPrefix", ""))
if channel not in {"stable", "beta"} or not prefix.startswith("https://"):
    raise SystemExit("direct release: manifest update channel or download prefix is invalid")
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
items = ET.parse(appcast).getroot().findall("./channel/item")
matches = []
for item in items:
    enclosure = item.find("enclosure")
    if enclosure is not None and enclosure.attrib.get("url") == prefix + zip_path.name:
        matches.append((item, enclosure))
if len(matches) != 1:
    raise SystemExit("direct release: appcast does not contain exactly one final ZIP enclosure")
item, enclosure = matches[0]
if not enclosure.attrib.get(f"{{{sparkle}}}edSignature"):
    raise SystemExit("direct release: appcast enclosure has no EdDSA signature")
channel_element = item.find(f"{{{sparkle}}}channel")
if channel == "stable":
    if channel_element is not None and (channel_element.text or "").strip():
        raise SystemExit("direct release: stable appcast item must not carry a channel")
elif channel_element is None or (channel_element.text or "").strip() != "beta":
    raise SystemExit("direct release: beta appcast item is missing its beta channel")
PY
}

validate_complete_release() {
  local app_bundle="$1"
  local dmg_path="$2"
  local zip_path="$3"
  local manifest="$4"
  local checksums="$5"
  local appcast="$6"
  local extracted_app=""
  local app_team=""
  local extracted_team=""
  local output_tree=""
  local extracted_tree=""
  local extract_dir="$TMP_DIR/zip-validation"

  for path in "$dmg_path" "$zip_path" "$manifest" "$checksums" "$appcast"; do
    [[ -f "$path" ]] || fail "release artifact is missing: $path"
  done
  app_team="$(validate_signed_app "$app_bundle" 1 | tail -n 1)"
  validate_signed_disk_image "$dmg_path" "$app_team" >/dev/null
  "$XCRUN_TOOL" stapler validate "$dmg_path" \
    || fail "stapled DMG notarization ticket validation failed"
  "$SPCTL_TOOL" --assess --type open --context context:primary-signature \
    --verbose=4 "$dmg_path" || fail "Gatekeeper rejected the DMG"

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  "$DITTO_TOOL" -x -k "$zip_path" "$extract_dir"
  extracted_app="$extract_dir/$APP_DISPLAY_NAME.app"
  [[ -d "$extracted_app" ]] || fail "ZIP does not contain $APP_DISPLAY_NAME.app"
  extracted_team="$(validate_signed_app "$extracted_app" 1 | tail -n 1)"
  [[ "$extracted_team" == "$app_team" ]] \
    || fail "app and ZIP signatures use different teams"
  output_tree="$(bundle_tree_sha256 "$app_bundle")"
  extracted_tree="$(bundle_tree_sha256 "$extracted_app")"
  [[ "$output_tree" == "$extracted_tree" ]] \
    || fail "ZIP app content differs from the validated app bundle"
  validate_manifest_and_checksums \
    "$app_bundle" "$zip_path" "$dmg_path" "$manifest" "$checksums" "$appcast"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --prepare)
      MODE="prepare"
      shift
      ;;
    --validate)
      MODE="validate"
      shift
      ;;
    --release)
      MODE="release"
      shift
      ;;
    --output-dir)
      [[ "$#" -ge 2 ]] || fail "--output-dir requires a path"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --identity)
      [[ "$#" -ge 2 ]] || fail "--identity requires a value"
      APPLICATION_IDENTITY="$2"
      shift 2
      ;;
    --notary-profile)
      [[ "$#" -ge 2 ]] || fail "--notary-profile requires a value"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --app-bundle)
      [[ "$#" -ge 2 ]] || fail "--app-bundle requires a path"
      APP_BUNDLE_INPUT="$2"
      shift 2
      ;;
    --dmg)
      [[ "$#" -ge 2 ]] || fail "--dmg requires a path"
      DMG_INPUT="$2"
      shift 2
      ;;
    --zip)
      [[ "$#" -ge 2 ]] || fail "--zip requires a path"
      ZIP_INPUT="$2"
      shift 2
      ;;
    --manifest)
      [[ "$#" -ge 2 ]] || fail "--manifest requires a path"
      MANIFEST_INPUT="$2"
      shift 2
      ;;
    --checksums)
      [[ "$#" -ge 2 ]] || fail "--checksums requires a path"
      CHECKSUM_INPUT="$2"
      shift 2
      ;;
    --appcast)
      [[ "$#" -ge 2 ]] || fail "--appcast requires a path"
      APPCAST_INPUT="$2"
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

for tool in \
  "$CODESIGN_TOOL" "$DITTO_TOOL" "$GIT_TOOL" "$HDIUTIL_TOOL" \
  "$PLISTBUDDY_TOOL" "$PLUTIL_TOOL" "$PYTHON_TOOL" "$SECURITY_TOOL" \
  "$SHASUM_TOOL" "$SPCTL_TOOL" "$XATTR_TOOL" "$XCRUN_TOOL"; do
  require_tool "$tool"
done

ROOT_DIR="$(canonical_path "$ROOT_DIR")"
OUTPUT_DIR="$(canonical_path "$OUTPUT_DIR")"
DIRECT_ENTITLEMENTS="$ROOT_DIR/Packaging/DirectDistribution.entitlements"
SAFARI_ENTITLEMENTS="$ROOT_DIR/Packaging/SafariWebExtension.entitlements"
case "$OUTPUT_DIR" in
  /|"${HOME:-}"|"$ROOT_DIR"|"$ROOT_DIR/dist")
    fail "refusing unsafe output directory: $OUTPUT_DIR"
    ;;
esac

[[ -f "$ROOT_DIR/script/build_and_run.sh" ]] || fail "missing script/build_and_run.sh"
[[ -f "$ROOT_DIR/script/check_build_version.sh" ]] || fail "missing script/check_build_version.sh"
[[ -f "$ROOT_DIR/script/check_repository_source_boundary.sh" ]] \
  || fail "missing script/check_repository_source_boundary.sh"
[[ -f "$ROOT_DIR/script/sign_sparkle_framework.sh" ]] \
  || fail "missing script/sign_sparkle_framework.sh"
[[ -f "$ROOT_DIR/script/generate_direct_appcast.sh" ]] \
  || fail "missing script/generate_direct_appcast.sh"
[[ -f "$ROOT_DIR/Packaging/ThirdPartyNotices/Sparkle-LICENSE.txt" ]] \
  || fail "missing Packaging/ThirdPartyNotices/Sparkle-LICENSE.txt"
[[ -f "$DIRECT_ENTITLEMENTS" ]] || fail "missing Packaging/DirectDistribution.entitlements"
[[ -f "$SAFARI_ENTITLEMENTS" ]] || fail "missing Packaging/SafariWebExtension.entitlements"
"$PLUTIL_TOOL" -lint "$DIRECT_ENTITLEMENTS" >/dev/null \
  || fail "DirectDistribution.entitlements is invalid"
"$PLUTIL_TOOL" -lint "$SAFARI_ENTITLEMENTS" >/dev/null \
  || fail "SafariWebExtension.entitlements is invalid"
"$XCRUN_TOOL" -f notarytool >/dev/null \
  || fail "Xcode does not provide notarytool"
"$XCRUN_TOOL" -f stapler >/dev/null \
  || fail "Xcode does not provide stapler"

version_values="$(bash "$ROOT_DIR/script/check_build_version.sh" --print-values)"
IFS=$'\t' read -r MARKETING_VERSION BUILD_NUMBER <<<"$version_values"
[[ -n "$MARKETING_VERSION" && -n "$BUILD_NUMBER" ]] \
  || fail "build version values are unavailable"
artifact_base="RepoPress-Studio-$MARKETING_VERSION-$BUILD_NUMBER"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repopress-direct-release.XXXXXX")"

if [[ "$MODE" == "dry-run" ]]; then
  missing=()
  [[ -n "$APPLICATION_IDENTITY" ]] || missing+=(DIRECT_DISTRIBUTION_APPLICATION_IDENTITY)
  [[ -n "$NOTARY_PROFILE" ]] || missing+=(DIRECT_DISTRIBUTION_NOTARY_PROFILE)
  [[ -n "$UPDATE_FEED_URL" ]] || missing+=(REPOPRESS_UPDATE_FEED_URL)
  [[ -n "$UPDATE_PUBLIC_ED_KEY" ]] || missing+=(REPOPRESS_UPDATE_PUBLIC_ED_KEY)
  [[ -n "$UPDATE_DOWNLOAD_URL_PREFIX" ]] || missing+=(REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX)
  if [[ -n "$APPLICATION_IDENTITY" ]]; then
    identity_output="$($SECURITY_TOOL find-identity -v -p codesigning 2>/dev/null || true)"
    if ! grep -F -- "$APPLICATION_IDENTITY" <<<"$identity_output" \
      | grep -F '"Developer ID Application:' >/dev/null; then
      echo "direct release: configured Developer ID identity is not available in the current keychain"
    fi
  fi
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "direct release: workflow is installed; configure before release: ${missing[*]}"
  else
    echo "direct release: workflow and credential names are configured"
  fi
  echo "direct release: dry-run did not build, sign, contact Apple, or prove notarization"
  exit 0
fi

if [[ "$MODE" == "prepare" ]]; then
  prepared_root="$OUTPUT_DIR/prepared-$artifact_base"
  prepared_app="$prepared_root/$APP_DISPLAY_NAME.app"
  safe_remove_output "$prepared_root"
  mkdir -p "$prepared_root"
  build_direct_app "$prepared_app" 0
  echo "direct release: prepared ad-hoc inspection app $prepared_app"
  echo "direct release: this app is not Developer ID signed, notarized, or ready to distribute"
  if [[ -z "$UPDATE_FEED_URL" || -z "$UPDATE_PUBLIC_ED_KEY" ]]; then
    echo "direct release: automatic updates are disabled in this prepared app"
  fi
  exit 0
fi

if [[ "$MODE" == "validate" ]]; then
  [[ -n "$APP_BUNDLE_INPUT" ]] || fail "--validate requires --app-bundle or DIRECT_DISTRIBUTION_APP_BUNDLE_PATH"
  [[ -n "$DMG_INPUT" ]] || fail "--validate requires --dmg or DIRECT_DISTRIBUTION_DMG_PATH"
  [[ -n "$ZIP_INPUT" ]] || fail "--validate requires --zip or DIRECT_DISTRIBUTION_ZIP_PATH"
  [[ -n "$MANIFEST_INPUT" ]] || fail "--validate requires --manifest or DIRECT_DISTRIBUTION_MANIFEST_PATH"
  [[ -n "$CHECKSUM_INPUT" ]] || fail "--validate requires --checksums or DIRECT_DISTRIBUTION_CHECKSUM_PATH"
  [[ -n "$APPCAST_INPUT" ]] || fail "--validate requires --appcast or DIRECT_DISTRIBUTION_APPCAST_PATH"
  APP_BUNDLE_INPUT="$(canonical_path "$APP_BUNDLE_INPUT")"
  DMG_INPUT="$(canonical_path "$DMG_INPUT")"
  ZIP_INPUT="$(canonical_path "$ZIP_INPUT")"
  MANIFEST_INPUT="$(canonical_path "$MANIFEST_INPUT")"
  CHECKSUM_INPUT="$(canonical_path "$CHECKSUM_INPUT")"
  APPCAST_INPUT="$(canonical_path "$APPCAST_INPUT")"
  validate_complete_release \
    "$APP_BUNDLE_INPUT" "$DMG_INPUT" "$ZIP_INPUT" "$MANIFEST_INPUT" "$CHECKSUM_INPUT" "$APPCAST_INPUT"
  echo "direct release: signed, hardened, notarized, stapled artifacts and hashes validated"
  exit 0
fi

bash "$ROOT_DIR/script/check_repository_source_boundary.sh" --release >/dev/null \
  || fail "Developer ID release packaging requires a clean committed Git checkout"
[[ -n "$APPLICATION_IDENTITY" ]] \
  || fail "DIRECT_DISTRIBUTION_APPLICATION_IDENTITY is required"
[[ -n "$NOTARY_PROFILE" ]] \
  || fail "DIRECT_DISTRIBUTION_NOTARY_PROFILE is required"
[[ -n "$UPDATE_FEED_URL" ]] || fail "REPOPRESS_UPDATE_FEED_URL is required"
[[ -n "$UPDATE_PUBLIC_ED_KEY" ]] || fail "REPOPRESS_UPDATE_PUBLIC_ED_KEY is required"
[[ -n "$UPDATE_DOWNLOAD_URL_PREFIX" ]] \
  || fail "REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX is required"
[[ -n "$SPARKLE_KEY_ACCOUNT" ]] || fail "REPOPRESS_SPARKLE_KEY_ACCOUNT must not be empty"
[[ -x "$SPARKLE_GENERATE_KEYS_TOOL" ]] \
  || fail "Sparkle generate_keys is unavailable: $SPARKLE_GENERATE_KEYS_TOOL"
case "$UPDATE_CHANNEL" in
  stable|beta) ;;
  *) fail "REPOPRESS_UPDATE_CHANNEL must be stable or beta" ;;
esac
"$PYTHON_TOOL" - \
  "$UPDATE_FEED_URL" "$UPDATE_PUBLIC_ED_KEY" "$UPDATE_DOWNLOAD_URL_PREFIX" "$UPDATE_CHANNEL" <<'PY'
from urllib.parse import urlparse
import sys

feed_url, public_key, download_prefix, channel = sys.argv[1:]
parsed = urlparse(feed_url)
if feed_url != feed_url.strip() or parsed.scheme.lower() != "https" or not parsed.netloc:
    raise SystemExit("direct release: REPOPRESS_UPDATE_FEED_URL must be an absolute https URL")
if parsed.path.rsplit("/", 1)[-1] != f"{channel}-appcast.xml":
    raise SystemExit(f"direct release: REPOPRESS_UPDATE_FEED_URL must end in {channel}-appcast.xml")
if public_key != public_key.strip() or not public_key or any(character.isspace() for character in public_key):
    raise SystemExit("direct release: REPOPRESS_UPDATE_PUBLIC_ED_KEY must be a non-empty single-line EdDSA public key")
download = urlparse(download_prefix)
if download_prefix != download_prefix.strip() or download.scheme.lower() != "https" or not download.netloc:
    raise SystemExit("direct release: REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX must be an absolute https URL")
PY
actual_update_public_key="$($SPARKLE_GENERATE_KEYS_TOOL \
  --account "$SPARKLE_KEY_ACCOUNT" -p)" \
  || fail "could not read the existing Sparkle public key from the Keychain"
actual_update_public_key="$(printf '%s' "$actual_update_public_key" | tr -d '\r\n')"
[[ "$actual_update_public_key" == "$UPDATE_PUBLIC_ED_KEY" ]] \
  || fail "REPOPRESS_UPDATE_PUBLIC_ED_KEY does not match the Keychain private key account"
identity_output="$($SECURITY_TOOL find-identity -v -p codesigning 2>&1 || true)"
grep -F -- "$APPLICATION_IDENTITY" <<<"$identity_output" \
  | grep -F '"Developer ID Application:' >/dev/null \
  || fail "configured identity is not an available Developer ID Application certificate"

release_root="$OUTPUT_DIR/$artifact_base"
signed_app="$release_root/$APP_DISPLAY_NAME.app"
zip_path="$OUTPUT_DIR/$artifact_base-macOS.zip"
dmg_path="$OUTPUT_DIR/$artifact_base-macOS.dmg"
manifest_path="$OUTPUT_DIR/$artifact_base-manifest.json"
checksum_path="$OUTPUT_DIR/$artifact_base.sha256"
appcast_path="$OUTPUT_DIR/$UPDATE_CHANNEL-appcast.xml"
for target in "$release_root" "$zip_path" "$dmg_path" "$manifest_path" "$checksum_path"; do
  safe_remove_output "$target"
done
mkdir -p "$release_root"
build_direct_app "$signed_app" 1

safari_extension="$signed_app/Contents/PlugIns/RepoPressSafariExtension.appex"
bash "$ROOT_DIR/script/sign_sparkle_framework.sh" \
  --framework "$signed_app/Contents/Frameworks/Sparkle.framework" \
  --identity "$APPLICATION_IDENTITY" \
  --timestamp >/dev/null
"$CODESIGN_TOOL" --force --options runtime --timestamp \
  --entitlements "$SAFARI_ENTITLEMENTS" \
  --sign "$APPLICATION_IDENTITY" "$safari_extension"
"$CODESIGN_TOOL" --force --options runtime --timestamp \
  --entitlements "$DIRECT_ENTITLEMENTS" \
  --sign "$APPLICATION_IDENTITY" "$signed_app"
team_identifier="$(validate_signed_app "$signed_app" 0 | tail -n 1)"

notary_upload_zip="$TMP_DIR/$artifact_base-notary-upload.zip"
app_notary_receipt="$TMP_DIR/app-notary-receipt.json"
"$DITTO_TOOL" -c -k --sequesterRsrc --keepParent "$signed_app" "$notary_upload_zip"
submit_for_notarization "$notary_upload_zip" "$app_notary_receipt"
"$XCRUN_TOOL" stapler staple "$signed_app" || fail "could not staple the app notarization ticket"
"$XCRUN_TOOL" stapler validate "$signed_app" || fail "could not validate the stapled app ticket"
"$SPCTL_TOOL" --assess --type execute --verbose=4 "$signed_app" \
  || fail "Gatekeeper rejected the notarized app"

"$DITTO_TOOL" -c -k --sequesterRsrc --keepParent "$signed_app" "$zip_path"
REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX="$UPDATE_DOWNLOAD_URL_PREFIX" \
REPOPRESS_SPARKLE_KEY_ACCOUNT="$SPARKLE_KEY_ACCOUNT" \
REPOPRESS_UPDATE_CHANNEL="$UPDATE_CHANNEL" \
  bash "$ROOT_DIR/script/generate_direct_appcast.sh" \
    --archive "$zip_path" --output "$appcast_path" >/dev/null
dmg_staging="$TMP_DIR/dmg-root"
mkdir -p "$dmg_staging"
"$DITTO_TOOL" "$signed_app" "$dmg_staging/$APP_DISPLAY_NAME.app"
ln -s /Applications "$dmg_staging/Applications"
"$HDIUTIL_TOOL" create \
  -volname "$APP_DISPLAY_NAME" \
  -srcfolder "$dmg_staging" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$dmg_path" >/dev/null
[[ -f "$dmg_path" ]] || fail "hdiutil did not create the DMG"
"$CODESIGN_TOOL" --force --timestamp \
  --sign "$APPLICATION_IDENTITY" "$dmg_path"
validate_signed_disk_image "$dmg_path" "$team_identifier" >/dev/null

dmg_notary_receipt="$TMP_DIR/dmg-notary-receipt.json"
submit_for_notarization "$dmg_path" "$dmg_notary_receipt"
"$XCRUN_TOOL" stapler staple "$dmg_path" || fail "could not staple the DMG notarization ticket"
"$XCRUN_TOOL" stapler validate "$dmg_path" || fail "could not validate the stapled DMG ticket"
"$SPCTL_TOOL" --assess --type open --context context:primary-signature \
  --verbose=4 "$dmg_path" || fail "Gatekeeper rejected the notarized DMG"

write_release_manifest \
  "$manifest_path" "$signed_app" "$zip_path" "$dmg_path" "$appcast_path" \
  "$app_notary_receipt" "$dmg_notary_receipt" "$team_identifier"
(
  cd "$OUTPUT_DIR"
  "$SHASUM_TOOL" -a 256 \
    "$(basename "$zip_path")" \
    "$(basename "$dmg_path")" \
    "$(basename "$manifest_path")" \
    "$(basename "$appcast_path")" >"$(basename "$checksum_path")"
)
validate_complete_release \
  "$signed_app" "$dmg_path" "$zip_path" "$manifest_path" "$checksum_path" "$appcast_path"

echo "direct release: Developer ID app $signed_app"
echo "direct release: notarized ZIP $zip_path"
echo "direct release: notarized and stapled DMG $dmg_path"
echo "direct release: manifest $manifest_path"
echo "direct release: SHA-256 $checksum_path"
echo "direct release: signed appcast $appcast_path"
