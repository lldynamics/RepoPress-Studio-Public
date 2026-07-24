#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-remote-recovery.XXXXXX)"
EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
ENV_TEMPLATE="$ROOT_DIR/docs/release-evidence/remote-recovery.env.example"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "remote recovery evidence test: $*" >&2
  exit 1
}

cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$EVIDENCE_FILE"
[[ -f "$ENV_TEMPLATE" ]] || fail "remote recovery env template is missing"
grep -q "release_evidence_source_manifest.py" "$ROOT_DIR/script/record_remote_recovery_evidence.sh" \
  || fail "remote recovery recorder does not use the shared source manifest"
deployment_manifest_paths="$(python3 "$ROOT_DIR/script/release_evidence_source_manifest.py" \
  "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift" \
  "refreshDeploymentStatus")"
grep -q "WorkbenchStore+DeploymentCommands.swift" <<<"$deployment_manifest_paths" \
  || fail "shared source manifest omits split deployment commands"
remote_test_manifest_paths="$(python3 "$ROOT_DIR/script/release_evidence_source_manifest.py" \
  "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift" \
  "testOnlineDirectPublishBlocksRemoteSamePathConflictBeforeCallingAPI")"
grep -q "WorkbenchStoreRemotePublishingTests.swift" <<<"$remote_test_manifest_paths" \
  || fail "shared source manifest omits split remote publishing tests"

template_text="$(cat "$ENV_TEMPLATE")"
template_required_markers=(
  "REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY"
  "REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY"
  "REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY"
  "REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY"
  "REMOTE_RECOVERY_EVIDENCE_URL"
  "EXTERNAL_VERIFY_EVIDENCE_FILE"
  "record_remote_recovery_evidence.sh"
  "sync_app_store_checklist.sh"
)
for marker in "${template_required_markers[@]}"; do
  [[ "$template_text" == *"$marker"* ]] || fail "remote recovery env template missing marker: $marker"
done

if grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/|github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|private article|real repository|real branch)' "$ENV_TEMPLATE"; then
  fail "remote recovery env template contains private-looking recovery evidence content"
fi

dry_run_output="$TMP_DIR/dry-run.txt"
EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" --dry-run >"$dry_run_output"
grep -q 'remote conflict preview UI: present' "$dry_run_output" || fail "dry-run did not verify conflict UI"
grep -q 'pending/retry release ledger states: present' "$dry_run_output" || fail "dry-run did not verify pending/retry states"
grep -q 'rollback package generation: present' "$dry_run_output" || fail "dry-run did not verify rollback package"
grep -q 'structured recovery evidence export: present' "$dry_run_output" || fail "dry-run did not verify structured recovery export"
grep -q 'remote conflict regression test: present' "$dry_run_output" || fail "dry-run did not verify conflict regression test"
grep -q 'deployment polling regression tests: present' "$dry_run_output" || fail "dry-run did not verify deployment polling tests"
grep -q 'pending retry ledger regression test: present' "$dry_run_output" || fail "dry-run did not verify pending retry regression test"
grep -q 'rollback recovery package regression test: present' "$dry_run_output" || fail "dry-run did not verify rollback recovery regression test"
grep -q 'structured recovery evidence regression test: present' "$dry_run_output" || fail "dry-run did not verify structured recovery regression test"
grep -q 'shared external recorder validation: waiting for all manual summaries' "$dry_run_output" \
  || fail "dry-run did not report waiting shared recorder validation"

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" \
    --remote-conflict-preview "Conflict preview displayed changed path." \
    --execute >/dev/null 2>&1; then
  fail "remote recovery evidence accepted missing pending/retry/rollback summaries"
fi

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" \
    --remote-conflict-preview "Conflict preview included /Users/example/private.md." \
    --pending-offline-state "Pending state displayed." \
    --deployment-retry "Retry refreshed deployment state." \
    --rollback-package "Rollback package copied." \
    --execute >/dev/null 2>&1; then
  fail "remote recovery evidence accepted private local path"
