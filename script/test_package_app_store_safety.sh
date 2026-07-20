#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/script/package_app_store.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/app-store-package-safety.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "app store package safety test: $*" >&2
  exit 1
}

for unsafe_dir in / "$HOME" "$ROOT_DIR" "$ROOT_DIR/dist"; do
  if bash "$PACKAGE_SCRIPT" --dry-run --output-dir "$unsafe_dir" >/dev/null 2>&1; then
    fail "accepted unsafe output directory: $unsafe_dir"
  fi
done

safe_output="$(bash "$PACKAGE_SCRIPT" --dry-run --output-dir "$TMP_DIR/output" 2>&1)" \
  || fail "rejected isolated output directory"
grep -q "packaging path" <<<"$safe_output" \
  || fail "safe dry-run did not report packaging workflow availability"

if grep -Fq 'rm -rf "$OUTPUT_DIR"' "$PACKAGE_SCRIPT"; then
  fail "package script still removes the entire caller-provided output directory"
fi

grep -Fq 'xattr -cr "$signed_app"' "$PACKAGE_SCRIPT" \
  || fail "package script does not strip App Store-rejected extended attributes before signing"

python3 "$ROOT_DIR/script/test_resolve_app_store_entitlements.py"

echo "app store package safety test: passed"
