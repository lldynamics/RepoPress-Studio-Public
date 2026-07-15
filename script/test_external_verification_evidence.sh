#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-external-evidence.XXXXXX)"
EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
SCREENSHOT_FINGERPRINT="$(python3 "$ROOT_DIR/script/screenshot_evidence_fingerprint.py")"
SCREENSHOT_DIR="$TMP_DIR/app-store-screenshots"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "external verification evidence test: $*" >&2
  exit 1
}

cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$EVIDENCE_FILE"
mkdir -p "$SCREENSHOT_DIR"
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  printf 'fixture image for %s\n' "$id" >"$SCREENSHOT_DIR/$id.png"
  python3 "$ROOT_DIR/script/screenshot_capture_provenance.py" record \
    --root "$ROOT_DIR" \
    --manifest "$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md" \
    --screenshot-dir "$SCREENSHOT_DIR" \
    --id "$id" \
    --image "$SCREENSHOT_DIR/$id.png" >/dev/null
done < <(sed -nE 's/^\| `([^`]+)` \|.*/\1/p' "$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md")

assert_strict_rejects_legacy_item() {
  local item_id="$1"
  local legacy_file="$TMP_DIR/${item_id}.md"
  cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$legacy_file"
  python3 - "$legacy_file" "$item_id" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
item_id = sys.argv[2]
text = path.read_text()
text = re.sub(
    rf"^- \[ \] `{re.escape(item_id)}` - .*$",
    f"- [x] `{item_id}` - Legacy evidence without structured fields.",
    text,
    count=1,
    flags=re.MULTILINE,
)
path.write_text(text)
PY
  if STRICT_EXTERNAL_VERIFICATION=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$legacy_file" \
    bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1; then
    fail "strict gate accepted legacy $item_id evidence without structured fields"
  fi
}

assert_strict_rejects_pending_item() {
  local item_id="$1"
  local pending_file="$TMP_DIR/${item_id}-pending.md"
  cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$pending_file"
  python3 - "$pending_file" "$item_id" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
item_id = sys.argv[2]
sections = {
    "github-direct-publish": (
        "GitHub API 直接提交",
        [
            "- Pending online publish evidence.",
            "- Token scope: Not verified with provider API.",
            "- Commit SHA: Missing commit SHA.",
            "- Deployment status: Waiting for GitHub Pages status.",
            "- Release ledger: TODO record release ledger entry.",
        ],
    ),
    "github-review-publish": (
        "GitHub PR 发布",
        [
            "- Pending GitHub PR evidence.",
            "- PR URL: https://github.com/example/test-site/pull/1",
            "- Provider review artifact: Pending PR API response.",
            "- Review branch: codex/live-verify-github-review",
            "- Target branch: main",
            "- File changes: Missing file change review.",
            "- Deployment status: Waiting for GitHub Actions status.",
            "- Rollback draft: TODO record rollback draft.",
        ],
    ),
    "gitlab-direct-publish": (
        "GitLab API 直接提交",
        [
            "- Pending GitLab direct evidence.",
            "- Token scope: Not checked with GitLab API.",
            "- Commit SHA: Missing commit SHA.",
            "- Pipeline or Pages status: Waiting for GitLab pipeline status.",
            "- Release ledger: TODO record release ledger entry.",
        ],
    ),
    "gitlab-review-publish": (
        "GitLab MR 发布",
        [
            "- Pending GitLab MR evidence.",
            "- MR URL: https://gitlab.com/example/test-site/-/merge_requests/1",
            "- Provider review artifact: Pending MR API response.",
            "- Source branch: codex/live-verify-gitlab-review",
            "- Target branch: main",
            "- File changes: Missing file change review.",
            "- Deployment status: Waiting for GitLab Pages status.",
            "- Rollback draft: TODO record rollback draft.",
        ],
    ),
}
title, lines = sections[item_id]
text = path.read_text()
text = re.sub(
    rf"^- \[ \] `{re.escape(item_id)}` - .*$",
    f"- [x] `{item_id}` - {title}: Pending placeholder evidence.",
    text,
    count=1,
    flags=re.MULTILINE,
)
text = text.rstrip() + f"\n\n### {title}\n" + "\n".join(lines) + "\n"
path.write_text(text)
PY
  if STRICT_EXTERNAL_VERIFICATION=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$pending_file" \
    bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1; then
    fail "strict gate accepted pending $item_id evidence"
  fi
}

