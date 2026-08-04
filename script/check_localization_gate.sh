#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_DIR="$ROOT_DIR/Sources/PersonalSitePublisherMac/Resources"
CORE_RESOURCE_DIR="$ROOT_DIR/Sources/PublishingWorkbenchCore/Resources"
PACKAGE_FILE="$ROOT_DIR/Package.swift"
CATALOG_FILE="$RESOURCE_DIR/Localizable.xcstrings"

# Scope: app-target SwiftUI/literal localization calls, semantic model keys,
# and presentation strings explicitly migrated through CoreL10n.

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

if grep -R -Fq 'Locale(identifier: "zh_Hans_CN")' "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views"; then
  fail "user-facing dates must follow the current locale instead of forcing zh_Hans_CN"
fi
grep -Fq '.locale(.autoupdatingCurrent)' \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/SiteMaintenanceCalendarSection.swift" \
  || fail "maintenance calendar titles must use the current locale"
grep -Fq 'calendar.locale = .autoupdatingCurrent' \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/SiteMaintenanceCalendarSection.swift" \
  || fail "maintenance calendar weekdays must use the current locale"

required_info_plist_keys=(CFBundleDisplayName CFBundleName)
required_localizable_keys=(
  app.name
  workspace.writing
  workspace.rss
  workspace.siteStarter
  workspace.sync
  workspace.images
  workspace.contentHealth
)

for language in zh-Hans en; do
  info_plist_file="$RESOURCE_DIR/$language.lproj/InfoPlist.strings"
  [[ -f "$info_plist_file" ]] || fail "$language InfoPlist.strings is missing"
  plutil -lint "$info_plist_file" >/dev/null || fail "$info_plist_file has invalid .strings syntax"

  for required_key in "${required_info_plist_keys[@]}"; do
    grep -Eq "^[[:space:]]*\"$required_key\"[[:space:]]*=" "$info_plist_file" \
      || fail "$language InfoPlist.strings is missing $required_key"
  done

  core_strings_file="$CORE_RESOURCE_DIR/$language.lproj/Localizable.strings"
  [[ -f "$core_strings_file" ]] || fail "$language Core Localizable.strings is missing"
  plutil -lint "$core_strings_file" >/dev/null || fail "$core_strings_file has invalid .strings syntax"
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

python3 "$ROOT_DIR/script/test_sync_ui_localizations.py" \
  || fail "localization extraction regression tests failed"

python3 "$ROOT_DIR/script/sync_ui_localizations.py" --check \
  || fail "declared UI-scope keys are missing complete zh-Hans/en catalog coverage"

echo "localization gate: UI scope has $catalog_key_count translated catalog keys and compiles for zh-Hans/en; InfoPlist metadata is valid"
echo "localization gate: migrated PublishingWorkbenchCore presentation keys compile and have matching zh-Hans/en placeholders"
