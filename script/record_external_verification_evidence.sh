#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_FILE="${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
SCREENSHOT_MANIFEST_FILE="${SCREENSHOT_MANIFEST_FILE:-$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md}"
ITEM_ID=""
SUMMARY=""
EVIDENCE_URL=""
TOKEN_SCOPE=""
COMMIT_SHA=""
DEPLOYMENT_STATUS=""
RELEASE_LEDGER=""
PR_URL=""
MR_URL=""
PROVIDER_REVIEW_ARTIFACT=""
REVIEW_BRANCH=""
SOURCE_BRANCH=""
TARGET_BRANCH=""
FILE_CHANGES=""
ROLLBACK_DRAFT=""
REMOTE_CONFLICT_PREVIEW=""
PENDING_OFFLINE_STATE=""
DEPLOYMENT_RETRY=""
ROLLBACK_PACKAGE=""
SCREENSHOT_SET=""
SCREENSHOT_PRIVACY_GATE=""
SCREENSHOT_STRICT_GATE=""
SCREENSHOT_SOURCE_FINGERPRINT=""
EXECUTE=0

usage() {
  cat <<'USAGE'
Usage: script/record_external_verification_evidence.sh --item <id> --summary <text> [--evidence-url <url>] --execute
       script/record_external_verification_evidence.sh --dry-run

For github-direct-publish and gitlab-direct-publish, include:
  --token-scope <text>
  --commit-sha <text>
  --deployment-status <text>
  --release-ledger <text>

For github-review-publish, include:
  --pr-url <https-url>
  --provider-review-artifact <text>
  --review-branch <text>
  --target-branch <text>
  --file-changes <text>
  --deployment-status <text>
  --release-ledger <text>
  --rollback-draft <text>

For gitlab-review-publish, include:
  --mr-url <https-url>
  --provider-review-artifact <text>
  --source-branch <text>
  --target-branch <text>
  --file-changes <text>
  --deployment-status <text>
  --release-ledger <text>
  --rollback-draft <text>

For remote-conflict-deployment-rollback, include:
  --remote-conflict-preview <text>
  --pending-offline-state <text>
  --deployment-retry <text>
  --rollback-package <text>

For app-store-screenshots, include:
  --screenshot-set <text>
  --screenshot-privacy-gate <text>
  --screenshot-strict-gate <text>
  --screenshot-source-fingerprint <sha256:hex>

Records redacted external verification evidence in docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md.
It only accepts the fixed release evidence item IDs and refuses local paths,
token-like strings, and authorization headers. By default, use --dry-run to
validate the recorder without writing.

Allowed item IDs:
  github-direct-publish
  github-review-publish
  gitlab-direct-publish
  gitlab-review-publish
  remote-conflict-deployment-rollback
  app-store-screenshots

Examples:
  script/record_external_verification_evidence.sh --dry-run

  script/record_external_verification_evidence.sh \
    --item github-direct-publish \
    --summary "GitHub direct publish verified on disposable test repository." \
    --token-scope "Least-privilege contents write token was confirmed by provider API." \
    --commit-sha "abc123 redacted test commit." \
    --deployment-status "GitHub Pages or Actions status reached success for the test commit." \
    --release-ledger "Release ledger contains the online direct publish entry and deployment check." \
    --evidence-url "https://github.com/owner/test-site/commit/abc123" \
    --execute

  script/record_external_verification_evidence.sh \
    --item remote-conflict-deployment-rollback \
    --summary "Remote conflict, pending deployment, retry, and rollback flow verified on disposable content." \
    --remote-conflict-preview "Direct publish blocked after same-path remote edit; conflict package listed the changed path." \
    --pending-offline-state "Failed deployment was kept as pending retry in the release ledger." \
    --deployment-retry "Deployment polling and manual retry refreshed the provider status." \
    --rollback-package "Rollback package included branch, files, and PR/MR draft URL." \
    --execute

  script/record_external_verification_evidence.sh \
    --item app-store-screenshots \
    --summary "Eight App Store screenshots captured and strict screenshot/privacy gates passed." \
    --screenshot-set "Captured manifest screenshot IDs: writing, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, privacy-lock." \
    --screenshot-privacy-gate "check_screenshot_privacy.sh passed with no local paths, tokens, or private article text." \
    --screenshot-strict-gate "STRICT_SCREENSHOTS=1 check_screenshots.sh and strict release gate output were reviewed." \
    --screenshot-source-fingerprint "$(script/screenshot_evidence_fingerprint.py)" \
    --execute
USAGE
}