if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item github-direct-publish \
  --summary "GitHub direct commit verified on disposable test repository." \
  --dry-run >/dev/null 2>&1; then
  fail "GitHub direct evidence accepted without structured fields"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item github-review-publish \
  --summary "GitHub pull request publishing verified on disposable test repository." \
  --dry-run >/dev/null 2>&1; then
  fail "GitHub review evidence accepted without structured fields"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item gitlab-direct-publish \
  --summary "GitLab direct commit verified on disposable test project." \
  --dry-run >/dev/null 2>&1; then
  fail "GitLab direct evidence accepted without structured fields"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item gitlab-review-publish \
  --summary "GitLab merge request publishing verified on disposable test project." \
  --dry-run >/dev/null 2>&1; then
  fail "GitLab review evidence accepted without structured fields"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item remote-conflict-deployment-rollback \
  --summary "Remote conflict preview, pending/offline deployment state, retry, deployment polling, and rollback guidance verified on disposable test content." \
  --dry-run >/dev/null 2>&1; then
  fail "remote conflict evidence accepted without structured fields"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item storekit-sandbox \
  --summary "StoreKit sandbox purchase, restore, entitlement source, and free quota boundary verified with redacted sandbox account." \
  --dry-run >/dev/null 2>&1; then
  fail "StoreKit evidence accepted without structured fields"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item app-store-screenshots \
  --summary "Nine manifest screenshots captured; screenshot privacy and strict screenshot gates passed." \
  --dry-run >/dev/null 2>&1; then
  fail "screenshot evidence accepted without structured fields"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item app-store-screenshots \
  --summary "Nine manifest screenshots captured; screenshot privacy and strict screenshot gates passed." \
  --screenshot-set "Captured writing and AI chat screens." \
  --screenshot-privacy-gate "check_screenshot_privacy.sh passed with no local paths or tokens." \
  --screenshot-strict-gate "STRICT_SCREENSHOTS=1 check_screenshots.sh passed." \
  --dry-run >/dev/null 2>&1; then
  fail "screenshot evidence accepted an incomplete screenshot set"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item github-direct-publish \
  --summary "GitHub direct commit verified on disposable test repository." \
  --token-scope "Least-privilege contents write token was confirmed by GitHub API." \
  --commit-sha "abc123 redacted test commit." \
  --deployment-status "GitHub Pages or Actions status reached success for the test commit." \
  --release-ledger "Release ledger contains the online direct publish entry and deployment check." \
  --evidence-url "http://github.com/example/test-site/commit/abc123" \
  --dry-run >/dev/null 2>&1; then
  fail "GitHub direct evidence accepted a non-https evidence URL"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item github-direct-publish \
  --summary "GitHub direct commit pending verification." \
  --token-scope "Least-privilege contents write token was confirmed by GitHub API." \
  --commit-sha "abc123 redacted test commit." \
  --deployment-status "GitHub Pages or Actions status reached success for the test commit." \
  --release-ledger "Release ledger contains the online direct publish entry and deployment check." \
  --dry-run >/dev/null 2>&1; then
  fail "GitHub direct evidence accepted pending placeholder text"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item github-direct-publish \
  --summary "GitHub direct commit verified on disposable test repository." \
  --token-scope "Least-privilege contents write token was confirmed by GitHub API." \
  --commit-sha "abc123 redacted test commit." \
  --deployment-status "GitHub Pages or Actions status reached success for the test commit." \
  --release-ledger "Release ledger contains online publish evidence." \
  --dry-run >/dev/null 2>&1; then
  fail "GitHub direct evidence accepted release ledger without direct publish coverage"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item github-review-publish \
  --summary "GitHub pull request publishing verified on disposable test repository." \
  --pr-url "https://github.com/example/test-site/pull/1" \
  --review-branch "codex/live-verify-github-review" \
  --target-branch "main" \
  --file-changes "Created disposable live verification file through GitHub API." \
  --deployment-status "GitHub Pages or Actions status was checked for the PR branch." \
  --release-ledger "Release ledger contains the GitHub PR publish entry, review branch, and deployment check." \
  --rollback-draft "Rollback draft listed the review branch, file path, and revert path." \
  --dry-run >/dev/null 2>&1; then
  fail "GitHub review evidence accepted missing provider review artifact"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item github-review-publish \
  --summary "GitHub pull request publishing verified on disposable test repository." \
  --pr-url "https://github.com/example/test-site/pull/1" \
  --provider-review-artifact "GitHub Pull Request API returned number #1, state open, draft=false." \
  --review-branch "codex/live-verify-github-review" \
  --target-branch "main" \
  --file-changes "Created disposable live verification file through GitHub API." \
  --deployment-status "GitHub Pages or Actions status was checked for the PR branch." \
  --release-ledger "Release ledger contains only the online direct publish entry and deployment check." \
  --rollback-draft "Rollback draft listed the review branch, file path, and revert path." \
  --dry-run >/dev/null 2>&1; then
  fail "GitHub review evidence accepted release ledger without PR/review coverage"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item gitlab-review-publish \
  --summary "GitLab merge request publishing verified on disposable test project." \
  --mr-url "https://gitlab.com/example/test-site/-/merge_requests/1" \
  --provider-review-artifact "GitLab Merge Request API returned iid !1, state opened, merge status available." \
  --source-branch "codex/live-verify-gitlab-review" \
  --target-branch "main" \
  --file-changes "Created disposable live verification file through GitLab API." \
  --deployment-status "Waiting for GitLab Pages status." \
  --release-ledger "Release ledger contains the GitLab MR publish entry, source branch, and deployment check." \
  --rollback-draft "Rollback draft listed the source branch, file path, and revert path." \
  --dry-run >/dev/null 2>&1; then
  fail "GitLab review evidence accepted pending placeholder text"