fi

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" \
    --remote-conflict-preview "Conflict preview included /Users/example/private.md." \
    --pending-offline-state "Pending state displayed." \
    --deployment-retry "Retry refreshed deployment state." \
    --rollback-package "Rollback package copied." \
    --dry-run >/dev/null 2>&1; then
  fail "remote recovery dry-run accepted private local path"
fi

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" \
    --remote-conflict-preview "TODO reproduce same-path remote edit." \
    --pending-offline-state "Pending state displayed." \
    --deployment-retry "Waiting for provider retry." \
    --rollback-package "Missing rollback package." \
    --dry-run >/dev/null 2>&1; then
  fail "remote recovery dry-run accepted pending placeholder text"
fi

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" \
    --remote-conflict-preview "Conflict preview displayed changed path." \
    --pending-offline-state "Pending state displayed." \
    --deployment-retry "Retry refreshed deployment state." \
    --rollback-package "Rollback package copied." \
    --evidence-url "http://example.com/remote-recovery" \
    --dry-run >/dev/null 2>&1; then
  fail "remote recovery dry-run accepted a non-HTTPS evidence URL"
fi

ready_output="$TMP_DIR/ready-dry-run.txt"
EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" \
    --remote-conflict-preview "Direct publish was blocked after a same-path remote edit; conflict package listed the changed path." \
    --pending-offline-state "Failed or unknown deployment state was kept as pending retry in the release ledger." \
    --deployment-retry "Deployment polling and manual retry refreshed the provider status." \
    --rollback-package "Rollback package included branch, files, commands, and PR/MR draft URL." \
    --dry-run >"$ready_output"
grep -q 'shared external recorder validation: ready' "$ready_output" \
  || fail "complete dry-run did not validate through shared recorder"

PENDING_EVIDENCE_FILE="$TMP_DIR/pending-remote-recovery-evidence.md"
cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$PENDING_EVIDENCE_FILE"
perl -0pi -e 's/- \[ \] `remote-conflict-deployment-rollback`/- [x] `remote-conflict-deployment-rollback`/' "$PENDING_EVIDENCE_FILE"
cat >>"$PENDING_EVIDENCE_FILE" <<'EOF'

### 远端冲突、部署和回滚
- Remote recovery pending.
- Remote conflict preview: TODO reproduce same-path remote edit.
- Pending/offline state: Failed deployment stayed pending for retry.
- Deployment retry: Waiting for provider retry.
- Rollback package: Missing rollback package.
EOF
if STRICT_EXTERNAL_STRUCTURE_ONLY=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$PENDING_EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1; then
  fail "strict external gate accepted pending remote recovery evidence"
fi

EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_remote_recovery_evidence.sh" \
    --remote-conflict-preview "Direct publish was blocked after a same-path remote edit; conflict package listed the changed path." \
    --pending-offline-state "Failed or unknown deployment state was kept as pending retry in the release ledger." \
    --deployment-retry "Deployment polling and manual retry refreshed the provider status." \
    --rollback-package "Rollback package included branch, files, commands, and PR/MR draft URL." \
    --execute >/dev/null

grep -q '^- \[x\] `remote-conflict-deployment-rollback`' "$EVIDENCE_FILE" || fail "remote recovery item was not marked complete"
grep -q 'Remote conflict preview:' "$EVIDENCE_FILE" || fail "remote conflict detail missing"
grep -q 'Pending/offline state:' "$EVIDENCE_FILE" || fail "pending/offline detail missing"
grep -q 'Deployment retry:' "$EVIDENCE_FILE" || fail "deployment retry detail missing"
grep -q 'Rollback package:' "$EVIDENCE_FILE" || fail "rollback package detail missing"

STRICT_EXTERNAL_STRUCTURE_ONLY=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null

echo "remote recovery evidence test: passed"
