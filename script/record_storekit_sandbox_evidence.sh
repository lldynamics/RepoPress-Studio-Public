#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_MANIFEST_HELPER="$ROOT_DIR/script/release_evidence_source_manifest.py"
PRODUCT_ID="${STOREKIT_PRODUCT_ID:-personal.site.publisher.pro}"
STOREKIT_DIR="${STOREKIT_DIR:-$ROOT_DIR/StoreKit}"
EVIDENCE_FILE="${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
PURCHASE_SUMMARY=""
RESTORE_SUMMARY=""
FREE_QUOTA_SUMMARY=""
BOUNDARY_EVENTS_SUMMARY=""
PRODUCT_LOOKUP_SUMMARY=""
EVIDENCE_URL=""
EXECUTE=0

usage() {
  cat <<'USAGE'
Usage: script/record_storekit_sandbox_evidence.sh --product-lookup <text> --purchase <text> --restore <text> --free-quota <text> --boundary-events <text> --execute
       script/record_storekit_sandbox_evidence.sh --dry-run

Records the StoreKit sandbox external evidence item through the shared evidence
recorder. The script verifies the local StoreKit product configuration during
dry-run, but --execute requires a product lookup summary from a real App Store
sandbox run. Product lookup, purchase, restore, free quota, and boundary event
summaries must come from a real sandbox run and should be short, redacted text.

Options:
  --purchase <text>       Sandbox purchase result and entitlement source.
  --restore <text>        Sandbox restore result after clearing local state.
  --free-quota <text>     Free quota boundary before/after Pro unlock.
  --boundary-events <text> Free-plan block and Pro no-quota event summary.
  --product-lookup <text> Sandbox product lookup result.
  --evidence-url <url>    Optional HTTPS evidence URL.
  --execute               Write docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md.
  --dry-run               Validate readiness without writing.
USAGE
}

fail() {
  echo "storekit sandbox evidence: $*" >&2
  exit 1
}

