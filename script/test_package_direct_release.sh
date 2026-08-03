#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/repopress-direct-release-test.XXXXXX)"
FIXTURE_ROOT="$TMP_DIR/project"
BIN_DIR="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "direct release package test: $*" >&2
  exit 1
}

mkdir -p \
  "$FIXTURE_ROOT/Packaging/ThirdPartyNotices" \
  "$FIXTURE_ROOT/script" \
  "$BIN_DIR"
cp "$ROOT_DIR/Packaging/DirectDistribution.entitlements" "$FIXTURE_ROOT/Packaging/"
cp "$ROOT_DIR/Packaging/SafariWebExtension.entitlements" "$FIXTURE_ROOT/Packaging/"
cp "$ROOT_DIR/Packaging/ThirdPartyNotices/Sparkle-LICENSE.txt" \
  "$FIXTURE_ROOT/Packaging/ThirdPartyNotices/"
cp "$ROOT_DIR/script/sign_sparkle_framework.sh" "$FIXTURE_ROOT/script/"
cp "$ROOT_DIR/script/generate_direct_appcast.sh" "$FIXTURE_ROOT/script/"
cat >"$FIXTURE_ROOT/Packaging/Downloader.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST

cat >"$FIXTURE_ROOT/Packaging/BuildVersion.xcconfig" <<'CONFIG'
MARKETING_VERSION = 1.2
CURRENT_PROJECT_VERSION = 3
CONFIG

cat >"$FIXTURE_ROOT/script/check_build_version.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--print-values" ]] || exit 2
printf '1.2\t3\n'
STUB

cat >"$FIXTURE_ROOT/script/check_repository_source_boundary.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--release" ]] || exit 2
echo "fixture source boundary: clean"
STUB

cat >"$FIXTURE_ROOT/script/build_and_run.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *" --package-only "* ]] || exit 2
[[ " $* " == *" --direct "* ]] || exit 2
app="${PERSONAL_SITE_PUBLISHER_DIST_DIR:?}/PersonalSitePublisherMac.app"
rm -rf "$app"
safari="$app/Contents/PlugIns/RepoPressSafariExtension.appex"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle/Versions/B"
mkdir -p \
  "$app/Contents/MacOS" \
  "$app/Contents/Resources/ThirdPartyNotices" \
  "$safari/Contents/MacOS" \
  "$sparkle_version/XPCServices/Installer.xpc" \
  "$sparkle_version/XPCServices/Downloader.xpc" \
  "$sparkle_version/Updater.app"
printf '#!/usr/bin/env bash\nexit 0\n' >"$app/Contents/MacOS/PersonalSitePublisherMac"
printf '#!/usr/bin/env bash\nexit 0\n' >"$safari/Contents/MacOS/RepoPressSafariExtension"
chmod +x \
  "$app/Contents/MacOS/PersonalSitePublisherMac" \
  "$safari/Contents/MacOS/RepoPressSafariExtension"
cp "${DIRECT_TEST_ROOT:?}/Packaging/ThirdPartyNotices/Sparkle-LICENSE.txt" \
  "$app/Contents/Resources/ThirdPartyNotices/"
for executable in \
  "$sparkle_version/XPCServices/Installer.xpc/fixture" \
  "$sparkle_version/XPCServices/Downloader.xpc/fixture" \
  "$sparkle_version/Autoupdate" \
  "$sparkle_version/Updater.app/fixture" \
  "$sparkle_version/Sparkle"; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$executable"
  chmod +x "$executable"
done
ln -s B "$sparkle/Versions/Current"
ln -s Versions/Current/Sparkle "$sparkle/Sparkle"
ln -s Versions/Current/Autoupdate "$sparkle/Autoupdate"
ln -s Versions/Current/Updater.app "$sparkle/Updater.app"
ln -s Versions/Current/XPCServices "$sparkle/XPCServices"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jinfang.PersonalSitePublisherMac</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>PersonalSitePublisherDistributionChannel</key><string>Direct</string>
  <key>SUEnableInstallerLauncherService</key><true/>
  <key>SUFeedURL</key><string>${REPOPRESS_UPDATE_FEED_URL:-}</string>
  <key>SUPublicEDKey</key><string>${REPOPRESS_UPDATE_PUBLIC_ED_KEY:-}</string>
  <key>RepoPressUpdateChannel</key><string>${REPOPRESS_UPDATE_CHANNEL:-stable}</string>