fi
if EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
  --item gitlab-review-publish \
  --summary "GitLab merge request publishing verified on disposable test project." \
  --mr-url "https://gitlab.com/example/test-site/-/merge_requests/1" \
  --provider-review-artifact "GitLab Merge Request API returned iid !1, state opened, merge status available." \
  --source-branch "codex/live-verify-gitlab-review" \
  --target-branch "main" \
  --file-changes "Created disposable live verification file through GitLab API." \
  --deployment-status "GitLab Pipeline or Pages status was checked for the MR branch." \
  --release-ledger "Release ledger contains only the GitLab direct publish entry and deployment check." \
  --rollback-draft "Rollback draft listed the source branch, file path, and revert path." \
  --dry-run >/dev/null 2>&1; then
  fail "GitLab review evidence accepted release ledger without MR/review coverage"
fi
assert_strict_rejects_legacy_item github-direct-publish
assert_strict_rejects_legacy_item github-review-publish
assert_strict_rejects_legacy_item gitlab-direct-publish
assert_strict_rejects_legacy_item gitlab-review-publish
assert_strict_rejects_legacy_item remote-conflict-deployment-rollback
assert_strict_rejects_legacy_item storekit-sandbox
assert_strict_rejects_legacy_item app-store-screenshots
assert_strict_rejects_pending_item github-direct-publish
assert_strict_rejects_pending_item github-review-publish
assert_strict_rejects_pending_item gitlab-direct-publish
assert_strict_rejects_pending_item gitlab-review-publish