reject_private_content() {
  local value="$1"
  local label="$2"
  if printf "%s" "$value" | grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/)'; then
    fail "$label contains a local filesystem path"
  fi
  if printf "%s" "$value" | grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})'; then
    fail "$label contains a token-like secret"
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --purchase)
      [[ "$#" -ge 2 ]] || fail "--purchase requires text"
      PURCHASE_SUMMARY="$2"
      shift 2
      ;;
    --restore)
      [[ "$#" -ge 2 ]] || fail "--restore requires text"
      RESTORE_SUMMARY="$2"
      shift 2
      ;;
    --free-quota)
      [[ "$#" -ge 2 ]] || fail "--free-quota requires text"
      FREE_QUOTA_SUMMARY="$2"
      shift 2
      ;;
    --boundary-events)
      [[ "$#" -ge 2 ]] || fail "--boundary-events requires text"
      BOUNDARY_EVENTS_SUMMARY="$2"
      shift 2
      ;;
    --product-lookup)
      [[ "$#" -ge 2 ]] || fail "--product-lookup requires text"
      PRODUCT_LOOKUP_SUMMARY="$2"
      shift 2
      ;;
    --evidence-url)
      [[ "$#" -ge 2 ]] || fail "--evidence-url requires an HTTPS URL"
      EVIDENCE_URL="$2"
      shift 2
      ;;
    --execute)
      EXECUTE=1
      shift
      ;;
    --dry-run)
      EXECUTE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$EVIDENCE_FILE" ]] || fail "evidence file is missing: ${EVIDENCE_FILE#$ROOT_DIR/}"

bash "$ROOT_DIR/script/check_storekit.sh" >/dev/null

require_source_pattern() {
  local relative_path="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -R -q "$pattern" "$ROOT_DIR/$relative_path"; then
    fail "missing local StoreKit coverage: $label"
  fi
}

require_source_pattern_any_file() {
  local pattern="$1"
  local label="$2"
  shift 2
  local relative_path
  for relative_path in "$@"; do
    if [[ -f "$ROOT_DIR/$relative_path" ]] && grep -q "$pattern" "$ROOT_DIR/$relative_path"; then
      return 0
    fi
  done
  fail "missing local StoreKit coverage: $label"
}

require_source_pattern_source_manifest() {
  local relative_path="$1"
  local pattern="$2"
  local label="$3"
  local expanded_paths=()
  local expanded_path
  while IFS= read -r expanded_path; do
    expanded_paths+=("$expanded_path")
  done < <(python3 "$SOURCE_MANIFEST_HELPER" "$relative_path" "$pattern")
  require_source_pattern_any_file "$pattern" "$label" "${expanded_paths[@]}"
}

require_source_pattern "Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift" "Product.products(for: \\[productID\\])" "StoreKit product lookup"
require_source_pattern "Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift" "product.purchase()" "StoreKit purchase entry point"
require_source_pattern "Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift" "AppStore.sync()" "StoreKit restore entry point"
require_source_pattern "Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift" "Transaction.currentEntitlements" "StoreKit entitlement refresh"
require_source_pattern "Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift" "externalVerificationEvidenceMarkdown" "StoreKit external evidence export"
require_source_pattern_source_manifest \
  "Sources/PersonalSitePublisherMac/Views/SettingsView.swift" \
  "copyProSandboxEvidence" \
  "StoreKit external evidence copy UI"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift" "testStatusSummaryShowsUnlockedStoreKitEntitlement" "StoreKit entitlement status regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift" "testProSandboxVerificationSummaryIsVerifiedForCheckedStoreKitEntitlement" "StoreKit sandbox verification regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift" "testProSandboxVerificationSummaryBuildsExternalEvidenceFields" "StoreKit external evidence regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift" "testProEntitlementAllowsPremiumFeaturesWithoutConsumingFreeUsage" "Pro entitlement free-quota regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift" "testExplicitRestoreWithoutEntitlementKeepsUserFacingMessage" "StoreKit restore-missing-entitlement regression test"

auto_lookup="$(
  python3 - "$STOREKIT_DIR" "$PRODUCT_ID" <<'PY'
from pathlib import Path
import json
import sys

storekit_dir = Path(sys.argv[1])
product_id = sys.argv[2]

for path in sorted(storekit_dir.glob("*.storekit")):
    data = json.loads(path.read_text())
    for product in data.get("nonConsumables", []):
        if product.get("productID") == product_id:
            price = product.get("displayPrice") or "<missing price>"
            locales = sorted(
                loc.get("locale", "")
                for loc in product.get("localizations", [])
                if loc.get("locale")
            )
            names = [
                loc.get("displayName", "")
                for loc in product.get("localizations", [])
                if loc.get("displayName")
            ]
            locale_text = ", ".join(locales) if locales else "<missing locales>"
            name_text = " / ".join(names) if names else product.get("referenceName", product_id)
            print(
                f"Local StoreKit config loaded {product_id} with display price {price}, "
                f"locales {locale_text}, and display names {name_text}."
            )
            sys.exit(0)
raise SystemExit(f"product {product_id} not found in StoreKit configuration")
PY
)"

manual_product_lookup=1
if [[ -z "$PRODUCT_LOOKUP_SUMMARY" ]]; then
  manual_product_lookup=0
  PRODUCT_LOOKUP_SUMMARY="$auto_lookup"
fi

reject_private_content "$PRODUCT_LOOKUP_SUMMARY" "product lookup summary"
if [[ -n "${PURCHASE_SUMMARY//[[:space:]]/}" ]]; then
  reject_private_content "$PURCHASE_SUMMARY" "purchase summary"
fi
if [[ -n "${RESTORE_SUMMARY//[[:space:]]/}" ]]; then
  reject_private_content "$RESTORE_SUMMARY" "restore summary"
fi
if [[ -n "${FREE_QUOTA_SUMMARY//[[:space:]]/}" ]]; then
  reject_private_content "$FREE_QUOTA_SUMMARY" "free quota summary"
fi
if [[ -n "${BOUNDARY_EVENTS_SUMMARY//[[:space:]]/}" ]]; then
  reject_private_content "$BOUNDARY_EVENTS_SUMMARY" "boundary events summary"
