#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${PRIVACY_SUPPORT_ROOT:-$ROOT_DIR}"
COPY_FILE="${PRIVACY_SUPPORT_COPY_FILE:-$PROJECT_ROOT/docs/privacy-support-copy.md}"
PUBLIC_DIR="$PROJECT_ROOT/docs/public-pages"
PRIVACY_ZH="$PUBLIC_DIR/privacy-zh-Hans.html"
PRIVACY_EN="$PUBLIC_DIR/privacy-en.html"
SUPPORT_ZH="$PUBLIC_DIR/support-zh-Hans.html"
SUPPORT_EN="$PUBLIC_DIR/support-en.html"
COPY_FILES=(
  "$COPY_FILE"
  "$PRIVACY_ZH"
  "$PRIVACY_EN"
  "$SUPPORT_ZH"
  "$SUPPORT_EN"
)

fail() {
  echo "privacy support copy gate: $*" >&2
  exit 1
}

require_terms() {
  local file="$1"
  local label="$2"
  shift 2
  local term=""
  local missing=()

  for term in "$@"; do
    if ! grep -Fqi "$term" "$file"; then
      missing+=("$term")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    fail "$label is missing required direct-distribution coverage: ${missing[*]}"
  fi
}

for file in "${COPY_FILES[@]}"; do
  [[ -f "$file" ]] || fail "required privacy/support file is missing: $file"
done

require_terms "$COPY_FILE" "docs/privacy-support-copy.md" \
  "free" \
  "official website" \
  "Developer ID" \
  "BYOK" \
  "custom HTTPS endpoint" \
  "local loopback" \
  "explicit consent" \
  "API keys are stored in macOS Keychain" \
  "developer does not proxy or receive" \
  "localhost" \
  "127.0.0.1:17843" \
  "Safari Web Extension" \
  "Chrome Web Store" \
  "Sparkle" \
  "server access logs" \
  "IP address" \
  "request time" \
  "requested path" \
  "response status" \
  "user agent" \
  "Quick Hide" \
  "does not encrypt local data" \
  "Private-content masking" \
  "local paths" \
  "access tokens" \
  "authorization headers" \
  "private article body text" \
  "redacted screenshots"

require_terms "$PRIVACY_EN" "English public privacy page" \
  "free" \
  "official RepoPress Studio website" \
  "Developer ID" \
  "BYOK" \
  "custom remote API" \
  "explicit consent" \
  "developer does not proxy or receive" \
  "localhost" \
  "127.0.0.1:17843" \
  "macOS Keychain" \
  "Safari Web Extension" \
  "Chrome Web Store" \
  "Sparkle" \
  "server access logs" \
  "IP address" \
  "user agent or app version"

require_terms "$SUPPORT_EN" "English public support page" \
  "free from the official website" \
  "Developer ID" \
  "BYOK" \
  "custom remote API" \
  "explicit consent" \
  "developer does not proxy or receive" \
  "localhost" \
  "127.0.0.1:17843" \
  "macOS Keychain" \
  "Safari Web Extension" \
  "Chrome Web Store" \
  "Sparkle" \
  "server access logs" \
  "IP address" \
  "user agent or app version"

require_terms "$PRIVACY_ZH" "Chinese public privacy page" \
  "免费" \
  "官方网站" \
  "Developer ID" \
  "BYOK" \
  "自定义远程 API" \
  "明确同意" \
  "开发者不转发也不接收" \
  "localhost" \
  "127.0.0.1:17843" \
  "macOS Keychain" \
  "Safari Web Extension" \
  "Chrome 网上应用店" \
  "Sparkle" \
  "服务器访问日志" \
  "IP 地址" \
  "User-Agent 或应用版本"

require_terms "$SUPPORT_ZH" "Chinese public support page" \
  "官方网站免费下载" \
  "Developer ID" \
  "BYOK" \
  "自定义远程 API" \
  "明确同意" \
  "开发者不转发也不接收" \
  "localhost" \
  "127.0.0.1:17843" \
  "macOS Keychain" \
  "Safari Web Extension" \
  "Chrome 网上应用店" \
  "Sparkle" \
  "服务器访问日志" \
  "IP 地址" \
  "User-Agent 或应用版本"

for file in "${COPY_FILES[@]}"; do
  if grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/)' "$file"; then
    fail "public copy contains a local filesystem path: $(basename "$file")"
  fi
  if grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})' "$file"; then
    fail "public copy contains token-like or authorization-header content: $(basename "$file")"
  fi
done

for file in "$PRIVACY_ZH" "$PRIVACY_EN" "$SUPPORT_ZH" "$SUPPORT_EN"; do
  grep -Fqi '<!doctype html>' "$file" || fail "public page has no HTML doctype: $file"
  grep -Fqi '</html>' "$file" || fail "public page is incomplete: $file"
done

echo "privacy support copy gate: free website distribution, BYOK consent, browser loopback, Sparkle update logging, and redaction boundaries verified"
