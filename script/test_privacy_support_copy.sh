#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-privacy-copy.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "privacy support copy test: $*" >&2
  exit 1
}

make_fixture() {
  mkdir -p \
    "$TMP_DIR/docs" \
    "$TMP_DIR/Sources/PublishingWorkbenchCore/Models" \
    "$TMP_DIR/Sources/PersonalSitePublisherMac/App" \
    "$TMP_DIR/Sources/PersonalSitePublisherMac/Views" \
    "$TMP_DIR/Tests/PublishingWorkbenchCoreTests"

  cat >"$TMP_DIR/docs/privacy-support-copy.md" <<'DOC'
# Privacy And Support Copy Review

Manual quick hide covers workbench content until the user returns.
Private-content masking hides private article titles from list and release surfaces.
Do not include local paths, access tokens, authorization headers, or private article body text in support requests.
Use redacted screenshots for support. Online publishing, repository API requests, deployment checks, and StoreKit may contact external services.
External AI assistance is optional and available to every user without RepoPress Pro. The app does not meter AI requests. It requires explicit consent before the first request to each remote endpoint. API keys are stored in macOS Keychain. Requests go directly to the selected provider; the developer does not proxy or receive the key or AI content. RepoPress Pro unlocks online publishing and batch publishing only.
Browser extensions use authenticated browser capture through 127.0.0.1:17843. Chrome, Edge, and Firefox are not claimed as public features of this submission. The app does not install a Native Messaging helper.
DOC

  cat >"$TMP_DIR/Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift" <<'SWIFT'
let masksPrivateContent = true
let checklist = "工作台隐藏时禁用设置项"
SWIFT

  cat >"$TMP_DIR/Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" <<'SWIFT'
struct ProtectedSettingsView {
  let disabledRule = ".disabled(!store.canUseProtectedWorkbench)"
  let overlay = "PrivacyLockOverlay(store: store)"
}
SWIFT

  cat >"$TMP_DIR/Sources/PersonalSitePublisherMac/Views/ContentView.swift" <<'SWIFT'
let overlay = "PrivacyLockOverlay(store: store)"
let command = "快速隐藏"
SWIFT

  cat >"$TMP_DIR/Sources/PersonalSitePublisherMac/Views/SharedViews.swift" <<'SWIFT'
let identifier = "privacy-lock-overlay"
SWIFT

  cat >"$TMP_DIR/Tests/PublishingWorkbenchCoreTests/SEOAuditServiceTests.swift" <<'SWIFT'
let testName = "私密文章不输出预览图"
SWIFT
}

make_fixture

PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null

printf '\n/Users/example/site\n' >>"$TMP_DIR/docs/privacy-support-copy.md"
if PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null 2>&1; then
  fail "gate accepted local filesystem path"
fi

make_fixture
printf '\nghp_abcdefghijklmnopqrstuvwxyz\n' >>"$TMP_DIR/docs/privacy-support-copy.md"
if PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null 2>&1; then
  fail "gate accepted token-like content"
fi

make_fixture
perl -0pi -e 's/Private-content masking//g' "$TMP_DIR/docs/privacy-support-copy.md"
if PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null 2>&1; then
  fail "gate accepted copy missing private-content masking coverage"
fi

make_fixture
perl -0pi -e 's/explicit consent//g' "$TMP_DIR/docs/privacy-support-copy.md"
if PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null 2>&1; then
  fail "gate accepted AI support copy without explicit consent"
fi

make_fixture
printf '\nAI requires RepoPress Pro.\n' >>"$TMP_DIR/docs/privacy-support-copy.md"
if PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null 2>&1; then
  fail "gate accepted copy that put AI behind Pro"
fi

make_fixture
perl -0pi -e 's/masksPrivateContent//g' "$TMP_DIR/Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift"
if PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null 2>&1; then
  fail "gate accepted missing source behavior"
fi

make_fixture
perl -0pi -e 's/ProtectedSettingsView//g' "$TMP_DIR/Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift"
if PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null 2>&1; then
  fail "gate accepted missing protected settings wrapper"
fi

make_fixture
perl -0pi -e 's/\.disabled\(!store\.canUseProtectedWorkbench\)//g' "$TMP_DIR/Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift"
if PRIVACY_SUPPORT_ROOT="$TMP_DIR" bash "$ROOT_DIR/script/check_privacy_support_copy.sh" >/dev/null 2>&1; then
  fail "gate accepted unlocked settings controls"
fi

echo "privacy support copy test: passed"
