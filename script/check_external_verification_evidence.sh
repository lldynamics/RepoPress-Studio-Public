#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_FILE="${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"

fail() {
  echo "external verification gate: $*" >&2
  exit 1
}

[[ -f "$EVIDENCE_FILE" ]] || fail "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md is missing"

required_ids=(
  github-direct-publish
  github-review-publish
  gitlab-direct-publish
  gitlab-review-publish
  remote-conflict-deployment-rollback
  storekit-sandbox
  app-store-screenshots
)

text="$(cat "$EVIDENCE_FILE")"

missing_ids=()
unchecked_ids=()
for id in "${required_ids[@]}"; do
  if ! grep -q "\`$id\`" "$EVIDENCE_FILE"; then
    missing_ids+=("$id")
    continue
  fi
  if ! grep -Eq "^- \[[xX]\][[:space:]]+\`$id\`" "$EVIDENCE_FILE"; then
    unchecked_ids+=("$id")
  fi
done

[[ "${#missing_ids[@]}" -eq 0 ]] || fail "evidence file is missing required item id(s): ${missing_ids[*]}"

blocked=()
if echo "$text" | grep -Eq '(/Users/|/Volumes/|file:///Users/|file:///Volumes/)'; then
  blocked+=("local path")
fi
if echo "$text" | grep -Eq '(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})'; then
  blocked+=("token-like secret")
fi
[[ "${#blocked[@]}" -eq 0 ]] || fail "possible private content found: ${blocked[*]}"

