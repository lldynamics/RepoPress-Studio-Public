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

display_name_count="$(grep -R -c '"displayName"[[:space:]]*:[[:space:]]*"RepoPress Pro"' "$STOREKIT_DIR" | awk -F: '{ total += $NF } END { print total + 0 }')"
[[ "$display_name_count" -ge 2 ]] \
  || fail "StoreKit configuration must localize the product name as RepoPress Pro"

if grep -R -Eq 'Personal Site Publisher|Personal Site Publishing Console|个人网站写作与发布|个人网站发布控制台' "$STOREKIT_DIR"; then
  fail "StoreKit configuration still contains the retired product name"
fi

python3 - "$STOREKIT_DIR" "$PRODUCT_ID" <<'PY' || fail "StoreKit product metadata is invalid"
import json
import re
import sys
from pathlib import Path

storekit_dir = Path(sys.argv[1])
product_id = sys.argv[2]
products = []
for path in sorted(storekit_dir.glob("*.storekit")):
    payload = json.loads(path.read_text(encoding="utf-8"))
    products.extend(payload.get("nonConsumables", []))

matches = [product for product in products if product.get("productID") == product_id]
if len(matches) != 1:
    raise SystemExit(f"expected one {product_id} product, found {len(matches)}")

localizations = matches[0].get("localizations", [])
by_locale = {item.get("locale"): item for item in localizations}
for locale in ("en_US", "zh_Hans"):
    item = by_locale.get(locale)
    if not item:
        raise SystemExit(f"missing {locale} localization")
    if item.get("displayName") != "RepoPress Pro":
        raise SystemExit(f"{locale} display name must be RepoPress Pro")
    description = item.get("description", "")
    if not description or len(description) > 45:
        raise SystemExit(f"{locale} description must contain 1 to 45 characters")
    if re.search(r"\bAI\b|artificial intelligence|browser (?:capture|extension)|浏览器插件|浏览器采集", description, re.IGNORECASE):
        raise SystemExit(f"{locale} description must not present AI or browser capture as a Pro purchase benefit")
PY

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
  MonetizationTests.testProEntitlementAllowsPremiumFeaturesWithoutConsumingFreeUsage
  MonetizationTests.testSilentStoreKitEntitlementCheckUpdatesTimestampWithoutUserMessage
)
for test_name in "${behavior_tests[@]}"; do
  swift test --filter "$test_name" --disable-sandbox >/dev/null \
    || fail "StoreKit behavior regression test failed: $test_name"
done

echo "storekit gate: product $PRODUCT_ID metadata and ${#behavior_tests[@]} StoreKit behavior tests passed"
