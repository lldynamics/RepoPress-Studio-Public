#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_MANIFEST_HELPER="$ROOT_DIR/script/release_evidence_source_manifest.py"
EVIDENCE_FILE="${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
REMOTE_CONFLICT_PREVIEW=""
PENDING_OFFLINE_STATE=""
DEPLOYMENT_RETRY=""
ROLLBACK_PACKAGE=""
EVIDENCE_URL=""
EXECUTE=0

usage() {
  cat <<'USAGE'
Usage: script/record_remote_recovery_evidence.sh --remote-conflict-preview <text> --pending-offline-state <text> --deployment-retry <text> --rollback-package <text> --execute
       script/record_remote_recovery_evidence.sh --dry-run

Records the remote-conflict-deployment-rollback external evidence item through
the shared evidence recorder. The script first verifies that the current Mac
app sources still contain the remote conflict preview, pending deployment/retry
states, deployment recheck action, and rollback package surfaces.

The four evidence fields must come from a real disposable remote-publish run.
Use short redacted summaries only.

Options:
  --remote-conflict-preview <text>  Same-path remote conflict preview evidence.
  --pending-offline-state <text>    Pending/offline deployment ledger evidence.
  --deployment-retry <text>         Deployment polling or manual retry evidence.
  --rollback-package <text>         Rollback commands and PR/MR draft evidence.
  --evidence-url <url>              Optional HTTPS evidence URL.
  --execute                         Write docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md.
  --dry-run                         Validate local capability coverage without writing.
USAGE
}

fail() {
  echo "remote recovery evidence: $*" >&2
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
    --remote-conflict-preview)
      [[ "$#" -ge 2 ]] || fail "--remote-conflict-preview requires text"
      REMOTE_CONFLICT_PREVIEW="$2"
      shift 2
      ;;
    --pending-offline-state)
      [[ "$#" -ge 2 ]] || fail "--pending-offline-state requires text"
      PENDING_OFFLINE_STATE="$2"
      shift 2
      ;;
    --deployment-retry)
      [[ "$#" -ge 2 ]] || fail "--deployment-retry requires text"
      DEPLOYMENT_RETRY="$2"
      shift 2
      ;;
    --rollback-package)
      [[ "$#" -ge 2 ]] || fail "--rollback-package requires text"
      ROLLBACK_PACKAGE="$2"
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

