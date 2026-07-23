#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PersonalSitePublisherMac"
BUNDLE_ID="com.jinfang.PersonalSitePublisherMac"
ENTITLEMENTS="$ROOT_DIR/Sources/PersonalSitePublisherMac/AppStore.entitlements"
SAFARI_EXTENSION_ENTITLEMENTS="$ROOT_DIR/Packaging/SafariWebExtension.entitlements"
SAFARI_EXTENSION_BUNDLE_ID="$BUNDLE_ID.SafariExtension"
OUTPUT_DIR="${APP_STORE_OUTPUT_DIR:-$ROOT_DIR/dist/app-store}"
APPLICATION_IDENTITY="${APP_STORE_APPLICATION_IDENTITY:-}"
INSTALLER_IDENTITY="${APP_STORE_INSTALLER_IDENTITY:-}"
PROVISIONING_PROFILE="${APP_STORE_PROVISIONING_PROFILE:-}"
SAFARI_EXTENSION_PROVISIONING_PROFILE="${APP_STORE_SAFARI_EXTENSION_PROVISIONING_PROFILE:-}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: script/package_app_store.sh [--dry-run] [--output-dir <path>]

Creates a distribution-signed Mac App Store .app and installer .pkg from a
clean Git checkout. The command intentionally requires explicit credentials:

  APP_STORE_APPLICATION_IDENTITY  Mac App Distribution signing identity
  APP_STORE_INSTALLER_IDENTITY    Mac Installer Distribution signing identity
  APP_STORE_PROVISIONING_PROFILE  Matching Mac App Store provisioning profile
  APP_STORE_SAFARI_EXTENSION_PROVISIONING_PROFILE
                                  Matching Safari extension provisioning profile

Options:
  --dry-run            Verify the packaging path and print missing configuration.
  --output-dir <path>  Override the generated artifact directory.
USAGE
}

fail() {
  echo "app store package: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --output-dir)
      [[ "$#" -ge 2 ]] || fail "--output-dir requires a path"
      OUTPUT_DIR="$2"
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

OUTPUT_DIR="$(python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
)"
case "$OUTPUT_DIR" in
  /|"$HOME"|"$ROOT_DIR"|"$ROOT_DIR/dist")
    fail "refusing unsafe output directory: $OUTPUT_DIR"
    ;;
esac

for tool in codesign ditto git plutil productbuild pkgutil python3 security shasum xattr; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[[ -f "$ROOT_DIR/script/build_and_run.sh" ]] || fail "missing script/build_and_run.sh"
[[ -f "$ROOT_DIR/script/check_app_store_archive_readiness.sh" ]] \
  || fail "missing script/check_app_store_archive_readiness.sh"
[[ -f "$ROOT_DIR/script/resolve_app_store_entitlements.py" ]] \
  || fail "missing script/resolve_app_store_entitlements.py"
[[ -f "$ENTITLEMENTS" ]] || fail "missing AppStore.entitlements"
[[ -f "$SAFARI_EXTENSION_ENTITLEMENTS" ]] \
  || fail "missing SafariWebExtension.entitlements"
plutil -lint "$ENTITLEMENTS" >/dev/null || fail "AppStore.entitlements is invalid"
plutil -lint "$SAFARI_EXTENSION_ENTITLEMENTS" >/dev/null \
  || fail "SafariWebExtension.entitlements is invalid"

if [[ "$DRY_RUN" == "1" ]]; then
  missing=()
  [[ -n "$APPLICATION_IDENTITY" ]] || missing+=(APP_STORE_APPLICATION_IDENTITY)
  [[ -n "$INSTALLER_IDENTITY" ]] || missing+=(APP_STORE_INSTALLER_IDENTITY)
  [[ -n "$PROVISIONING_PROFILE" ]] || missing+=(APP_STORE_PROVISIONING_PROFILE)
  [[ -n "$SAFARI_EXTENSION_PROVISIONING_PROFILE" ]] \
    || missing+=(APP_STORE_SAFARI_EXTENSION_PROVISIONING_PROFILE)
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "app store package: packaging path is present; configure before signing: ${missing[*]}"
  else
    echo "app store package: packaging path and required environment variables are present"
  fi
  exit 0
fi

bash "$ROOT_DIR/script/check_repository_source_boundary.sh" --release >/dev/null \
  || fail "distribution packaging requires a clean committed Git checkout"
[[ -n "$APPLICATION_IDENTITY" ]] || fail "APP_STORE_APPLICATION_IDENTITY is required"
[[ -n "$INSTALLER_IDENTITY" ]] || fail "APP_STORE_INSTALLER_IDENTITY is required"
[[ -f "$PROVISIONING_PROFILE" ]] || fail "APP_STORE_PROVISIONING_PROFILE does not point to a file"
[[ -f "$SAFARI_EXTENSION_PROVISIONING_PROFILE" ]] \
  || fail "APP_STORE_SAFARI_EXTENSION_PROVISIONING_PROFILE does not point to a file"

