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
[[ -f "$CATALOG_FILE" ]] || fail "Localizable.xcstrings is missing; the legacy .strings files cannot prove UI-string coverage"
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
  localizable_file="$RESOURCE_DIR/$language.lproj/Localizable.strings"
  info_plist_file="$RESOURCE_DIR/$language.lproj/InfoPlist.strings"
  [[ -f "$localizable_file" ]] || fail "$language Localizable.strings is missing"
  [[ -f "$info_plist_file" ]] || fail "$language InfoPlist.strings is missing"
  plutil -lint "$localizable_file" >/dev/null || fail "$localizable_file has invalid .strings syntax"
  plutil -lint "$info_plist_file" >/dev/null || fail "$info_plist_file has invalid .strings syntax"

  for required_key in "${required_info_plist_keys[@]}"; do
    grep -Eq "^[[:space:]]*\"$required_key\"[[:space:]]*=" "$info_plist_file" \
      || fail "$language InfoPlist.strings is missing $required_key"
  done

  for required_key in "${required_localizable_keys[@]}"; do
    grep -Eq "^[[:space:]]*\"$required_key\"[[:space:]]*=" "$localizable_file" \
      || fail "$language Localizable.strings is missing $required_key"
  done
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

extract_keys() {
  local file="$1"
  sed -nE 's/^[[:space:]]*"(([^"\\]|\\.)*)"[[:space:]]*=.*/\1/p' "$file"
}

for language in zh-Hans en; do
  file="$RESOURCE_DIR/$language.lproj/Localizable.strings"
  keys_file="$TMP_DIR/$language.keys"
  duplicate_file="$TMP_DIR/$language.duplicates"
  extract_keys "$file" | sort > "$keys_file"
  uniq -d "$keys_file" > "$duplicate_file"
  if [[ -s "$duplicate_file" ]]; then
    echo "localization gate: duplicate keys in $language:" >&2
    sed 's/^/  - /' "$duplicate_file" >&2
    exit 1
  fi
  sort -u "$keys_file" -o "$keys_file"
  [[ -s "$keys_file" ]] || fail "$language Localizable.strings does not contain any keys"
done

missing_in_en="$TMP_DIR/missing-in-en.keys"
missing_in_zh="$TMP_DIR/missing-in-zh.keys"
comm -23 "$TMP_DIR/zh-Hans.keys" "$TMP_DIR/en.keys" > "$missing_in_en"
comm -13 "$TMP_DIR/zh-Hans.keys" "$TMP_DIR/en.keys" > "$missing_in_zh"

if [[ -s "$missing_in_en" || -s "$missing_in_zh" ]]; then
  if [[ -s "$missing_in_en" ]]; then
    echo "localization gate: keys missing in en:" >&2
    sed 's/^/  - /' "$missing_in_en" >&2
  fi
  if [[ -s "$missing_in_zh" ]]; then
    echo "localization gate: keys missing in zh-Hans:" >&2
    sed 's/^/  - /' "$missing_in_zh" >&2
  fi
  exit 1
fi

key_count="$(wc -l < "$TMP_DIR/zh-Hans.keys" | tr -d '[:space:]')"
catalog_key_count="$(python3 - "$CATALOG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(len(json.load(handle).get("strings", {})))
PY
)"
[[ "$catalog_key_count" -gt 0 ]] || fail "Localizable.xcstrings does not contain any source keys"

# A catalog alone is not coverage. UI literals must move to localization keys;
# this deliberately rejects the historical state where a handful of resource
# keys coexisted with hundreds of hard-coded SwiftUI strings.
raw_ui_literal_count="$(rg -g '*.swift' -N '(^|[[:space:]])(Text|Label|Button|Toggle|Section)\("' "$ROOT_DIR/Sources/PersonalSitePublisherMac" | wc -l | tr -d '[:space:]')"
[[ "$raw_ui_literal_count" -eq 0 ]] || fail "found $raw_ui_literal_count hard-coded SwiftUI strings; migrate them to Localizable.xcstrings keys"

echo "localization gate: xcstrings has $catalog_key_count source keys; zh-Hans and en legacy metadata keys match ($key_count)"