incomplete_screenshot_file="$TMP_DIR/app-store-screenshots-incomplete.md"
cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$incomplete_screenshot_file"
python3 - "$incomplete_screenshot_file" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"^- \[ \] `app-store-screenshots` - .*$",
    "- [x] `app-store-screenshots` - App Store screenshot evidence with incomplete set.",
    text,
    count=1,
    flags=re.MULTILINE,
)
text = text.rstrip() + """

### App Store 截图和严格门禁
- Nine manifest screenshots captured; screenshot privacy and strict screenshot gates passed.
- Screenshot set: Captured writing and AI chat screens.
- Screenshot privacy gate: check_screenshot_privacy.sh passed with no local paths or tokens.
- Screenshot strict gate: STRICT_SCREENSHOTS=1 check_screenshots.sh passed.
"""
path.write_text(text)
PY
if STRICT_EXTERNAL_VERIFICATION=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$incomplete_screenshot_file" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1; then
  fail "strict gate accepted app-store-screenshots evidence with an incomplete screenshot set"
fi

custom_manifest="$TMP_DIR/custom-screenshot-manifest.md"
cat >"$custom_manifest" <<'MD'
| ID | Target file | Screen | Purpose | Status |
| --- | --- | --- | --- | --- |
| `writing` | `writing.png` | Writing | Test | Captured |
| `custom-screen` | `custom-screen.png` | Custom | Test | Captured |
MD
if SCREENSHOT_MANIFEST_FILE="$custom_manifest" EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
    --item app-store-screenshots \
    --summary "All manifest screenshots captured and gates passed." \
    --screenshot-set "Captured manifest screenshot IDs: writing." \
    --screenshot-privacy-gate "Screenshot privacy gate passed." \
    --screenshot-strict-gate "Strict screenshot gate passed." \
    --dry-run >/dev/null 2>&1; then
  fail "screenshot evidence recorder ignored a required ID added to the manifest"
fi
SCREENSHOT_MANIFEST_FILE="$custom_manifest" EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/record_external_verification_evidence.sh" \
    --item app-store-screenshots \
    --summary "All manifest screenshots captured and gates passed." \
    --screenshot-set "Captured manifest screenshot IDs: writing, custom-screen." \
    --screenshot-privacy-gate "Screenshot privacy gate passed." \
    --screenshot-strict-gate "Strict screenshot gate passed." \
    --screenshot-source-fingerprint "$(python3 "$ROOT_DIR/script/screenshot_evidence_fingerprint.py" --manifest "$custom_manifest")" \
    --dry-run >/dev/null 2>&1 \
  || fail "screenshot evidence recorder rejected all IDs from a custom manifest"

custom_check_file="$TMP_DIR/custom-screenshot-check.md"
cp "$EVIDENCE_FILE" "$custom_check_file"
perl -0pi -e 's/- \[ \] `app-store-screenshots`/- [x] `app-store-screenshots`/' "$custom_check_file"
if SCREENSHOT_MANIFEST_FILE="$custom_manifest" STRICT_EXTERNAL_STRUCTURE_ONLY=1 \
  EXTERNAL_VERIFY_EVIDENCE_FILE="$custom_check_file" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1; then
  fail "strict evidence checker ignored a required ID added to the manifest"
fi
custom_evidence="$TMP_DIR/custom-screenshot-evidence.md"
cp "$EVIDENCE_FILE" "$custom_evidence"
perl -0pi -e 's/(Screenshot set: .*privacy-lock)\./$1, custom-screen./' "$custom_evidence"
SCREENSHOT_MANIFEST_FILE="$custom_manifest" STRICT_EXTERNAL_STRUCTURE_ONLY=1 \
  EXTERNAL_VERIFY_EVIDENCE_FILE="$custom_evidence" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1 \
  || fail "strict evidence checker rejected all IDs from a custom manifest"

record() {
  EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/record_external_verification_evidence.sh" "$@" --execute >/dev/null
}

record --item github-direct-publish \
  --summary "GitHub direct commit verified on disposable test repository." \
  --token-scope "Least-privilege contents write token was confirmed by GitHub API." \
  --commit-sha "abc123 redacted test commit." \
  --deployment-status "GitHub Pages or Actions status reached success for the test commit." \
  --release-ledger "Release ledger contains the online direct publish entry and deployment check." \
  --evidence-url "https://github.com/example/test-site/commit/abc123"