</dict></plist>
PLIST
cat >"$safari/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jinfang.PersonalSitePublisherMac.SafariExtension</string>
  <key>CFBundleExecutable</key><string>RepoPressSafariExtension</string>
</dict></plist>
PLIST
STUB

cat >"$BIN_DIR/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
arguments=" $* "
target="${!#}"
if [[ -n "${CODESIGN_LOG:-}" && "$arguments" == *" --sign "* ]]; then
  printf '%s\n' "$*" >>"$CODESIGN_LOG"
fi
if [[ "$arguments" == *" --sign "* && "$target" == *.dmg && -n "${DMG_SIGN_MARKER:-}" ]]; then
  : >"$DMG_SIGN_MARKER"
fi
if [[ "$arguments" == *" -d "* && "$arguments" == *" --entitlements "* ]]; then
  if [[ "$target" == *Downloader.xpc ]]; then
    cat "${DIRECT_TEST_ROOT:?}/Packaging/Downloader.entitlements"
  elif [[ "$target" == *.appex ]]; then
    cat "${DIRECT_TEST_ROOT:?}/Packaging/SafariWebExtension.entitlements"
  else
    cat "${DIRECT_TEST_ROOT:?}/Packaging/DirectDistribution.entitlements"
  fi
  exit 0
fi
if [[ "$arguments" == *" -dv "* ]]; then
  team="TEAM123456"
  if [[ "$target" == *.dmg ]]; then
    team="${DMG_TEAM_IDENTIFIER:-TEAM123456}"
  fi
  printf '%s\n' \
    'Executable=fixture' \
    'Identifier=fixture' \
    'CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+1 location=embedded' \
    "Authority=Developer ID Application: Fixture ($team)" \
    "TeamIdentifier=$team" >&2
  exit 0
fi
exit 0
STUB

cat >"$BIN_DIR/security" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo '  1) FIXTUREHASH "Developer ID Application: Fixture (TEAM123456)"'
echo '     1 valid identities found'
STUB

cat >"$BIN_DIR/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-f" ]]; then
  echo "/fixture/${2:-tool}"
  exit 0
fi
if [[ "${1:-}" == "notarytool" && "${2:-}" == "submit" ]]; then
  artifact="${3:-unknown}"
  status="${NOTARY_STATUS:-Accepted}"
  if [[ "$artifact" == *.dmg ]]; then
    [[ -f "${DMG_SIGN_MARKER:?}" ]] || {
      echo "fixture DMG reached notarization before Developer ID signing" >&2
      exit 3
    }
    printf '{"id":"fixture-dmg-submission","status":"%s"}\n' "$status"
  else
    printf '{"id":"fixture-app-submission","status":"%s"}\n' "$status"
  fi
  exit 0
fi
if [[ "${1:-}" == "stapler" ]]; then
  exit 0
fi
exit 2
STUB

cat >"$BIN_DIR/hdiutil" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
output="${!#}"
printf 'fixture notarized dmg\n' >"$output"
STUB

cat >"$BIN_DIR/spctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exit 0
STUB

cat >"$BIN_DIR/generate_appcast" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
output=""
prefix=""
channel="stable"
archive_dir="${!#}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --download-url-prefix) prefix="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    --account|--maximum-deltas) shift 2 ;;
    *) shift ;;
  esac
done
zip_path="$(find "$archive_dir" -maxdepth 1 -name '*.zip' -print -quit)"
zip_name="$(basename "$zip_path")"
if [[ "$channel" == "beta" ]]; then
  channel_xml='<sparkle:channel>beta</sparkle:channel>'
else
  channel_xml=''
fi
cat >"$archive_dir/$output" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
<channel><item>${channel_xml}<enclosure url="${prefix}${zip_name}" sparkle:version="3" sparkle:edSignature="fixture-signature" /></item></channel>
</rss>
XML
STUB

