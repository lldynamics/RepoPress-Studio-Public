#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_ID="personal.site.publisher.pro"
STOREKIT_DIR="$ROOT_DIR/StoreKit"

fail() {
  echo "storekit gate: $*" >&2
  exit 1
}

[[ -d "$STOREKIT_DIR" ]] || fail "StoreKit directory is missing"

storekit_files="$(find "$STOREKIT_DIR" -maxdepth 1 -type f -name '*.storekit' | sort)"
[[ -n "$storekit_files" ]] || fail "no .storekit configuration file found"

if ! grep -R -q "\"productID\"[[:space:]]*:[[:space:]]*\"$PRODUCT_ID\"" "$STOREKIT_DIR"; then
  fail "product ID $PRODUCT_ID is missing from StoreKit configuration"
fi

if ! grep -R -q "\"nonConsumables\"" "$STOREKIT_DIR"; then
  fail "StoreKit configuration does not define a non-consumable Pro product"
fi

if ! grep -R -q '"displayPrice"[[:space:]]*:[[:space:]]*"[^"]' "$STOREKIT_DIR"; then
  fail "StoreKit configuration does not define a display price for $PRODUCT_ID"
fi

for locale in en_US zh_Hans; do
  if ! grep -R -q "\"locale\"[[:space:]]*:[[:space:]]*\"$locale\"" "$STOREKIT_DIR"; then
    fail "StoreKit configuration is missing $locale localization"
  fi
done

for field in displayName description; do
  if ! grep -R -q "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]" "$STOREKIT_DIR"; then
    fail "StoreKit configuration is missing localized $field"
  fi
done

SWIFT_BUILD_HOME="${SWIFT_BUILD_HOME:-/private/tmp/personal-site-publisher-swift-home}"
export HOME="$SWIFT_BUILD_HOME"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$HOME/.swift-clang-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$HOME/.swift-module-cache}"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

# Product metadata is a file-format contract. Purchase, restore, entitlement,
# and free-plan boundaries are proved by behavior tests instead of source-name
# markers, so file moves and method renames cannot create a false pass.
behavior_tests=(
  MonetizationTests.testStatusSummaryShowsUnlockedStoreKitEntitlement
  MonetizationTests.testProSandboxVerificationSummaryIsVerifiedForCheckedStoreKitEntitlement
  MonetizationTests.testSilentStoreKitEntitlementCheckUpdatesTimestampWithoutUserMessage
)
for test_name in "${behavior_tests[@]}"; do
  swift test --filter "$test_name" --disable-sandbox >/dev/null \
    || fail "StoreKit behavior regression test failed: $test_name"
done

echo "storekit gate: product $PRODUCT_ID metadata and ${#behavior_tests[@]} StoreKit behavior tests passed"
