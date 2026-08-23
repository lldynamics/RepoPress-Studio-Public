#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORTER="$ROOT_DIR/script/export_public_snapshot.sh"
CHECKER="$ROOT_DIR/script/check_public_snapshot.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repopress-public-snapshot.XXXXXX" 2>/dev/null || mktemp -d "$ROOT_DIR/.build/tmp/repopress-public-snapshot.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "public snapshot export test: $*" >&2
  exit 1
}

SNAPSHOT_DIR="$TMP_DIR/snapshot"
source_changes="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)"
if [[ -n "$source_changes" ]]; then
  if bash "$EXPORTER" "$SNAPSHOT_DIR" >/dev/null 2>&1; then
    fail "dirty source export must require an explicit opt-in"
  fi
else
  bash "$EXPORTER" "$SNAPSHOT_DIR" >/dev/null
fi
rm -rf "$SNAPSHOT_DIR"
bash "$EXPORTER" --allow-dirty "$SNAPSHOT_DIR" >/dev/null

[[ -f "$SNAPSHOT_DIR/README.md" ]] || fail "public README was not installed"
cmp -s "$ROOT_DIR/README.public.md" "$SNAPSHOT_DIR/README.md" \
  || fail "public README differs from its reviewed template"
cmp -s "$ROOT_DIR/LICENSE" "$SNAPSHOT_DIR/LICENSE" \
  || fail "public license differs from the reviewed MPL-2.0 text"
cmp -s "$ROOT_DIR/TRADEMARKS.md" "$SNAPSHOT_DIR/TRADEMARKS.md" \
  || fail "public trademark policy differs from its reviewed source"
[[ -f "$SNAPSHOT_DIR/Sources/PersonalSitePublisherMac/Support/ThinRedScroller.swift" ]] \
  || fail "current untracked source files were not included"
[[ ! -e "$SNAPSHOT_DIR/RELEASE_CHECKLIST.md" ]] \
  || fail "internal release checklist was exported"
[[ ! -e "$SNAPSHOT_DIR/APP_STORE_CHECKLIST.md" ]] \
  || fail "legacy internal App Store checklist was exported"
[[ ! -e "$SNAPSHOT_DIR/docs/release-screenshots" ]] \
  || fail "release screenshots were exported"
[[ ! -e "$SNAPSHOT_DIR/docs/app-store-screenshots" ]] \
  || fail "legacy App Store screenshots were exported"
[[ ! -e "$SNAPSHOT_DIR/docs/private-release" ]] \
  || fail "private release material was exported"
[[ ! -e "$SNAPSHOT_DIR/docs/release-evidence" ]] \
  || fail "internal release evidence was exported"
[[ ! -e "$SNAPSHOT_DIR/BrowserExtension/release-ledger.json" ]] \
  || fail "browser release ledger was exported"
[[ ! -e "$SNAPSHOT_DIR/.git" ]] || fail "private Git history was exported"

bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null
git -C "$SNAPSHOT_DIR" init -q
bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null \
  || fail "a clean public Git repository should pass after initialization"

printf '\nlocal modification\n' >>"$SNAPSHOT_DIR/LICENSE"
if bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null 2>&1; then
  fail "a modified MPL-2.0 license text must fail the public snapshot gate"
fi
cp "$ROOT_DIR/LICENSE" "$SNAPSHOT_DIR/LICENSE"

rm "$SNAPSHOT_DIR/TRADEMARKS.md"
if bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null 2>&1; then
  fail "a missing trademark policy must fail the public snapshot gate"
fi
cp "$ROOT_DIR/TRADEMARKS.md" "$SNAPSHOT_DIR/TRADEMARKS.md"

printf 'not-a-real-secret\n' >"$SNAPSHOT_DIR/.env"
if bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null 2>&1; then
  fail "credential files must fail the public snapshot gate"
fi
rm -f "$SNAPSHOT_DIR/.env"

mkdir -p "$SNAPSHOT_DIR/docs/release-screenshots"
printf 'unreviewed image\n' >"$SNAPSHOT_DIR/docs/release-screenshots/private.png"
if bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null 2>&1; then
  fail "unreviewed screenshot paths must fail the public snapshot gate"
fi
rm -rf "$SNAPSHOT_DIR/docs/release-screenshots"

ln -s README.md "$SNAPSHOT_DIR/local-link"
if bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null 2>&1; then
  fail "symbolic links must fail the public snapshot gate"
fi
rm -f "$SNAPSHOT_DIR/local-link"

mkdir -p "$SNAPSHOT_DIR/Sources/.build"
printf 'generated\n' >"$SNAPSHOT_DIR/Sources/.build/marker.txt"
if bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null 2>&1; then
  fail "nested build directories must fail the public snapshot gate"
fi
rm -rf "$SNAPSHOT_DIR/Sources/.build"

synthetic_secret='sk-public-gate-regression-1234567890'
printf 'let accidentalCredential = "%s"\n' "$synthetic_secret" \
  >"$SNAPSHOT_DIR/Sources/PublicGateSecret.swift"
secret_output="$TMP_DIR/secret-gate-output.txt"
if bash "$CHECKER" "$SNAPSHOT_DIR" >"$secret_output" 2>&1; then
  fail "unapproved credential-like content must fail the public snapshot gate"
fi
if grep -Fq "$synthetic_secret" "$secret_output"; then
  fail "public snapshot gate must not echo suspected secret values"
fi
grep -Fq 'Sources/PublicGateSecret.swift:1' "$secret_output" \
  || fail "public snapshot gate should report a sanitized file and line reference"
rm -f "$SNAPSHOT_DIR/Sources/PublicGateSecret.swift"

git -C "$SNAPSHOT_DIR" config user.email "public-gate@example.invalid"
git -C "$SNAPSHOT_DIR" config user.name "Public Gate Test"
git -C "$SNAPSHOT_DIR" add -A
git -C "$SNAPSHOT_DIR" commit -qm "public baseline"
mkdir -p "$SNAPSHOT_DIR/docs/release-screenshots"
printf 'historical private image\n' >"$SNAPSHOT_DIR/docs/release-screenshots/private.png"
git -C "$SNAPSHOT_DIR" add -A
git -C "$SNAPSHOT_DIR" commit -qm "add private fixture"
rm -rf "$SNAPSHOT_DIR/docs/release-screenshots"
git -C "$SNAPSHOT_DIR" add -A
git -C "$SNAPSHOT_DIR" commit -qm "remove private fixture"
if bash "$CHECKER" "$SNAPSHOT_DIR" >/dev/null 2>&1; then
  fail "private paths reachable from Git history must fail the public snapshot gate"
fi

mkdir -p "$TMP_DIR/nonempty"
printf 'occupied\n' >"$TMP_DIR/nonempty/file.txt"
if bash "$EXPORTER" --allow-dirty "$TMP_DIR/nonempty" >/dev/null 2>&1; then
  fail "export must reject a non-empty destination"
fi

echo "public snapshot export test: passed"