record --item github-review-publish \
  --summary "GitHub pull request publishing verified on disposable test repository." \
  --pr-url "https://github.com/example/test-site/pull/1" \
  --provider-review-artifact "GitHub Pull Request API returned number #1, state open, draft=false." \
  --review-branch "codex/live-verify-github-review" \
  --target-branch "main" \
  --file-changes "Created disposable live verification file through GitHub API." \
  --deployment-status "GitHub Pages or Actions status was checked for the PR branch." \
  --release-ledger "Release ledger contains the GitHub PR publish entry, review branch, and deployment check." \
  --rollback-draft "Rollback draft listed the review branch, file path, and revert path."
record --item gitlab-direct-publish \
  --summary "GitLab direct commit verified on disposable test project." \
  --token-scope "Least-privilege project write token was confirmed by GitLab API." \
  --commit-sha "def456 redacted test commit." \
  --deployment-status "GitLab Pipeline or Pages status reached success for the test commit." \
  --release-ledger "Release ledger contains the GitLab direct publish entry and deployment check." \
  --evidence-url "https://gitlab.com/example/test-site/-/commit/def456"
record --item gitlab-review-publish \
  --summary "GitLab merge request publishing verified on disposable test project." \
  --mr-url "https://gitlab.com/example/test-site/-/merge_requests/1" \
  --provider-review-artifact "GitLab Merge Request API returned iid !1, state opened, merge status available." \
  --source-branch "codex/live-verify-gitlab-review" \
  --target-branch "main" \
  --file-changes "Created disposable live verification file through GitLab API." \
  --deployment-status "GitLab Pipeline or Pages status was checked for the MR branch." \
  --release-ledger "Release ledger contains the GitLab MR publish entry, source branch, and deployment check." \
  --rollback-draft "Rollback draft listed the source branch, file path, and revert path."
record --item remote-conflict-deployment-rollback \
  --summary "Remote conflict preview, pending/offline deployment state, retry, deployment polling, and rollback guidance verified on disposable test content." \
  --remote-conflict-preview "Direct publish was blocked after a same-path remote edit; conflict package listed the changed path." \
  --pending-offline-state "Failed or unknown deployment state was kept as pending retry in the release ledger." \
  --deployment-retry "Deployment polling and manual retry refreshed the provider status." \
  --rollback-package "Rollback package included branch, files, and PR/MR draft URL."
record --item storekit-sandbox \
  --summary "StoreKit sandbox purchase, restore, entitlement source, and free quota boundary verified with redacted sandbox account." \
  --storekit-product-lookup "Sandbox loaded product personal.site.publisher.pro with localized price and copy." \
  --storekit-purchase "Purchase completed and entitlement source changed to StoreKit." \
  --storekit-restore "Restore reapplied Pro entitlement after clearing local state." \
  --storekit-free-quota "Free quota boundary showed upgrade copy before purchase and no quota consumption after Pro unlock." \
  --storekit-boundary-events "Recent Pro boundary events showed free-plan block before purchase and Pro no-quota allow after unlock."
record --item app-store-screenshots \
  --summary "Nine manifest screenshots captured; screenshot privacy and strict screenshot gates passed." \
  --screenshot-set "Captured manifest screenshot IDs: writing, ai-chat, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock." \
  --screenshot-privacy-gate "check_screenshot_privacy.sh passed with no local paths, tokens, or private article text." \
  --screenshot-strict-gate "STRICT_SCREENSHOTS=1 check_screenshots.sh and strict release gate output were reviewed." \
  --screenshot-source-fingerprint "$SCREENSHOT_FINGERPRINT"

STRICT_EXTERNAL_VERIFICATION=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null

grep -q 'Evidence URL: https://github.com/example/test-site/commit/abc123' "$EVIDENCE_FILE" \
  || fail "GitHub direct evidence URL was not written"
grep -q 'Evidence URL: https://gitlab.com/example/test-site/-/commit/def456' "$EVIDENCE_FILE" \
  || fail "GitLab direct evidence URL was not written"

echo "external verification evidence test: passed"