cat >"$BIN_DIR/generate_keys" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *" -p "* ]] || exit 2
printf '%s\n' "${FIXTURE_SPARKLE_PUBLIC_KEY:-fixture-public-ed-key}"
STUB

chmod +x "$FIXTURE_ROOT/script/"*.sh "$BIN_DIR/"*
cat >"$FIXTURE_ROOT/.gitignore" <<'IGNORE'
artifacts/
dist/
IGNORE
git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" \
  -c user.name="Direct Release Fixture" \
  -c user.email="fixture@example.invalid" \
  commit -qm "fixture"

common_environment=(
  "DIRECT_DISTRIBUTION_ROOT=$FIXTURE_ROOT"
  "DIRECT_TEST_ROOT=$FIXTURE_ROOT"
  "CODESIGN_TOOL=$BIN_DIR/codesign"
  "HDIUTIL_TOOL=$BIN_DIR/hdiutil"
  "SECURITY_TOOL=$BIN_DIR/security"
  "SPCTL_TOOL=$BIN_DIR/spctl"
  "XCRUN_TOOL=$BIN_DIR/xcrun"
  "SPARKLE_GENERATE_APPCAST_TOOL=$BIN_DIR/generate_appcast"
  "SPARKLE_GENERATE_KEYS_TOOL=$BIN_DIR/generate_keys"
  "CODESIGN_LOG=$TMP_DIR/codesign.log"
  "DMG_SIGN_MARKER=$TMP_DIR/dmg-signed.marker"
)
identity="Developer ID Application: Fixture (TEAM123456)"

dry_output="$(env "${common_environment[@]}" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
  --dry-run --output-dir "$FIXTURE_ROOT/artifacts/dry")"
grep -Fq "configure before release" <<<"$dry_output" \
  || fail "dry-run did not clearly report missing credentials"
grep -Fq "did not build, sign, contact Apple, or prove notarization" <<<"$dry_output" \
  || fail "dry-run overstated its evidence"

if env "${common_environment[@]}" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
    --dry-run --output-dir "$FIXTURE_ROOT" >/dev/null 2>&1; then
  fail "unsafe output directory was accepted"
fi

env "${common_environment[@]}" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
  --prepare --output-dir "$FIXTURE_ROOT/artifacts/prepare" >/dev/null
prepared_app="$FIXTURE_ROOT/artifacts/prepare/prepared-RepoPress-Studio-1.2-3/RepoPress Studio.app"
[[ -x "$prepared_app/Contents/MacOS/PersonalSitePublisherMac" ]] \
  || fail "prepare mode did not create the inspection app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherDistributionChannel' \
  "$prepared_app/Contents/Info.plist")" == "Direct" ]] \
  || fail "prepare mode did not preserve the Direct channel marker"
[[ -s "$prepared_app/Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt" ]] \
  || fail "prepare mode omitted the Sparkle third-party notice"

release_output="$FIXTURE_ROOT/artifacts/release"
if mismatch_output="$(env "${common_environment[@]}" \
  DIRECT_DISTRIBUTION_APPLICATION_IDENTITY="$identity" \
  DIRECT_DISTRIBUTION_NOTARY_PROFILE="Fixture-Notary" \
  REPOPRESS_UPDATE_FEED_URL="https://updates.example.invalid/stable-appcast.xml" \
  REPOPRESS_UPDATE_PUBLIC_ED_KEY="wrong-public-key" \
  REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX="https://updates.example.invalid/downloads" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
    --release --output-dir "$FIXTURE_ROOT/artifacts/key-mismatch" 2>&1)"; then
  fail "release mode accepted a public key that does not match the Keychain account"
fi
grep -Fq "does not match the Keychain private key account" <<<"$mismatch_output" \
  || fail "public-key mismatch failed without an explicit diagnostic"

