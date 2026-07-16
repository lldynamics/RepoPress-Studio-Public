#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-storekit-evidence.XXXXXX)"
EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
ENV_TEMPLATE="$ROOT_DIR/docs/release-evidence/storekit-sandbox.env.example"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "storekit sandbox evidence test: $*" >&2
  exit 1
}

cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$EVIDENCE_FILE"
[[ -f "$ENV_TEMPLATE" ]] || fail "StoreKit sandbox env template is missing"
template_text="$(cat "$ENV_TEMPLATE")"
template_required_markers=(
  "STOREKIT_PRODUCT_ID"
  "STOREKIT_SANDBOX_PRODUCT_LOOKUP_SUMMARY"
  "STOREKIT_SANDBOX_PURCHASE_SUMMARY"
  "STOREKIT_SANDBOX_RESTORE_SUMMARY"
  "STOREKIT_SANDBOX_FREE_QUOTA_SUMMARY"
  "STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY"
  "STOREKIT_SANDBOX_EVIDENCE_URL"
  "EXTERNAL_VERIFY_EVIDENCE_FILE"
  "record_storekit_sandbox_evidence.sh"
  "sync_app_store_checklist.sh"
)
for marker in "${template_required_markers[@]}"; do
  [[ "$template_text" == *"$marker"* ]] || fail "StoreKit env template missing marker: $marker"
done
grep -q 'STOREKIT_PRODUCT_ID="personal.site.publisher.pro"' "$ENV_TEMPLATE" \
  || fail "StoreKit env template does not preserve the configured product ID"

if grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/|github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|transaction[[:space:]_-]*id|receipt[[:space:]_-]*id)' "$ENV_TEMPLATE"; then
  fail "StoreKit env template contains private-looking sandbox evidence content"
fi

dry_run_output="$TMP_DIR/dry-run.txt"
EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" --dry-run >"$dry_run_output"
grep -q 'personal.site.publisher.pro' "$dry_run_output" || fail "dry-run did not include product ID"
grep -q '29.99' "$dry_run_output" || fail "dry-run did not include display price"
grep -q 'zh_Hans' "$dry_run_output" || fail "dry-run did not include localized StoreKit config"
grep -q 'local StoreKit config lookup:' "$dry_run_output" || fail "dry-run did not label the local StoreKit config lookup"
grep -q 'sandbox product lookup summary: required for --execute' "$dry_run_output" || fail "dry-run did not require sandbox product lookup evidence for execute"
grep -q 'StoreKit coordinator product lookup: present' "$dry_run_output" || fail "dry-run did not verify StoreKit product lookup entry"
grep -q 'StoreKit coordinator purchase entry point: present' "$dry_run_output" || fail "dry-run did not verify StoreKit purchase entry"
grep -q 'StoreKit coordinator restore entry point: present' "$dry_run_output" || fail "dry-run did not verify StoreKit restore entry"
grep -q 'StoreKit entitlement refresh: present' "$dry_run_output" || fail "dry-run did not verify entitlement refresh"
grep -q 'StoreKit external evidence export: present' "$dry_run_output" || fail "dry-run did not verify external evidence export"
grep -q 'StoreKit entitlement status regression test: present' "$dry_run_output" || fail "dry-run did not verify entitlement status test"
grep -q 'StoreKit sandbox verification regression test: present' "$dry_run_output" || fail "dry-run did not verify sandbox verification test"
grep -q 'StoreKit external evidence regression test: present' "$dry_run_output" || fail "dry-run did not verify external evidence regression test"
grep -q 'Pro entitlement free-quota regression test: present' "$dry_run_output" || fail "dry-run did not verify free-quota test"
grep -q 'StoreKit restore-missing-entitlement regression test: present' "$dry_run_output" || fail "dry-run did not verify restore-missing-entitlement test"

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" \
    --purchase "Purchase completed and entitlement source changed to StoreKit." \
    --execute >/dev/null 2>&1; then
  fail "StoreKit sandbox evidence accepted missing product lookup, restore, free quota, and boundary event summaries"
fi

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" \
    --product-lookup "Sandbox product lookup loaded personal.site.publisher.pro from App Store sandbox catalog." \
    --purchase "Purchase completed and entitlement source changed to StoreKit." \
    --execute >/dev/null 2>&1; then
  fail "StoreKit sandbox evidence accepted missing restore, free quota, and boundary event summaries"
