#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_ROOT="${BROWSER_EXTENSION_GATE_CACHE_ROOT:-$ROOT_DIR/.build/browser-extension-gate-cache}"
RUNTIME_HOME="${HOME:?}"

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$RUNTIME_HOME/Library/Caches/ms-playwright}"

export XDG_CACHE_HOME="$CACHE_ROOT/xdg"
export CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang"
export SWIFT_MODULE_CACHE_PATH="$CACHE_ROOT/swift"
export HOME="$CACHE_ROOT/home"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

cd "$ROOT_DIR"

python3 script/check_node_toolchain_security.py
python3 script/generate_browser_extension_protocol.py --check
bash script/sync_firefox_browser_extension.sh --check
bash script/sync_safari_browser_extension.sh --check
bash script/build_safari_web_extension.sh --check
python3 script/browser_extension_release_ledger.py check
python3 script/test_browser_extension_release_ledger.py
python3 script/chromium_extension_release.py check
node script/test_browser_extension_compatibility.mjs
node script/test_browser_extension_e2e.mjs --browser=chromium
node script/test_browser_extension_e2e.mjs --browser=firefox

swift build --disable-sandbox --product PersonalSitePublisherMac
swift test --disable-sandbox --filter KnowledgeBrowserImportOperationLedgerTests
swift test --disable-sandbox --filter KnowledgeLibraryServiceTests.testBrowserDuplicateResolutionSupportsVersionMoveCopyAndCancelWithoutSilentMutation

echo "Safari Web Extension, Chrome, Firefox, and authenticated loopback release gate: passed"