env "${common_environment[@]}" \
  DIRECT_DISTRIBUTION_APPLICATION_IDENTITY="$identity" \
  DIRECT_DISTRIBUTION_NOTARY_PROFILE="Fixture-Notary" \
  REPOPRESS_UPDATE_FEED_URL="https://updates.example.invalid/stable-appcast.xml" \
  REPOPRESS_UPDATE_PUBLIC_ED_KEY="fixture-public-ed-key" \
  REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX="https://updates.example.invalid/downloads" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
    --release --output-dir "$release_output" >/dev/null

artifact_base="RepoPress-Studio-1.2-3"
signed_app="$release_output/$artifact_base/RepoPress Studio.app"
zip_path="$release_output/$artifact_base-macOS.zip"
dmg_path="$release_output/$artifact_base-macOS.dmg"
manifest_path="$release_output/$artifact_base-manifest.json"
checksum_path="$release_output/$artifact_base.sha256"
appcast_path="$release_output/stable-appcast.xml"
for artifact in "$signed_app" "$zip_path" "$dmg_path" "$manifest_path" "$checksum_path" "$appcast_path"; do
  [[ -e "$artifact" ]] || fail "release mode omitted $artifact"
done
sparkle_notice="$signed_app/Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt"
[[ -s "$sparkle_notice" ]] || fail "release mode omitted the Sparkle third-party notice"

python3 - "$TMP_DIR/codesign.log" <<'PY'
from pathlib import Path
import sys

lines = [line for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if " --sign " in f" {line} "]
targets = [line.split()[-1] for line in lines]
expected = ["Installer.xpc", "Downloader.xpc", "Autoupdate", "Updater.app", "Sparkle.framework"]
if len(targets) < len(expected) or any(not target.endswith(suffix) for target, suffix in zip(targets, expected)):
    raise SystemExit(f"unexpected Sparkle signing order: {targets}")
if "--entitlements" not in lines[1]:
    raise SystemExit("Downloader.xpc was re-signed without retained entitlements")
if any("--deep" in line for line in lines):
    raise SystemExit("nested code was re-signed with --deep")
dmg_lines = [line for line in lines if line.split()[-1].endswith(".dmg")]
if len(dmg_lines) != 1:
    raise SystemExit(f"expected exactly one DMG signing operation: {dmg_lines}")
dmg_line = dmg_lines[0]
for required in ("--force", "--timestamp", "--sign"):
    if required not in dmg_line:
        raise SystemExit(f"DMG signing omitted {required}: {dmg_line}")
if "--options" in dmg_line or "--deep" in dmg_line:
    raise SystemExit(f"DMG signing used an inappropriate nested-code option: {dmg_line}")
PY

python3 - "$manifest_path" <<'PY'
import json
from pathlib import Path
import sys

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["schemaVersion"] == 1, payload
assert payload["product"]["distributionChannel"] == "Direct", payload
assert payload["product"]["marketingVersion"] == "1.2", payload
assert payload["product"]["buildNumber"] == "3", payload
assert payload["signing"]["kind"] == "Developer ID Application", payload
assert payload["signing"]["teamIdentifier"] == "TEAM123456", payload
assert payload["signing"]["hardenedRuntime"] is True, payload
assert payload["notarization"]["app"]["status"] == "Accepted", payload
assert payload["notarization"]["dmg"]["status"] == "Accepted", payload
assert payload["updates"]["channel"] == "stable", payload
assert payload["artifacts"]["appcast"]["path"] == "stable-appcast.xml", payload
assert payload["source"]["isDirty"] is False, payload
assert payload["reproducibility"]["byteForByteReproducible"] is False, payload
PY

env "${common_environment[@]}" \
  DIRECT_DISTRIBUTION_APP_BUNDLE_PATH="$signed_app" \
  DIRECT_DISTRIBUTION_DMG_PATH="$dmg_path" \
  DIRECT_DISTRIBUTION_ZIP_PATH="$zip_path" \
  DIRECT_DISTRIBUTION_MANIFEST_PATH="$manifest_path" \
  DIRECT_DISTRIBUTION_CHECKSUM_PATH="$checksum_path" \
  DIRECT_DISTRIBUTION_APPCAST_PATH="$appcast_path" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
    --validate --output-dir "$release_output" >/dev/null

