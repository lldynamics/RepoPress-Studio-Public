#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_DIR="$ROOT_DIR/Sources/PersonalSitePublisherMac/Resources"
PACKAGE_FILE="$ROOT_DIR/Package.swift"
CATALOG_FILE="$RESOURCE_DIR/Localizable.xcstrings"

fail() {
  echo "localization gate: $*" >&2
  exit 1
}

[[ -f "$PACKAGE_FILE" ]] || fail "Package.swift is missing"
grep -q 'defaultLocalization: "zh-Hans"' "$PACKAGE_FILE" || fail "Package.swift must declare defaultLocalization: \"zh-Hans\""
[[ -f "$CATALOG_FILE" ]] || fail "Localizable.xcstrings is missing"
# String catalogs are JSON. `plutil -lint` rejects valid `.xcstrings` JSON on
# some macOS toolchain versions, so validate the catalog with the JSON parser.
python3 -m json.tool "$CATALOG_FILE" >/dev/null || fail "Localizable.xcstrings is invalid"

required_info_plist_keys=(CFBundleDisplayName CFBundleName)
required_localizable_keys=(
  app.name
  workspace.writing
  workspace.siteStarter
  workspace.sync
  workspace.images
  workspace.contentHealth
  workspace.ai
  workspace.generalDrafts
  workspace.maintenance
  workspace.releaseHistory
  workspace.releaseReadiness
  releaseGate.title
  releaseGate.localization
  releaseGate.runtime
  releaseGate.screenshots
  releaseGate.appStore
  releaseGate.productReadiness
)

for language in zh-Hans en; do
  info_plist_file="$RESOURCE_DIR/$language.lproj/InfoPlist.strings"
  [[ -f "$info_plist_file" ]] || fail "$language InfoPlist.strings is missing"
  plutil -lint "$info_plist_file" >/dev/null || fail "$info_plist_file has invalid .strings syntax"

  for required_key in "${required_info_plist_keys[@]}"; do
    grep -Eq "^[[:space:]]*\"$required_key\"[[:space:]]*=" "$info_plist_file" \
      || fail "$language InfoPlist.strings is missing $required_key"
  done
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

catalog_key_count="$(python3 - "$CATALOG_FILE" "${required_localizable_keys[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    strings = json.load(handle).get("strings", {})

missing = []
for key in sys.argv[2:]:
    entry = strings.get(key, {})
    for language in ("zh-Hans", "en"):
        value = entry.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value", "")
        if not value.strip():
            missing.append(f"{key}:{language}")

if missing:
    print("missing catalog translations: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)

print(len(strings))
PY
)"
[[ "$catalog_key_count" -gt 0 ]] || fail "Localizable.xcstrings does not contain any source keys"

xcrun xcstringstool compile "$CATALOG_FILE" --output-directory "$TMP_DIR/compiled"
for language in zh-Hans en; do
  compiled_file="$TMP_DIR/compiled/$language.lproj/Localizable.strings"
  [[ -f "$compiled_file" ]] || fail "xcstringstool did not produce $language Localizable.strings"
  plutil -lint "$compiled_file" >/dev/null || fail "compiled $language Localizable.strings is invalid"
done

python3 "$ROOT_DIR/script/sync_ui_localizations.py" --check \
  || fail "SwiftUI strings are missing complete zh-Hans/en catalog coverage"

echo "localization gate: xcstrings has $catalog_key_count translated source keys and compiles for zh-Hans/en; InfoPlist metadata is valid"