security find-identity -v -p codesigning | grep -F -- "$APPLICATION_IDENTITY" >/dev/null \
  || fail "application signing identity is not available in the current keychain"
security find-identity -v | grep -F -- "$INSTALLER_IDENTITY" >/dev/null \
  || fail "installer signing identity is not available in the current keychain"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/personal-site-publisher-app-store.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
profile_plist="$tmp_dir/profile.plist"
resolved_entitlements="$tmp_dir/resolved-entitlements.plist"
safari_profile_plist="$tmp_dir/safari-profile.plist"
resolved_safari_entitlements="$tmp_dir/resolved-safari-entitlements.plist"
security cms -D -i "$PROVISIONING_PROFILE" >"$profile_plist" \
  || fail "could not decode the provisioning profile"
security cms -D -i "$SAFARI_EXTENSION_PROVISIONING_PROFILE" >"$safari_profile_plist" \
  || fail "could not decode the Safari extension provisioning profile"

python3 "$ROOT_DIR/script/resolve_app_store_entitlements.py" \
  "$profile_plist" "$ENTITLEMENTS" "$resolved_entitlements" "$BUNDLE_ID"
python3 "$ROOT_DIR/script/resolve_app_store_entitlements.py" \
  "$safari_profile_plist" \
  "$SAFARI_EXTENSION_ENTITLEMENTS" \
  "$resolved_safari_entitlements" \
  "$SAFARI_EXTENSION_BUNDLE_ID"

version_values="$(bash "$ROOT_DIR/script/check_build_version.sh" --print-values)"
IFS=$'\t' read -r marketing_version build_number <<<"$version_values"
artifact_base="$APP_NAME-$marketing_version-$build_number"
signed_app="$OUTPUT_DIR/$artifact_base.app"
installer_pkg="$OUTPUT_DIR/$artifact_base.pkg"
hash_file="$OUTPUT_DIR/$artifact_base.sha256"

mkdir -p "$OUTPUT_DIR"
for artifact_path in "$signed_app" "$installer_pkg" "$hash_file"; do
  case "$artifact_path" in
    "$OUTPUT_DIR"/*) ;;
    *) fail "artifact path escaped output directory: $artifact_path" ;;
  esac
done
rm -rf "$signed_app"
rm -f "$installer_pkg" "$hash_file"
bash "$ROOT_DIR/script/build_and_run.sh" --package-only --app-store >/dev/null
ditto "$ROOT_DIR/dist/$APP_NAME.app" "$signed_app"
cp "$PROVISIONING_PROFILE" "$signed_app/Contents/embedded.provisionprofile"
safari_extension="$signed_app/Contents/PlugIns/RepoPressSafariExtension.appex"
[[ -d "$safari_extension" ]] || fail "built app is missing the Safari Web Extension"
cp "$SAFARI_EXTENSION_PROVISIONING_PROFILE" \
  "$safari_extension/Contents/embedded.provisionprofile"
# Downloaded provisioning profiles commonly carry com.apple.quarantine. App
# Store processing rejects any extended file attribute embedded in the package,
# so remove inherited attributes before sealing the final code signature.
xattr -cr "$signed_app"

codesign --force --options runtime --timestamp \
  --entitlements "$resolved_safari_entitlements" \
  --sign "$APPLICATION_IDENTITY" "$safari_extension"
codesign --verify --strict --verbose=2 "$safari_extension"
codesign --force --options runtime --timestamp \
  --entitlements "$resolved_entitlements" \
  --sign "$APPLICATION_IDENTITY" "$signed_app"
codesign --verify --deep --strict --verbose=2 "$signed_app"

profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")"
safari_profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$safari_profile_plist")"
signed_team="$(codesign -dv --verbose=4 "$signed_app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
safari_signed_team="$(codesign -dv --verbose=4 "$safari_extension" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
[[ -n "$signed_team" ]] || fail "signed app does not expose a TeamIdentifier"
[[ -n "$safari_signed_team" ]] \
  || fail "signed Safari Web Extension does not expose a TeamIdentifier"
[[ "$signed_team" == "$profile_team" ]] \
  || fail "application signing certificate team does not match the provisioning profile"
[[ "$safari_profile_team" == "$profile_team" ]] \
  || fail "Safari extension provisioning profile team does not match the app profile"
[[ "$safari_signed_team" == "$profile_team" ]] \
  || fail "Safari extension signing certificate team does not match the app profile"

bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --app-bundle "$signed_app"
productbuild --component "$signed_app" /Applications \
  --sign "$INSTALLER_IDENTITY" "$installer_pkg"
pkgutil --check-signature "$installer_pkg" >/dev/null \
  || fail "installer package signature verification failed"

safari_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$safari_extension/Contents/Info.plist")"
shasum -a 256 \
  "$signed_app/Contents/MacOS/$APP_NAME" \
  "$safari_extension/Contents/MacOS/$safari_executable" \
  "$installer_pkg" \
  >"$hash_file"

echo "app store package: signed app $signed_app"
echo "app store package: signed installer $installer_pkg"
echo "app store package: hashes $hash_file"