mv "$sparkle_notice" "$sparkle_notice.missing"
if missing_notice_output="$(env "${common_environment[@]}" \
  DIRECT_DISTRIBUTION_APP_BUNDLE_PATH="$signed_app" \
  DIRECT_DISTRIBUTION_DMG_PATH="$dmg_path" \
  DIRECT_DISTRIBUTION_ZIP_PATH="$zip_path" \
  DIRECT_DISTRIBUTION_MANIFEST_PATH="$manifest_path" \
  DIRECT_DISTRIBUTION_CHECKSUM_PATH="$checksum_path" \
  DIRECT_DISTRIBUTION_APPCAST_PATH="$appcast_path" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
    --validate --output-dir "$release_output" 2>&1)"; then
  fail "validate mode accepted an app without the Sparkle third-party notice"
fi
grep -Fq "Sparkle third-party notice is missing" <<<"$missing_notice_output" \
  || fail "missing Sparkle notice failed without an explicit diagnostic"
mv "$sparkle_notice.missing" "$sparkle_notice"

if dmg_team_output="$(env "${common_environment[@]}" \
  DMG_TEAM_IDENTIFIER="OTHERTEAM1" \
  DIRECT_DISTRIBUTION_APP_BUNDLE_PATH="$signed_app" \
  DIRECT_DISTRIBUTION_DMG_PATH="$dmg_path" \
  DIRECT_DISTRIBUTION_ZIP_PATH="$zip_path" \
  DIRECT_DISTRIBUTION_MANIFEST_PATH="$manifest_path" \
  DIRECT_DISTRIBUTION_CHECKSUM_PATH="$checksum_path" \
  DIRECT_DISTRIBUTION_APPCAST_PATH="$appcast_path" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
    --validate --output-dir "$release_output" 2>&1)"; then
  fail "validate mode accepted a DMG signed by a different team"
fi
grep -Fq "app and DMG signatures use different teams" <<<"$dmg_team_output" \
  || fail "DMG team mismatch failed without an explicit diagnostic"

beta_appcast="$FIXTURE_ROOT/artifacts/beta-appcast.xml"
env "${common_environment[@]}" \
  REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX="https://updates.example.invalid/downloads" \
  REPOPRESS_UPDATE_PUBLIC_ED_KEY="fixture-public-ed-key" \
  REPOPRESS_UPDATE_CHANNEL="beta" \
  bash "$ROOT_DIR/script/generate_direct_appcast.sh" \
    --archive "$zip_path" --output "$beta_appcast" >/dev/null
grep -Fq '<sparkle:channel>beta</sparkle:channel>' "$beta_appcast" \
  || fail "beta appcast omitted its beta channel"
if grep -Fq '<sparkle:channel>stable</sparkle:channel>' "$appcast_path"; then
  fail "stable appcast incorrectly carries a stable channel"
fi

invalid_output="$FIXTURE_ROOT/artifacts/rejected"
if rejection_output="$(env "${common_environment[@]}" \
  DIRECT_DISTRIBUTION_APPLICATION_IDENTITY="$identity" \
  DIRECT_DISTRIBUTION_NOTARY_PROFILE="Fixture-Notary" \
  REPOPRESS_UPDATE_FEED_URL="https://updates.example.invalid/stable-appcast.xml" \
  REPOPRESS_UPDATE_PUBLIC_ED_KEY="fixture-public-ed-key" \
  REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX="https://updates.example.invalid/downloads" \
  NOTARY_STATUS="Invalid" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
    --release --output-dir "$invalid_output" 2>&1)"; then
  fail "release mode accepted a rejected notarization result"
fi
grep -Fq "did not return Accepted" <<<"$rejection_output" \
  || fail "rejected notarization failed without an explicit status error"

if env "${common_environment[@]}" \
  bash "$ROOT_DIR/script/package_direct_release.sh" \
    --validate --output-dir "$release_output" >/dev/null 2>&1; then
  fail "validate mode accepted an omitted artifact set"
fi

echo "direct release package test: passed"
