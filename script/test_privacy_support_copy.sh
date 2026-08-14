#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-editor-privacy-copy.XXXXXX" 2>/dev/null || mktemp -d "$ROOT_DIR/.build/tmp/mac-editor-privacy-copy.XXXXXX")"
FIXTURE_ROOT="$TMP_DIR/project"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "privacy support copy test: $*" >&2
  exit 1
}

make_fixture() {
  rm -rf "$FIXTURE_ROOT"
  mkdir -p "$FIXTURE_ROOT/docs/app-store/public-pages"
  cp "$ROOT_DIR/docs/privacy-support-copy.md" "$FIXTURE_ROOT/docs/"
  cp "$ROOT_DIR/docs/app-store/public-pages/privacy-zh-Hans.html" \
    "$FIXTURE_ROOT/docs/app-store/public-pages/"
  cp "$ROOT_DIR/docs/app-store/public-pages/privacy-en.html" \
    "$FIXTURE_ROOT/docs/app-store/public-pages/"
  cp "$ROOT_DIR/docs/app-store/public-pages/support-zh-Hans.html" \
    "$FIXTURE_ROOT/docs/app-store/public-pages/"
  cp "$ROOT_DIR/docs/app-store/public-pages/support-en.html" \
    "$FIXTURE_ROOT/docs/app-store/public-pages/"
}

gate_accepts_fixture() {
  PRIVACY_SUPPORT_ROOT="$FIXTURE_ROOT" \
    bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null
}

make_fixture
gate_accepts_fixture

printf '\n/Users/example/private-site\n' >>"$FIXTURE_ROOT/docs/privacy-support-copy.md"
if gate_accepts_fixture 2>/dev/null; then
  fail "gate accepted a local filesystem path"
fi

make_fixture
printf '\nghp_abcdefghijklmnopqrstuvwxyz\n' >>"$FIXTURE_ROOT/docs/privacy-support-copy.md"
if gate_accepts_fixture 2>/dev/null; then
  fail "gate accepted token-like content"
fi

make_fixture
perl -0pi -e 's/Sparkle/Sparkl_/g' \
  "$FIXTURE_ROOT/docs/app-store/public-pages/support-en.html"
if gate_accepts_fixture 2>/dev/null; then
  fail "gate accepted a public support page without Sparkle disclosure"
fi

make_fixture
perl -0pi -e 's/explicit consent/endpoint approval/g' \
  "$FIXTURE_ROOT/docs/app-store/public-pages/privacy-en.html"
if gate_accepts_fixture 2>/dev/null; then
  fail "gate accepted a public privacy page without explicit remote-AI consent"
fi

make_fixture
perl -0pi -e 's/服务器访问日志/更新请求记录/g' \
  "$FIXTURE_ROOT/docs/app-store/public-pages/support-zh-Hans.html"
if gate_accepts_fixture 2>/dev/null; then
  fail "gate accepted Chinese support copy without necessary server-log disclosure"
fi

make_fixture
perl -0pi -e 's/Chrome Web Store/browser extension channel/g' \
  "$FIXTURE_ROOT/docs/app-store/public-pages/privacy-en.html"
if gate_accepts_fixture 2>/dev/null; then
  fail "gate accepted public privacy copy without the Chrome extension boundary"
fi

echo "privacy support copy test: passed"