requires_structured_evidence() {
  [[ "${STRICT_EXTERNAL_VERIFICATION:-0}" == "1" || "${STRICT_EXTERNAL_STRUCTURE_ONLY:-0}" == "1" ]]
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

require_screenshot_set_coverage() {
  local value_lc
  value_lc="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"
  local missing=()
  contains_any "$value_lc" "writing" || missing+=("writing")
  contains_any "$value_lc" "ai chat" "ai-chat" || missing+=("ai-chat")
  contains_any "$value_lc" "sync/api publish" "sync api publish" "sync-api-publish" || missing+=("sync-api-publish")
  contains_any "$value_lc" "seo/social preview" "seo social preview" "seo-social-preview" || missing+=("seo-social-preview")
  contains_any "$value_lc" "deployment" "deployment-status" || missing+=("deployment-status")
  contains_any "$value_lc" "maintenance" || missing+=("maintenance")
  contains_any "$value_lc" "general drafts" "general-drafts" "通用草稿" || missing+=("general-drafts")
  contains_any "$value_lc" "pro" "pro-settings" || missing+=("pro-settings")
  contains_any "$value_lc" "privacy lock" "privacy-lock" || missing+=("privacy-lock")
  contains_any "$value_lc" "release readiness" "release-readiness" "release gate" || missing+=("release-readiness")
  [[ "${#missing[@]}" -eq 0 ]] || fail "app-store-screenshots evidence Screenshot set is missing required screen(s): ${missing[*]}"
}

require_labels_for_completed_item() {
  local item_id="$1"
  shift
  local labels=("$@")
  if grep -Eq "^- \[[xX]\][[:space:]]+\`$item_id\`" "$EVIDENCE_FILE"; then
    local missing_labels=()
    for label in "${labels[@]}"; do
      if ! grep -q "$label" "$EVIDENCE_FILE"; then
        missing_labels+=("$label")
      fi
    done
    if requires_structured_evidence && [[ "${#missing_labels[@]}" -gt 0 ]]; then
      fail "$item_id evidence is missing structured field(s): ${missing_labels[*]}"
    fi
  fi
}

section_for_heading() {
  local heading="$1"
  awk -v heading="$heading" '
    $0 == heading { capture = 1; next }
    /^### / && capture { capture = 0 }
    capture { print }
  ' "$EVIDENCE_FILE"
}

reject_completed_item_placeholders() {
  local item_id="$1"
  local heading="$2"
  if grep -Eq "^- \[[xX]\][[:space:]]+\`$item_id\`" "$EVIDENCE_FILE"; then
    local evidence_section
    evidence_section="$(section_for_heading "$heading")"
    if requires_structured_evidence && printf "%s" "$evidence_section" | grep -Eiq '(todo|pending|not verified|not checked|not confirmed|waiting for|missing|待填写|待验证|待确认|未验证|未确认)'; then
      fail "$item_id evidence still contains pending online verification placeholder text"
    fi
  fi
}

require_labels_for_completed_item github-direct-publish \
  "Token scope:" \
  "Commit SHA:" \
  "Deployment status:" \
  "Release ledger:"

require_labels_for_completed_item github-review-publish \
  "PR URL:" \
  "Provider review artifact:" \
  "Review branch:" \
  "Target branch:" \
  "File changes:" \
  "Deployment status:" \
  "Release ledger:" \
  "Rollback draft:"

require_labels_for_completed_item gitlab-direct-publish \
  "Token scope:" \
  "Commit SHA:" \
  "Pipeline or Pages status:" \
  "Release ledger:"

require_labels_for_completed_item gitlab-review-publish \
  "MR URL:" \
  "Provider review artifact:" \
  "Source branch:" \
  "Target branch:" \
  "File changes:" \
  "Deployment status:" \
  "Release ledger:" \
  "Rollback draft:"

reject_completed_item_placeholders github-direct-publish "### GitHub API 直接提交"
reject_completed_item_placeholders github-review-publish "### GitHub PR 发布"
reject_completed_item_placeholders gitlab-direct-publish "### GitLab API 直接提交"
reject_completed_item_placeholders gitlab-review-publish "### GitLab MR 发布"

if grep -Eq "^- \[[xX]\][[:space:]]+\`remote-conflict-deployment-rollback\`" "$EVIDENCE_FILE"; then
  remote_labels=(
    "Remote conflict preview:"
    "Pending/offline state:"
    "Deployment retry:"
    "Rollback package:"
  )
  missing_remote_labels=()
  for label in "${remote_labels[@]}"; do
    if ! grep -q "$label" "$EVIDENCE_FILE"; then
      missing_remote_labels+=("$label")
    fi
  done
  if requires_structured_evidence && [[ "${#missing_remote_labels[@]}" -gt 0 ]]; then
    fail "remote-conflict-deployment-rollback evidence is missing structured field(s): ${missing_remote_labels[*]}"
  fi
  remote_evidence_section="$(section_for_heading "### 远端冲突、部署和回滚")"
  if requires_structured_evidence && printf "%s" "$remote_evidence_section" | grep -Eiq '(todo|not verified|not checked|not confirmed|waiting for|missing rollback|missing deployment|missing conflict|待填写|待验证|未验证|未确认)'; then
    fail "remote-conflict-deployment-rollback evidence still contains pending recovery verification placeholder text"
  fi
fi

if grep -Eq "^- \[[xX]\][[:space:]]+\`storekit-sandbox\`" "$EVIDENCE_FILE"; then
  storekit_labels=(
    "StoreKit product lookup:"
    "StoreKit purchase:"
    "StoreKit restore:"
    "StoreKit free quota:"
    "StoreKit boundary events:"
  )
  missing_storekit_labels=()
  for label in "${storekit_labels[@]}"; do
    if ! grep -q "$label" "$EVIDENCE_FILE"; then
      missing_storekit_labels+=("$label")
    fi
  done
  if requires_structured_evidence && [[ "${#missing_storekit_labels[@]}" -gt 0 ]]; then
    fail "storekit-sandbox evidence is missing structured field(s): ${missing_storekit_labels[*]}"
  fi
  if requires_structured_evidence && grep -Eiq '(pending sandbox purchase|pending restore check|pending sandbox|confirm app store sandbox|confirm entitlement source changes|confirm pro unlock|use the pro settings purchase button|use restore purchase|待核验|待验证)' "$EVIDENCE_FILE"; then
    fail "storekit-sandbox evidence still contains pending sandbox verification placeholder text"
  fi
fi

if grep -Eq "^- \[[xX]\][[:space:]]+\`app-store-screenshots\`" "$EVIDENCE_FILE"; then
  screenshot_labels=(
    "Screenshot set:"
    "Screenshot privacy gate:"
    "Screenshot strict gate:"
  )
  missing_screenshot_labels=()
  for label in "${screenshot_labels[@]}"; do
    if ! grep -q "$label" "$EVIDENCE_FILE"; then
      missing_screenshot_labels+=("$label")
    fi
  done
  if requires_structured_evidence && [[ "${#missing_screenshot_labels[@]}" -gt 0 ]]; then
    fail "app-store-screenshots evidence is missing structured field(s): ${missing_screenshot_labels[*]}"
  fi
  if requires_structured_evidence && [[ "${#missing_screenshot_labels[@]}" -eq 0 ]]; then
    screenshot_set_line="$(grep -i "Screenshot set:" "$EVIDENCE_FILE" | tail -n 1)"
    require_screenshot_set_coverage "$screenshot_set_line"
  fi
  if requires_structured_evidence && grep -Eiq '(pending capture|pending screenshot|pending privacy|pending strict|todo|not captured|missing screenshot|waiting for screenshot|待采集|待截图|待验证)' "$EVIDENCE_FILE"; then
    fail "app-store-screenshots evidence still contains pending screenshot verification placeholder text"
  fi
fi

if [[ "${STRICT_EXTERNAL_VERIFICATION:-0}" == "1" && "${#unchecked_ids[@]}" -gt 0 ]]; then
  fail "strict mode requires completed external evidence for: ${unchecked_ids[*]}"
fi

completed_count=$(grep -Ec "^- \[[xX]\][[:space:]]+\`($(IFS='|'; echo "${required_ids[*]}"))\`" "$EVIDENCE_FILE" || true)
if [[ "${#unchecked_ids[@]}" -gt 0 ]]; then
  echo "external verification gate: evidence template covers ${#required_ids[@]} required items; completed: $completed_count; missing completion: ${unchecked_ids[*]}"
else
  echo "external verification gate: evidence complete for ${#required_ids[@]} required items"
fi