fi

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" \
    --purchase "Purchase completed on /Users/example/private screenshot." \
    --dry-run >/dev/null 2>&1; then
  fail "StoreKit sandbox dry-run accepted private local path"
fi

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" \
    --evidence-url "http://example.com/evidence" \
    --dry-run >/dev/null 2>&1; then
  fail "StoreKit sandbox dry-run accepted a non-HTTPS evidence URL"
fi

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" \
    --product-lookup "Sandbox product lookup loaded personal.site.publisher.pro from App Store sandbox catalog." \
    --purchase "Purchase completed on /Users/example/private screenshot." \
    --restore "Restore completed." \
    --free-quota "Free quota boundary verified." \
    --boundary-events "Recent Pro boundary events were verified." \
    --execute >/dev/null 2>&1; then
  fail "StoreKit sandbox evidence accepted private local path"
fi

PENDING_EVIDENCE_FILE="$TMP_DIR/pending-storekit-evidence.md"
cp "$EVIDENCE_FILE" "$PENDING_EVIDENCE_FILE"
cat >>"$PENDING_EVIDENCE_FILE" <<'MD'

### StoreKit sandbox 购买与恢复
- StoreKit product lookup: StoreKit configuration contains product personal.site.publisher.pro; confirm App Store sandbox can load the same product ID before recording evidence.
- StoreKit purchase: Pending sandbox purchase; use the Pro settings purchase button and confirm entitlement source changes to StoreKit.
- StoreKit restore: Pending restore check; use restore purchase and confirm the app does not mark Pro without a StoreKit entitlement.
- StoreKit free quota: Free quota boundary is not currently blocking; confirm Pro unlock leaves quota counters unchanged during AI, online publishing, and batch publishing.
- StoreKit boundary events: Pending boundary event confirmation; confirm free-plan block and Pro no-quota allow events before recording evidence.
MD
perl -0pi -e 's/- \[ \] `storekit-sandbox`/- [x] `storekit-sandbox`/' "$PENDING_EVIDENCE_FILE"
if STRICT_EXTERNAL_STRUCTURE_ONLY=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$PENDING_EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1; then
  fail "strict external evidence gate accepted pending StoreKit sandbox placeholder text"
fi

ready_output="$TMP_DIR/ready-dry-run.txt"
EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" \
    --product-lookup "Sandbox product lookup loaded personal.site.publisher.pro from App Store sandbox catalog." \
    --purchase "Sandbox purchase completed and entitlement source changed to StoreKit." \
    --restore "Sandbox restore reapplied Pro entitlement after clearing local state." \
    --free-quota "Free quota boundary showed upgrade copy before purchase and no quota consumption after Pro unlock." \
    --boundary-events "Recent Pro boundary events showed free-plan block before purchase and Pro no-quota allow after unlock." \
    --dry-run >"$ready_output"
grep -q 'shared external recorder validation: ready' "$ready_output" || fail "dry-run did not validate complete StoreKit evidence through shared recorder"

EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_storekit_sandbox_evidence.sh" \
    --product-lookup "Sandbox product lookup loaded personal.site.publisher.pro from App Store sandbox catalog." \
    --purchase "Sandbox purchase completed and entitlement source changed to StoreKit." \
    --restore "Sandbox restore reapplied Pro entitlement after clearing local state." \
    --free-quota "Free quota boundary showed upgrade copy before purchase and no quota consumption after Pro unlock." \
    --boundary-events "Recent Pro boundary events showed free-plan block before purchase and Pro no-quota allow after unlock." \
    --execute >/dev/null

grep -q '^- \[x\] `storekit-sandbox`' "$EVIDENCE_FILE" || fail "StoreKit sandbox item was not marked complete"
grep -q 'StoreKit product lookup:' "$EVIDENCE_FILE" || fail "product lookup detail missing"
grep -q 'StoreKit purchase:' "$EVIDENCE_FILE" || fail "purchase detail missing"
grep -q 'StoreKit restore:' "$EVIDENCE_FILE" || fail "restore detail missing"
grep -q 'StoreKit free quota:' "$EVIDENCE_FILE" || fail "free quota detail missing"
grep -q 'StoreKit boundary events:' "$EVIDENCE_FILE" || fail "boundary events detail missing"

STRICT_EXTERNAL_STRUCTURE_ONLY=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null

echo "storekit sandbox evidence test: passed"
