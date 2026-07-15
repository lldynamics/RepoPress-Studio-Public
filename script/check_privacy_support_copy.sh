#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${PRIVACY_SUPPORT_ROOT:-$ROOT_DIR}"
COPY_FILE="${PRIVACY_SUPPORT_COPY_FILE:-$PROJECT_ROOT/docs/privacy-support-copy.md}"

fail() {
  echo "privacy support copy gate: $*" >&2
  exit 1
}

[[ -f "$COPY_FILE" ]] || fail "docs/privacy-support-copy.md is missing"

text="$(cat "$COPY_FILE")"

required_terms=(
  "quick hide"
  "Private-content masking"
  "private article titles"
  "local paths"
  "access tokens"
  "authorization headers"
  "private article body text"
  "support requests"
  "redacted screenshots"
  "online publishing"
  "AI requests"
  "StoreKit"
)

missing_terms=()
for term in "${required_terms[@]}"; do
  if ! grep -Fqi "$term" "$COPY_FILE"; then
    missing_terms+=("$term")
  fi
done

if [[ "${#missing_terms[@]}" -gt 0 ]]; then
  fail "copy is missing required coverage: ${missing_terms[*]}"
fi

if grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/)' "$COPY_FILE"; then
  fail "copy contains a local filesystem path"
fi

if grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})' "$COPY_FILE"; then
  fail "copy contains token-like or authorization-header content"
fi

privacy_model="$PROJECT_ROOT/Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift"
app_file="$PROJECT_ROOT/Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift"
content_view="$PROJECT_ROOT/Sources/PersonalSitePublisherMac/Views/ContentView.swift"
shared_views="$PROJECT_ROOT/Sources/PersonalSitePublisherMac/Views/SharedViews.swift"
seo_tests="$PROJECT_ROOT/Tests/PublishingWorkbenchCoreTests/SEOAuditServiceTests.swift"

[[ -f "$privacy_model" ]] || fail "PrivacyProtectionModels.swift is missing"
[[ -f "$app_file" ]] || fail "PersonalSitePublisherMacApp.swift is missing"
[[ -f "$content_view" ]] || fail "ContentView.swift is missing"
[[ -f "$shared_views" ]] || fail "SharedViews.swift is missing"
[[ -f "$seo_tests" ]] || fail "SEOAuditServiceTests.swift is missing"

grep -Fq "masksPrivateContent" "$privacy_model" || fail "privacy model does not expose private-content masking"
grep -Fq "工作台隐藏时" "$privacy_model" || fail "privacy checklist does not cover hidden workbench behavior"
grep -Fq "ProtectedSettingsView" "$app_file" || fail "settings scene is not wrapped in a protected settings view"
grep -Fq ".disabled(!store.canUseProtectedWorkbench)" "$app_file" || fail "settings content is not disabled while privacy locked"
grep -Fq "PrivacyLockOverlay(store: store)" "$app_file" || fail "settings scene does not show the privacy lock overlay"
grep -Fq "PrivacyLockOverlay(store: store)" "$content_view" || fail "main workbench does not show the privacy lock overlay"
grep -Fq "快速隐藏" "$content_view" || fail "content view does not expose manual quick hide"
grep -Fq "privacy-lock-overlay" "$shared_views" || fail "privacy lock overlay is missing accessibility identifier"
grep -Fq "私密文章不输出预览图" "$seo_tests" || fail "private SEO/social preview suppression test is missing"

echo "privacy support copy gate: privacy/support copy, source behavior, and redaction rules verified"