fi
if [[ -n "$EVIDENCE_URL" ]]; then
  reject_private_content "$EVIDENCE_URL" "evidence URL"
  [[ "$EVIDENCE_URL" =~ ^https:// ]] || fail "--evidence-url must be https://"
fi

if [[ "$EXECUTE" == "1" ]]; then
  [[ "$manual_product_lookup" == "1" ]] || fail "--product-lookup from an App Store sandbox run is required with --execute"
  [[ -n "${PURCHASE_SUMMARY//[[:space:]]/}" ]] || fail "--purchase is required with --execute"
  [[ -n "${RESTORE_SUMMARY//[[:space:]]/}" ]] || fail "--restore is required with --execute"
  [[ -n "${FREE_QUOTA_SUMMARY//[[:space:]]/}" ]] || fail "--free-quota is required with --execute"
  [[ -n "${BOUNDARY_EVENTS_SUMMARY//[[:space:]]/}" ]] || fail "--boundary-events is required with --execute"
fi

record_args=(
  --item storekit-sandbox
  --summary "StoreKit sandbox purchase, restore, entitlement source, and free quota boundary verified with redacted sandbox evidence."
  --storekit-product-lookup "$PRODUCT_LOOKUP_SUMMARY"
  --storekit-purchase "$PURCHASE_SUMMARY"
  --storekit-restore "$RESTORE_SUMMARY"
  --storekit-free-quota "$FREE_QUOTA_SUMMARY"
  --storekit-boundary-events "$BOUNDARY_EVENTS_SUMMARY"
)

if [[ -n "$EVIDENCE_URL" ]]; then
  record_args+=(--evidence-url "$EVIDENCE_URL")
fi

if [[ "$EXECUTE" == "1" ]]; then
  EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
    bash "$ROOT_DIR/script/record_external_verification_evidence.sh" "${record_args[@]}" --execute
else
  has_all_manual_summaries=0
  if [[ -n "${PURCHASE_SUMMARY//[[:space:]]/}" &&
        -n "${RESTORE_SUMMARY//[[:space:]]/}" &&
        -n "${FREE_QUOTA_SUMMARY//[[:space:]]/}" &&
        -n "${BOUNDARY_EVENTS_SUMMARY//[[:space:]]/}" ]]; then
    has_all_manual_summaries=1
    EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
      bash "$ROOT_DIR/script/record_external_verification_evidence.sh" "${record_args[@]}" --dry-run >/dev/null
  fi

  echo "storekit sandbox evidence: dry-run"
  echo "- local StoreKit config lookup: $auto_lookup"
  echo "- sandbox product lookup summary: $([[ "$manual_product_lookup" == "1" ]] && echo recorded || echo required for --execute)"
  echo "- StoreKit coordinator product lookup: present"
  echo "- StoreKit coordinator purchase entry point: present"
  echo "- StoreKit coordinator restore entry point: present"
  echo "- StoreKit entitlement refresh: present"
  echo "- StoreKit external evidence export: present"
  echo "- StoreKit entitlement status regression test: present"
  echo "- StoreKit sandbox verification regression test: present"
  echo "- StoreKit external evidence regression test: present"
  echo "- Pro entitlement free-quota regression test: present"
  echo "- StoreKit restore-missing-entitlement regression test: present"
  echo "- purchase summary: $([[ -n "${PURCHASE_SUMMARY//[[:space:]]/}" ]] && echo recorded || echo required for --execute)"
  echo "- restore summary: $([[ -n "${RESTORE_SUMMARY//[[:space:]]/}" ]] && echo recorded || echo required for --execute)"
  echo "- free quota summary: $([[ -n "${FREE_QUOTA_SUMMARY//[[:space:]]/}" ]] && echo recorded || echo required for --execute)"
  echo "- boundary events summary: $([[ -n "${BOUNDARY_EVENTS_SUMMARY//[[:space:]]/}" ]] && echo recorded || echo required for --execute)"
  echo "- shared external recorder validation: $([[ "$has_all_manual_summaries" == "1" ]] && echo ready || echo waiting for all manual summaries)"
  echo "- evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"
fi
