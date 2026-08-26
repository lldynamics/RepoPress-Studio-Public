#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/script/check_browser_extension_release.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/browser-extension-release-gate.XXXXXX" 2>/dev/null || mktemp -d "$ROOT_DIR/.build/tmp/browser-extension-release-gate.XXXXXX")"
FIXTURE_ROOT="$TMP_DIR/project"
LOG_PATH="$TMP_DIR/commands.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "browser extension release gate test: $*" >&2
  exit 1
}

mkdir -p "$FIXTURE_ROOT/script" "$FIXTURE_ROOT/bin" "$FIXTURE_ROOT/.build/debug"
cp "$CHECK" "$FIXTURE_ROOT/script/check_browser_extension_release.sh"

cat >"$FIXTURE_ROOT/script/check_node_toolchain_security.py" <<'PY'
#!/usr/bin/env python3
import os

with open(os.environ["COMMAND_LOG"], "a", encoding="utf-8") as handle:
    handle.write("node-security\n")
if os.environ.get("FAIL_STAGE") == "node-security":
    raise SystemExit(1)
PY

cat >"$FIXTURE_ROOT/script/generate_browser_extension_protocol.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

with open(os.environ["COMMAND_LOG"], "a", encoding="utf-8") as handle:
    handle.write("protocol-generation:" + " ".join(sys.argv[1:]) + "\n")
if os.environ.get("FAIL_STAGE") == "protocol-generation":
    raise SystemExit(1)
PY

cat >"$FIXTURE_ROOT/script/build_browser_extension_source.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

with open(os.environ["COMMAND_LOG"], "a", encoding="utf-8") as handle:
    handle.write("source-build:" + " ".join(sys.argv[1:]) + "\n")
if os.environ.get("FAIL_STAGE") == "source-build":
    raise SystemExit(1)
PY

cat >"$FIXTURE_ROOT/script/test_browser_extension_source_layout.py" <<'PY'
#!/usr/bin/env python3
import os

with open(os.environ["COMMAND_LOG"], "a", encoding="utf-8") as handle:
    handle.write("source-layout-tests\n")
if os.environ.get("FAIL_STAGE") == "source-layout-tests":
    raise SystemExit(1)
PY

cat >"$FIXTURE_ROOT/script/browser_extension_release_ledger.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

with open(os.environ["COMMAND_LOG"], "a", encoding="utf-8") as handle:
    handle.write("release-ledger:" + " ".join(sys.argv[1:]) + "\n")
if os.environ.get("FAIL_STAGE") == "release-ledger":
    raise SystemExit(1)
PY

cat >"$FIXTURE_ROOT/script/test_browser_extension_release_ledger.py" <<'PY'
#!/usr/bin/env python3
import os

with open(os.environ["COMMAND_LOG"], "a", encoding="utf-8") as handle:
    handle.write("release-ledger-tests\n")
if os.environ.get("FAIL_STAGE") == "release-ledger-tests":
    raise SystemExit(1)
PY

cat >"$FIXTURE_ROOT/script/chromium_extension_release.py" <<'PY'
#!/usr/bin/env python3
import os
import sys

with open(os.environ["COMMAND_LOG"], "a", encoding="utf-8") as handle:
    handle.write("chromium-store-release:" + " ".join(sys.argv[1:]) + "\n")
if os.environ.get("FAIL_STAGE") == "chromium-store-release":
    raise SystemExit(1)
PY

cat >"$FIXTURE_ROOT/script/sync_firefox_browser_extension.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "firefox-sync:$*" >>"$COMMAND_LOG"
[[ "${FAIL_STAGE:-}" != "firefox-sync" ]]
STUB
chmod +x "$FIXTURE_ROOT/script/sync_firefox_browser_extension.sh"

for script_name in \
  test_browser_extension_compatibility.mjs \
  test_browser_extension_e2e.mjs; do
  : >"$FIXTURE_ROOT/script/$script_name"
done

cat >"$FIXTURE_ROOT/bin/node" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
stage="${1##*/}"
shift
echo "node:$stage:$*" >>"$COMMAND_LOG"
[[ "${FAIL_STAGE:-}" != "$stage" ]]
STUB
chmod +x "$FIXTURE_ROOT/bin/node"

cat >"$FIXTURE_ROOT/bin/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "swift:$*" >>"$COMMAND_LOG"
if [[ "$*" == *"--show-bin-path"* ]]; then
  echo "$FIXTURE_SWIFT_BIN_DIR"
fi
[[ "${FAIL_STAGE:-}" != "swift-${1:-}" ]]
STUB
chmod +x "$FIXTURE_ROOT/bin/swift"

COMMAND_LOG="$LOG_PATH" \
FIXTURE_SWIFT_BIN_DIR="$FIXTURE_ROOT/.build/debug" \
PATH="$FIXTURE_ROOT/bin:$PATH" \
bash "$FIXTURE_ROOT/script/check_browser_extension_release.sh" >/dev/null \
  || fail "complete fixture should pass"