fail() {
  echo "external verification recorder: $*" >&2
  exit 1
}

allowed_ids=(
  github-direct-publish
  github-review-publish
  gitlab-direct-publish
  gitlab-review-publish
  remote-conflict-deployment-rollback
  app-store-screenshots
)

is_allowed_id() {
  local candidate="$1"
  for id in "${allowed_ids[@]}"; do
    [[ "$candidate" == "$id" ]] && return 0
  done
  return 1
}

title_for_id() {
  case "$1" in
    github-direct-publish) echo "GitHub API 直接提交" ;;
    github-review-publish) echo "GitHub PR 发布" ;;
    gitlab-direct-publish) echo "GitLab API 直接提交" ;;
    gitlab-review-publish) echo "GitLab MR 发布" ;;
    remote-conflict-deployment-rollback) echo "远端冲突、部署和回滚" ;;
    app-store-screenshots) echo "App Store 截图和严格门禁" ;;
    *) fail "unsupported item id: $1" ;;
  esac
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

reject_remote_recovery_placeholder_content() {
  local value="$1"
  local label="$2"
  if printf "%s" "$value" | grep -Eiq '(todo|not verified|not checked|not confirmed|waiting for|missing rollback|missing deployment|missing conflict|待填写|待验证|未验证|未确认)'; then
    fail "$label still contains pending recovery verification placeholder text"
  fi
}

reject_online_publish_placeholder_content() {
  local value="$1"
  local label="$2"
  if printf "%s" "$value" | grep -Eiq '(todo|pending|not verified|not checked|not confirmed|waiting for|missing|待填写|待验证|待确认|未验证|未确认)'; then
    fail "$label still contains pending online verification placeholder text"
  fi
}

contains_any() {
  local haystack="$1"
  shift
  local needle
  for needle in "$@"; do
    [[ "$haystack" == *"$needle"* ]] && return 0
  done
  return 1
}

require_release_ledger_coverage() {
  local item_id="$1"
  local value_lc
  value_lc="$(printf "%s" "$2" | tr '[:upper:]' '[:lower:]')"
  case "$item_id" in
    github-direct-publish|gitlab-direct-publish)
      contains_any "$value_lc" "direct" "直接" || fail "release ledger must mention the direct publish entry for $item_id"
      ;;
    github-review-publish)
      contains_any "$value_lc" "pr" "pull request" "review branch" || fail "release ledger must mention the PR/review publish entry for github-review-publish"
      ;;
    gitlab-review-publish)
      contains_any "$value_lc" "mr" "merge request" "source branch" || fail "release ledger must mention the MR/review publish entry for gitlab-review-publish"
      ;;
  esac
}