require_source_pattern() {
  local relative_path="$1"
  local pattern="$2"
  local label="$3"
  if ! grep -R -q "$pattern" "$ROOT_DIR/$relative_path"; then
    fail "missing local capability surface: $label"
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
  fail "missing local capability surface: $label"
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

require_source_pattern "Sources/PersonalSitePublisherMac/Views" "remoteConflictPaths" "remote conflict preview UI"
require_source_pattern "Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift" "pendingRetry" "pending retry release ledger state"
require_source_pattern "Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift" "retryDeploymentCheck" "deployment retry action"
require_source_pattern "Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift" "ReleaseRollbackDraft" "rollback package generation"
require_source_pattern "Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift" "externalVerificationEvidenceMarkdown" "structured recovery evidence export"
require_source_pattern_source_manifest \
  "Sources/PersonalSitePublisherMac/Views/DetailContainerView.swift" \
  "copyRecoveryEvidence" \
  "structured recovery evidence copy UI"
require_source_pattern_source_manifest \
  "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift" \
  "refreshDeploymentStatus" \
  "manual deployment status refresh"
require_source_pattern_source_manifest \
  "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift" \
  "deploymentPollingState" \
  "deployment polling state"
require_source_pattern_source_manifest \
  "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift" \
  "testOnlineDirectPublishBlocksRemoteSamePathConflictBeforeCallingAPI" \
  "remote same-path conflict regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift" "testDeploymentPollingChecksPendingDeploymentRecordsAndCachesSnapshots" "deployment polling regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift" "testDeploymentPollingSummarizesSuccessRunningAndFailedRecords" "deployment polling summary regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift" "testUnknownDeploymentCheckBecomesRetryablePendingState" "pending retry ledger regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift" "testRecoveryPackageCombinesDeploymentSignalsAndRollbackCommands" "rollback recovery package regression test"
require_source_pattern "Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift" "testRecoveryPackageBuildsExternalVerificationEvidenceSummary" "structured recovery evidence regression test"

if [[ -n "${REMOTE_CONFLICT_PREVIEW//[[:space:]]/}" ]]; then
  reject_private_content "$REMOTE_CONFLICT_PREVIEW" "remote conflict preview"
fi
if [[ -n "${PENDING_OFFLINE_STATE//[[:space:]]/}" ]]; then
  reject_private_content "$PENDING_OFFLINE_STATE" "pending/offline state"
fi
if [[ -n "${DEPLOYMENT_RETRY//[[:space:]]/}" ]]; then
  reject_private_content "$DEPLOYMENT_RETRY" "deployment retry"
fi
if [[ -n "${ROLLBACK_PACKAGE//[[:space:]]/}" ]]; then
  reject_private_content "$ROLLBACK_PACKAGE" "rollback package"
fi
if [[ -n "$EVIDENCE_URL" ]]; then
  reject_private_content "$EVIDENCE_URL" "evidence URL"
  [[ "$EVIDENCE_URL" =~ ^https:// ]] || fail "--evidence-url must be https://"
fi

if [[ "$EXECUTE" == "1" ]]; then
  [[ -n "${REMOTE_CONFLICT_PREVIEW//[[:space:]]/}" ]] || fail "--remote-conflict-preview is required with --execute"
  [[ -n "${PENDING_OFFLINE_STATE//[[:space:]]/}" ]] || fail "--pending-offline-state is required with --execute"
  [[ -n "${DEPLOYMENT_RETRY//[[:space:]]/}" ]] || fail "--deployment-retry is required with --execute"
  [[ -n "${ROLLBACK_PACKAGE//[[:space:]]/}" ]] || fail "--rollback-package is required with --execute"
fi

record_args=(
  --item remote-conflict-deployment-rollback
  --summary "Remote conflict preview, pending/offline deployment state, retry, deployment polling, and rollback guidance verified on disposable remote content."
  --remote-conflict-preview "$REMOTE_CONFLICT_PREVIEW"
  --pending-offline-state "$PENDING_OFFLINE_STATE"
  --deployment-retry "$DEPLOYMENT_RETRY"
  --rollback-package "$ROLLBACK_PACKAGE"
)

if [[ -n "$EVIDENCE_URL" ]]; then
  record_args+=(--evidence-url "$EVIDENCE_URL")
fi

if [[ "$EXECUTE" == "1" ]]; then
  EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
    bash "$ROOT_DIR/script/record_external_verification_evidence.sh" "${record_args[@]}" --execute
else
  has_all_manual_summaries=0
  if [[ -n "${REMOTE_CONFLICT_PREVIEW//[[:space:]]/}" &&
        -n "${PENDING_OFFLINE_STATE//[[:space:]]/}" &&
        -n "${DEPLOYMENT_RETRY//[[:space:]]/}" &&
        -n "${ROLLBACK_PACKAGE//[[:space:]]/}" ]]; then
    has_all_manual_summaries=1
    EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
      bash "$ROOT_DIR/script/record_external_verification_evidence.sh" "${record_args[@]}" --dry-run >/dev/null
  fi

  echo "remote recovery evidence: dry-run"
  echo "- remote conflict preview UI: present"
  echo "- pending/retry release ledger states: present"
  echo "- deployment retry action: present"
  echo "- rollback package generation: present"
  echo "- structured recovery evidence export: present"
  echo "- remote conflict regression test: present"
  echo "- deployment polling regression tests: present"
  echo "- pending retry ledger regression test: present"
  echo "- rollback recovery package regression test: present"
  echo "- structured recovery evidence regression test: present"
  if [[ "$has_all_manual_summaries" == "1" ]]; then
    echo "- shared external recorder validation: ready"
  else
    echo "- shared external recorder validation: waiting for all manual summaries"
  fi
  echo "- evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"
  echo "- execute: pass --execute with all four redacted evidence summaries"
fi