grep -Fq "node:test_browser_extension_compatibility.mjs:" "$LOG_PATH" \
  || fail "browser compatibility test was omitted"
grep -Fq "node-security" "$LOG_PATH" \
  || fail "Node dependency security check was omitted"
grep -Fq "node:test_browser_extension_e2e.mjs:--browser=chromium" "$LOG_PATH" \
  || fail "real-browser extension E2E test was omitted"
grep -Fq "node:test_browser_extension_e2e.mjs:--browser=firefox" "$LOG_PATH" \
  || fail "Firefox real-browser extension E2E test was omitted"
grep -Fq "protocol-generation:--check" "$LOG_PATH" \
  || fail "cross-language protocol generation check was omitted"
grep -Fq "source-build:--browser chrome --check" "$LOG_PATH" \
  || fail "Chrome shared-source layout check was omitted"
grep -Fq "source-layout-tests" "$LOG_PATH" \
  || fail "shared-source layout behavior tests were omitted"
grep -Fq "firefox-sync:--check" "$LOG_PATH" \
  || fail "Firefox shared-resource synchronization check was omitted"
grep -Fq "release-ledger:check" "$LOG_PATH" \
  || fail "immutable browser extension release ledger check was omitted"
grep -Fq "release-ledger-tests" "$LOG_PATH" \
  || fail "immutable browser extension release ledger tests were omitted"
grep -Fq "chromium-store-release:check" "$LOG_PATH" \
  || fail "Chrome reproducible store package check was omitted"
grep -Fq "swift:build --disable-sandbox --product PersonalSitePublisherMac" "$LOG_PATH" \
  || fail "application product was not built"
grep -Fq "swift:test --disable-sandbox --filter KnowledgeBrowserImportOperationLedgerTests" "$LOG_PATH" \
  || fail "browser import idempotency tests were omitted"
grep -Fq "swift:test --disable-sandbox --filter KnowledgeLibraryServiceTests.testBrowserDuplicateResolutionSupportsVersionMoveCopyAndCancelWithoutSilentMutation" "$LOG_PATH" \
  || fail "browser duplicate resolution mutation tests were omitted"

: >"$LOG_PATH"
if COMMAND_LOG="$LOG_PATH" \
  FIXTURE_SWIFT_BIN_DIR="$FIXTURE_ROOT/.build/debug" \
  FAIL_STAGE="node-security" \
  PATH="$FIXTURE_ROOT/bin:$PATH" \
  bash "$FIXTURE_ROOT/script/check_browser_extension_release.sh" >/dev/null 2>&1; then
  fail "Node dependency security failure was not propagated"
fi
if grep -Fq "protocol-generation" "$LOG_PATH"; then
  fail "gate continued after the Node dependency security check failed"
fi

: >"$LOG_PATH"
if COMMAND_LOG="$LOG_PATH" \
  FIXTURE_SWIFT_BIN_DIR="$FIXTURE_ROOT/.build/debug" \
  FAIL_STAGE="release-ledger" \
  PATH="$FIXTURE_ROOT/bin:$PATH" \
  bash "$FIXTURE_ROOT/script/check_browser_extension_release.sh" >/dev/null 2>&1; then
  fail "immutable release ledger failure was not propagated"
fi
if grep -Fq "chromium-store-release" "$LOG_PATH"; then
  fail "gate continued after the immutable release ledger check failed"
fi

: >"$LOG_PATH"
if COMMAND_LOG="$LOG_PATH" \
  FIXTURE_SWIFT_BIN_DIR="$FIXTURE_ROOT/.build/debug" \
  FAIL_STAGE="chromium-store-release" \
  PATH="$FIXTURE_ROOT/bin:$PATH" \
  bash "$FIXTURE_ROOT/script/check_browser_extension_release.sh" >/dev/null 2>&1; then
  fail "Chromium store release failure was not propagated"
fi
if grep -Fq "test_browser_extension_compatibility.mjs" "$LOG_PATH"; then
  fail "gate continued after the Chromium store release check failed"
fi

: >"$LOG_PATH"
if COMMAND_LOG="$LOG_PATH" \
  FIXTURE_SWIFT_BIN_DIR="$FIXTURE_ROOT/.build/debug" \
  FAIL_STAGE="test_browser_extension_e2e.mjs" \
  PATH="$FIXTURE_ROOT/bin:$PATH" \
  bash "$FIXTURE_ROOT/script/check_browser_extension_release.sh" >/dev/null 2>&1; then
  fail "real-browser extension E2E failure was not propagated"
fi
if grep -Fq "swift:build" "$LOG_PATH"; then
  fail "gate continued after the real-browser extension E2E test failed"
fi

: >"$LOG_PATH"
echo "browser extension release gate test: passed"