require_screenshot_set_coverage() {
  local value_lc
  value_lc="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"
  local missing=()
  local id
  local required_count=0
  [[ -f "$SCREENSHOT_MANIFEST_FILE" ]] || fail "screenshot manifest is missing: $SCREENSHOT_MANIFEST_FILE"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    required_count=$((required_count + 1))
    contains_any "$value_lc" "$id" || missing+=("$id")
  done < <(sed -nE 's/^\| `([^`]+)` \|.*/\1/p' "$SCREENSHOT_MANIFEST_FILE")
  [[ "$required_count" -gt 0 ]] || fail "screenshot manifest contains no required screenshot IDs"
  [[ "${#missing[@]}" -eq 0 ]] || fail "screenshot set is missing required screen(s): ${missing[*]}"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --item)
      [[ "$#" -ge 2 ]] || fail "--item requires an evidence item ID"
      ITEM_ID="$2"
      shift 2
      ;;
    --summary)
      [[ "$#" -ge 2 ]] || fail "--summary requires text"
      SUMMARY="$2"
      shift 2
      ;;
    --evidence-url)
      [[ "$#" -ge 2 ]] || fail "--evidence-url requires a URL"
      EVIDENCE_URL="$2"
      shift 2
      ;;
    --token-scope)
      [[ "$#" -ge 2 ]] || fail "--token-scope requires text"
      TOKEN_SCOPE="$2"
      shift 2
      ;;
    --commit-sha)
      [[ "$#" -ge 2 ]] || fail "--commit-sha requires text"
      COMMIT_SHA="$2"
      shift 2
      ;;
    --deployment-status)
      [[ "$#" -ge 2 ]] || fail "--deployment-status requires text"
      DEPLOYMENT_STATUS="$2"
      shift 2
      ;;
    --release-ledger)
      [[ "$#" -ge 2 ]] || fail "--release-ledger requires text"
      RELEASE_LEDGER="$2"
      shift 2
      ;;
    --pr-url)
      [[ "$#" -ge 2 ]] || fail "--pr-url requires an https URL"
      PR_URL="$2"
      shift 2
      ;;
    --mr-url)
      [[ "$#" -ge 2 ]] || fail "--mr-url requires an https URL"
      MR_URL="$2"
      shift 2
      ;;
    --provider-review-artifact)
      [[ "$#" -ge 2 ]] || fail "--provider-review-artifact requires text"
      PROVIDER_REVIEW_ARTIFACT="$2"
      shift 2
      ;;
    --review-branch)
      [[ "$#" -ge 2 ]] || fail "--review-branch requires text"
      REVIEW_BRANCH="$2"
      shift 2
      ;;
    --source-branch)
      [[ "$#" -ge 2 ]] || fail "--source-branch requires text"
      SOURCE_BRANCH="$2"
      shift 2
      ;;
    --target-branch)
      [[ "$#" -ge 2 ]] || fail "--target-branch requires text"
      TARGET_BRANCH="$2"
      shift 2
      ;;
    --file-changes)
      [[ "$#" -ge 2 ]] || fail "--file-changes requires text"
      FILE_CHANGES="$2"
      shift 2
      ;;
    --rollback-draft)
      [[ "$#" -ge 2 ]] || fail "--rollback-draft requires text"
      ROLLBACK_DRAFT="$2"
      shift 2
      ;;
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
    --screenshot-set)
      [[ "$#" -ge 2 ]] || fail "--screenshot-set requires text"
      SCREENSHOT_SET="$2"
      shift 2
      ;;
    --screenshot-privacy-gate)
      [[ "$#" -ge 2 ]] || fail "--screenshot-privacy-gate requires text"
      SCREENSHOT_PRIVACY_GATE="$2"
      shift 2
      ;;
    --screenshot-strict-gate)
      [[ "$#" -ge 2 ]] || fail "--screenshot-strict-gate requires text"
      SCREENSHOT_STRICT_GATE="$2"
      shift 2
      ;;
    --screenshot-source-fingerprint)
      [[ "$#" -ge 2 ]] || fail "--screenshot-source-fingerprint requires a sha256 value"
      SCREENSHOT_SOURCE_FINGERPRINT="$2"
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
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$EVIDENCE_FILE" ]] || fail "evidence file is missing: ${EVIDENCE_FILE#$ROOT_DIR/}"

if [[ -z "$ITEM_ID" && "$EXECUTE" == "0" ]]; then
  echo "external verification recorder: ready"
  echo "- evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"
  echo "- allowed items: ${#allowed_ids[@]}"
  exit 0
fi

[[ -n "$ITEM_ID" ]] || fail "--item is required"
is_allowed_id "$ITEM_ID" || fail "unsupported item id: $ITEM_ID"
[[ -n "${SUMMARY//[[:space:]]/}" ]] || fail "--summary is required"

reject_private_content "$SUMMARY" "summary"
if [[ -n "$EVIDENCE_URL" ]]; then
  reject_private_content "$EVIDENCE_URL" "evidence URL"
  [[ "$EVIDENCE_URL" =~ ^https:// ]] || fail "evidence URL must be https://"
fi
if [[ "$ITEM_ID" == "github-direct-publish" || "$ITEM_ID" == "gitlab-direct-publish" ]]; then
  reject_online_publish_placeholder_content "$SUMMARY" "summary"
  [[ -n "${TOKEN_SCOPE//[[:space:]]/}" ]] || fail "--token-scope is required for $ITEM_ID"
  [[ -n "${COMMIT_SHA//[[:space:]]/}" ]] || fail "--commit-sha is required for $ITEM_ID"
  [[ -n "${DEPLOYMENT_STATUS//[[:space:]]/}" ]] || fail "--deployment-status is required for $ITEM_ID"
  [[ -n "${RELEASE_LEDGER//[[:space:]]/}" ]] || fail "--release-ledger is required for $ITEM_ID"
  reject_private_content "$TOKEN_SCOPE" "token scope"
  reject_private_content "$COMMIT_SHA" "commit SHA"
  reject_private_content "$DEPLOYMENT_STATUS" "deployment status"
  reject_private_content "$RELEASE_LEDGER" "release ledger"
  reject_online_publish_placeholder_content "$TOKEN_SCOPE" "token scope"
  reject_online_publish_placeholder_content "$COMMIT_SHA" "commit SHA"
  reject_online_publish_placeholder_content "$DEPLOYMENT_STATUS" "deployment status"
  reject_online_publish_placeholder_content "$RELEASE_LEDGER" "release ledger"
  require_release_ledger_coverage "$ITEM_ID" "$RELEASE_LEDGER"
fi
if [[ "$ITEM_ID" == "github-review-publish" ]]; then
  reject_online_publish_placeholder_content "$SUMMARY" "summary"
  [[ -n "${PR_URL//[[:space:]]/}" ]] || fail "--pr-url is required for github-review-publish"
  [[ "$PR_URL" =~ ^https:// ]] || fail "--pr-url must be https://"
  [[ -n "${PROVIDER_REVIEW_ARTIFACT//[[:space:]]/}" ]] || fail "--provider-review-artifact is required for github-review-publish"
  [[ -n "${REVIEW_BRANCH//[[:space:]]/}" ]] || fail "--review-branch is required for github-review-publish"
  [[ -n "${TARGET_BRANCH//[[:space:]]/}" ]] || fail "--target-branch is required for github-review-publish"
  [[ -n "${FILE_CHANGES//[[:space:]]/}" ]] || fail "--file-changes is required for github-review-publish"
  [[ -n "${DEPLOYMENT_STATUS//[[:space:]]/}" ]] || fail "--deployment-status is required for github-review-publish"
  [[ -n "${RELEASE_LEDGER//[[:space:]]/}" ]] || fail "--release-ledger is required for github-review-publish"
  [[ -n "${ROLLBACK_DRAFT//[[:space:]]/}" ]] || fail "--rollback-draft is required for github-review-publish"
  reject_private_content "$PR_URL" "PR URL"
  reject_private_content "$PROVIDER_REVIEW_ARTIFACT" "provider review artifact"
  reject_private_content "$REVIEW_BRANCH" "review branch"
  reject_private_content "$TARGET_BRANCH" "target branch"
  reject_private_content "$FILE_CHANGES" "file changes"
  reject_private_content "$DEPLOYMENT_STATUS" "deployment status"
  reject_private_content "$RELEASE_LEDGER" "release ledger"
  reject_private_content "$ROLLBACK_DRAFT" "rollback draft"
  reject_online_publish_placeholder_content "$PROVIDER_REVIEW_ARTIFACT" "provider review artifact"
  reject_online_publish_placeholder_content "$FILE_CHANGES" "file changes"
  reject_online_publish_placeholder_content "$DEPLOYMENT_STATUS" "deployment status"
  reject_online_publish_placeholder_content "$RELEASE_LEDGER" "release ledger"
  reject_online_publish_placeholder_content "$ROLLBACK_DRAFT" "rollback draft"
  require_release_ledger_coverage "$ITEM_ID" "$RELEASE_LEDGER"
fi
if [[ "$ITEM_ID" == "gitlab-review-publish" ]]; then
  reject_online_publish_placeholder_content "$SUMMARY" "summary"
  [[ -n "${MR_URL//[[:space:]]/}" ]] || fail "--mr-url is required for gitlab-review-publish"
  [[ "$MR_URL" =~ ^https:// ]] || fail "--mr-url must be https://"
  [[ -n "${PROVIDER_REVIEW_ARTIFACT//[[:space:]]/}" ]] || fail "--provider-review-artifact is required for gitlab-review-publish"
  [[ -n "${SOURCE_BRANCH//[[:space:]]/}" ]] || fail "--source-branch is required for gitlab-review-publish"
  [[ -n "${TARGET_BRANCH//[[:space:]]/}" ]] || fail "--target-branch is required for gitlab-review-publish"
  [[ -n "${FILE_CHANGES//[[:space:]]/}" ]] || fail "--file-changes is required for gitlab-review-publish"
  [[ -n "${DEPLOYMENT_STATUS//[[:space:]]/}" ]] || fail "--deployment-status is required for gitlab-review-publish"
  [[ -n "${RELEASE_LEDGER//[[:space:]]/}" ]] || fail "--release-ledger is required for gitlab-review-publish"
  [[ -n "${ROLLBACK_DRAFT//[[:space:]]/}" ]] || fail "--rollback-draft is required for gitlab-review-publish"
  reject_private_content "$MR_URL" "MR URL"
  reject_private_content "$PROVIDER_REVIEW_ARTIFACT" "provider review artifact"
  reject_private_content "$SOURCE_BRANCH" "source branch"
  reject_private_content "$TARGET_BRANCH" "target branch"
  reject_private_content "$FILE_CHANGES" "file changes"
  reject_private_content "$DEPLOYMENT_STATUS" "deployment status"
  reject_private_content "$RELEASE_LEDGER" "release ledger"
  reject_private_content "$ROLLBACK_DRAFT" "rollback draft"
  reject_online_publish_placeholder_content "$PROVIDER_REVIEW_ARTIFACT" "provider review artifact"
  reject_online_publish_placeholder_content "$FILE_CHANGES" "file changes"
  reject_online_publish_placeholder_content "$DEPLOYMENT_STATUS" "deployment status"
  reject_online_publish_placeholder_content "$RELEASE_LEDGER" "release ledger"
  reject_online_publish_placeholder_content "$ROLLBACK_DRAFT" "rollback draft"
  require_release_ledger_coverage "$ITEM_ID" "$RELEASE_LEDGER"
fi
if [[ "$ITEM_ID" == "remote-conflict-deployment-rollback" ]]; then
  [[ -n "${REMOTE_CONFLICT_PREVIEW//[[:space:]]/}" ]] || fail "--remote-conflict-preview is required for remote-conflict-deployment-rollback"
  [[ -n "${PENDING_OFFLINE_STATE//[[:space:]]/}" ]] || fail "--pending-offline-state is required for remote-conflict-deployment-rollback"
  [[ -n "${DEPLOYMENT_RETRY//[[:space:]]/}" ]] || fail "--deployment-retry is required for remote-conflict-deployment-rollback"
  [[ -n "${ROLLBACK_PACKAGE//[[:space:]]/}" ]] || fail "--rollback-package is required for remote-conflict-deployment-rollback"
  reject_private_content "$REMOTE_CONFLICT_PREVIEW" "remote conflict preview"
  reject_private_content "$PENDING_OFFLINE_STATE" "pending/offline state"
  reject_private_content "$DEPLOYMENT_RETRY" "deployment retry"
  reject_private_content "$ROLLBACK_PACKAGE" "rollback package"
  reject_remote_recovery_placeholder_content "$REMOTE_CONFLICT_PREVIEW" "remote conflict preview"
  reject_remote_recovery_placeholder_content "$PENDING_OFFLINE_STATE" "pending/offline state"
  reject_remote_recovery_placeholder_content "$DEPLOYMENT_RETRY" "deployment retry"
  reject_remote_recovery_placeholder_content "$ROLLBACK_PACKAGE" "rollback package"
fi
if [[ "$ITEM_ID" == "app-store-screenshots" ]]; then
  [[ -n "${SCREENSHOT_SET//[[:space:]]/}" ]] || fail "--screenshot-set is required for app-store-screenshots"
  [[ -n "${SCREENSHOT_PRIVACY_GATE//[[:space:]]/}" ]] || fail "--screenshot-privacy-gate is required for app-store-screenshots"
  [[ -n "${SCREENSHOT_STRICT_GATE//[[:space:]]/}" ]] || fail "--screenshot-strict-gate is required for app-store-screenshots"
  [[ "$SCREENSHOT_SOURCE_FINGERPRINT" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || fail "--screenshot-source-fingerprint must be sha256 followed by 64 lowercase hex characters"
  reject_private_content "$SCREENSHOT_SET" "screenshot set"
  reject_private_content "$SCREENSHOT_PRIVACY_GATE" "screenshot privacy gate"
  reject_private_content "$SCREENSHOT_STRICT_GATE" "screenshot strict gate"
  require_screenshot_set_coverage "$SCREENSHOT_SET"
fi

TITLE="$(title_for_id "$ITEM_ID")"

if [[ "$EXECUTE" != "1" ]]; then
  echo "external verification recorder: dry-run"
  echo "- item: $ITEM_ID"
  echo "- title: $TITLE"
  echo "- evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"
  if [[ "$ITEM_ID" == "github-direct-publish" || "$ITEM_ID" == "gitlab-direct-publish" ]]; then
    echo "- token scope: recorded"
    echo "- commit SHA: recorded"
    echo "- deployment status: recorded"
    echo "- release ledger: recorded"
  fi
  if [[ "$ITEM_ID" == "github-review-publish" ]]; then
    echo "- PR URL: recorded"
    echo "- provider review artifact: recorded"
    echo "- review branch: recorded"
    echo "- target branch: recorded"
    echo "- file changes: recorded"
    echo "- deployment status: recorded"
    echo "- release ledger: recorded"
    echo "- rollback draft: recorded"
  fi
  if [[ "$ITEM_ID" == "gitlab-review-publish" ]]; then
    echo "- MR URL: recorded"
    echo "- provider review artifact: recorded"
    echo "- source branch: recorded"
    echo "- target branch: recorded"
    echo "- file changes: recorded"
    echo "- deployment status: recorded"
    echo "- release ledger: recorded"
    echo "- rollback draft: recorded"
  fi
  if [[ "$ITEM_ID" == "remote-conflict-deployment-rollback" ]]; then
    echo "- remote conflict preview: recorded"
    echo "- pending/offline state: recorded"
    echo "- deployment retry: recorded"
    echo "- rollback package: recorded"
  fi
  if [[ "$ITEM_ID" == "app-store-screenshots" ]]; then
    echo "- screenshot set: recorded"
    echo "- screenshot privacy gate: recorded"
    echo "- screenshot strict gate: recorded"
    echo "- screenshot source fingerprint: recorded"
  fi
  echo "- execute: pass --execute to write the completed evidence item"
  exit 0
fi

python3 - "$EVIDENCE_FILE" "$ITEM_ID" "$TITLE" "$SUMMARY" "$EVIDENCE_URL" "$TOKEN_SCOPE" "$COMMIT_SHA" "$DEPLOYMENT_STATUS" "$RELEASE_LEDGER" "$PR_URL" "$MR_URL" "$PROVIDER_REVIEW_ARTIFACT" "$REVIEW_BRANCH" "$SOURCE_BRANCH" "$TARGET_BRANCH" "$FILE_CHANGES" "$ROLLBACK_DRAFT" "$REMOTE_CONFLICT_PREVIEW" "$PENDING_OFFLINE_STATE" "$DEPLOYMENT_RETRY" "$ROLLBACK_PACKAGE" "$SCREENSHOT_SET" "$SCREENSHOT_PRIVACY_GATE" "$SCREENSHOT_STRICT_GATE" "$SCREENSHOT_SOURCE_FINGERPRINT" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
(
    item_id,
    title,
    summary,
    evidence_url,
    token_scope,
    commit_sha,
    deployment_status,
    release_ledger,
    pr_url,
    mr_url,
    provider_review_artifact,
    review_branch,
    source_branch,
    target_branch,
    file_changes,
    rollback_draft,
    remote_conflict_preview,
    pending_offline_state,
    deployment_retry,
    rollback_package,
    screenshot_set,
    screenshot_privacy_gate,
    screenshot_strict_gate,
    screenshot_source_fingerprint,
) = sys.argv[2:26]
text = path.read_text()
pattern = re.compile(rf"^- \[[ xX]\] `{re.escape(item_id)}` - .*$", re.MULTILINE)
replacement = f"- [x] `{item_id}` - {title}: {summary}"
if pattern.search(text):
    text = pattern.sub(replacement, text, count=1)
else:
    text += f"\n{replacement}\n"

note_title = f"### {title}"
note_lines = [f"- {summary}"]
if item_id in {"github-direct-publish", "gitlab-direct-publish"}:
    deployment_label = "Pipeline or Pages status" if item_id == "gitlab-direct-publish" else "Deployment status"
    note_lines.extend([
        f"- Token scope: {token_scope}",
        f"- Commit SHA: {commit_sha}",
        f"- {deployment_label}: {deployment_status}",
        f"- Release ledger: {release_ledger}",
    ])
if item_id == "github-review-publish":
    note_lines.extend([
        f"- PR URL: {pr_url}",
        f"- Provider review artifact: {provider_review_artifact}",
        f"- Review branch: {review_branch}",
        f"- Target branch: {target_branch}",
        f"- File changes: {file_changes}",
        f"- Deployment status: {deployment_status}",
        f"- Release ledger: {release_ledger}",
        f"- Rollback draft: {rollback_draft}",
    ])
if item_id == "gitlab-review-publish":
    note_lines.extend([
        f"- MR URL: {mr_url}",
        f"- Provider review artifact: {provider_review_artifact}",
        f"- Source branch: {source_branch}",
        f"- Target branch: {target_branch}",
        f"- File changes: {file_changes}",
        f"- Deployment status: {deployment_status}",
        f"- Release ledger: {release_ledger}",
        f"- Rollback draft: {rollback_draft}",
    ])
if item_id == "remote-conflict-deployment-rollback":
    note_lines.extend([
        f"- Remote conflict preview: {remote_conflict_preview}",
        f"- Pending/offline state: {pending_offline_state}",
        f"- Deployment retry: {deployment_retry}",
        f"- Rollback package: {rollback_package}",
    ])
if item_id == "app-store-screenshots":
    note_lines.extend([
        f"- Screenshot set: {screenshot_set}",
        f"- Screenshot privacy gate: {screenshot_privacy_gate}",
        f"- Screenshot strict gate: {screenshot_strict_gate}",
        f"- Screenshot source fingerprint: {screenshot_source_fingerprint}",
    ])
if evidence_url:
    note_lines.append(f"- Evidence URL: {evidence_url}")
note = "\n".join(note_lines)
if note_title in text:
    text = text.rstrip() + "\n" + note + "\n"
else:
    text = text.rstrip() + f"\n\n{note_title}\n{note}\n"
path.write_text(text)
PY

echo "external verification recorder: recorded $ITEM_ID"
echo "- updated: ${EVIDENCE_FILE#$ROOT_DIR/}"
