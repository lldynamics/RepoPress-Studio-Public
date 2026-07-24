# External Verification Evidence

Record only redacted evidence. Do not paste tokens, authorization headers, local filesystem paths, private article text, or personal account identifiers.

## Required Evidence

- [ ] `github-direct-publish` - GitHub direct commit evidence: test repository, least-privilege token scope summary, commit SHA, deployment status, and release ledger entry.
- [ ] `github-review-publish` - GitHub PR evidence: PR URL, provider API PR number/state, review branch, target branch, file changes, deployment status, and rollback draft.
- [ ] `gitlab-direct-publish` - GitLab direct commit evidence: test project, token scope summary, commit SHA, Pipeline or Pages status, and release ledger entry.
- [ ] `gitlab-review-publish` - GitLab MR evidence: MR URL, provider API MR iid/state, source branch, target branch, file changes, deployment status, and rollback draft.
- [ ] `remote-conflict-deployment-rollback` - Remote conflict, pending/offline deployment, retry, and rollback evidence.
- [ ] `storekit-sandbox` - StoreKit sandbox purchase, restore, entitlement source, free quota, and Pro boundary event evidence.
- [x] `app-store-screenshots` - App Store 截图和严格门禁: 10 App Store screenshots captured; screenshot privacy and strict screenshot gates passed.

## Evidence Notes

Paste short redacted summaries below each completed item before changing `[ ]` to `[x]`.
Prefer the scripts below over manual edits. They reject local paths and token-like strings.

## Live Verification Commands

Use disposable test repositories and least-privilege tokens. These commands update this file only after a live provider API call succeeds.
By default, live verification only writes files under `codex-live-verification/` and review branches under `codex/live-verify-*`.
Only set `REMOTE_VERIFY_ALLOW_CUSTOM_PATH=1` or `REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH=1` for a disposable repository where those custom targets are intentional.
The live verifier checks GitHub Pages/Actions or GitLab Pipeline status after the API publish. Set `REMOTE_VERIFY_DEPLOYMENT_STATUS` only when you need to replace that auto-collected status with a more specific redacted summary.
For disposable review-mode runs, set `REMOTE_VERIFY_REVIEW_CLEANUP=1` only when you want the verifier to close the created PR/MR and delete the temporary review branch after deployment status is checked.
Prepare private env files outside the repository before filling real token and repository values:

```sh
script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target remote-publish
source /private/tmp/personal-site-publisher-release-envs/remote-publish-live.env
```

```sh
# Preferred matrix run after preparing both disposable test repositories:
REMOTE_VERIFY_GITHUB_TOKEN="<redacted>" REMOTE_VERIFY_GITHUB_OWNER="owner" REMOTE_VERIFY_GITHUB_REPO="test-site" \
REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER="Release ledger contains the GitHub online direct publish entry and deployment check." \
REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER="Release ledger contains the GitHub PR publish entry and deployment check." \
REMOTE_VERIFY_GITLAB_TOKEN="<redacted>" REMOTE_VERIFY_GITLAB_OWNER="group" REMOTE_VERIFY_GITLAB_REPO="test-site" \
REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER="Release ledger contains the GitLab online direct publish entry and deployment check." \
REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER="Release ledger contains the GitLab MR publish entry and deployment check." \
  script/verify_remote_publish_live_matrix.sh --execute

REMOTE_VERIFY_TOKEN="<redacted>" REMOTE_VERIFY_OWNER="owner" REMOTE_VERIFY_REPO="test-site" \
REMOTE_VERIFY_RELEASE_LEDGER="Release ledger contains the online direct publish entry and deployment check." \
  script/verify_remote_publish_live.sh --provider github --mode direct --execute

REMOTE_VERIFY_TOKEN="<redacted>" REMOTE_VERIFY_OWNER="owner" REMOTE_VERIFY_REPO="test-site" \
  script/verify_remote_publish_live.sh --provider github --mode review --execute

REMOTE_VERIFY_TOKEN="<redacted>" REMOTE_VERIFY_OWNER="group" REMOTE_VERIFY_REPO="test-site" \
REMOTE_VERIFY_RELEASE_LEDGER="Release ledger contains the GitLab direct publish entry and deployment check." \
  script/verify_remote_publish_live.sh --provider gitlab --mode direct --execute

REMOTE_VERIFY_TOKEN="<redacted>" REMOTE_VERIFY_OWNER="group" REMOTE_VERIFY_REPO="test-site" \
  script/verify_remote_publish_live.sh --provider gitlab --mode review --execute
```

For review-mode live verification, `script/verify_remote_publish_live.sh` generates a redacted rollback draft from the review branch, target branch, and disposable verification path. Set `REMOTE_VERIFY_ROLLBACK_DRAFT` only when you need to replace that generated text with a more specific redacted summary. When `REMOTE_VERIFY_REVIEW_CLEANUP=1`, the cleanup result is appended to that rollback evidence.

## Manual Evidence Commands

Use this only after the external action has actually been performed. Do not use it to mark planned work as complete.
Use `script/prepare_external_verification_envs.sh` to create private copies of
`storekit-sandbox.env.example` and `remote-recovery.env.example` outside the
repository before filling sandbox or recovery summaries.

```sh
script/record_external_verification_evidence.sh --dry-run

script/record_external_verification_evidence.sh \
  --item github-direct-publish \
  --summary "GitHub direct publish verified on disposable test repository." \
  --token-scope "GitHub repository permissions from API reported push=true and the Contents API write succeeded; least-privilege disposable repository token was used." \
  --commit-sha "abc123 redacted test commit." \
  --deployment-status "GitHub Pages or Actions status reached success for the test commit." \
  --release-ledger "Release ledger contains the online direct publish entry and deployment check." \
  --evidence-url "https://github.com/owner/test-site/commit/abc123" \
  --execute

script/record_external_verification_evidence.sh \
  --item github-review-publish \
  --summary "GitHub pull request publishing verified on disposable test repository." \
  --pr-url "https://github.com/owner/test-site/pull/1" \
  --provider-review-artifact "GitHub Pull Request API returned number #1, state open, draft=false." \
  --review-branch "codex/live-verify-github-review" \
  --target-branch "main" \
  --file-changes "Created disposable live verification file through GitHub API." \
  --deployment-status "GitHub Pages or Actions status was checked for the PR branch." \
  --rollback-draft "Rollback draft listed the review branch, file path, and revert path." \
  --execute

script/record_external_verification_evidence.sh \
  --item gitlab-direct-publish \
  --summary "GitLab direct publish verified on disposable test project." \
  --token-scope "GitLab project permissions from API reported Developer-or-higher access_level and the Repository Commits API write succeeded; least-privilege disposable project token was used." \
  --commit-sha "def456 redacted test commit." \
  --deployment-status "GitLab Pipeline or Pages status reached success for the test commit." \
  --release-ledger "Release ledger contains the GitLab direct publish entry and deployment check." \
  --evidence-url "https://gitlab.com/group/test-site/-/commit/def456" \
  --execute

script/record_external_verification_evidence.sh \
  --item gitlab-review-publish \
  --summary "GitLab merge request publishing verified on disposable test project." \
  --mr-url "https://gitlab.com/group/test-site/-/merge_requests/1" \
  --provider-review-artifact "GitLab Merge Request API returned iid !1, state opened, merge status available." \
  --source-branch "codex/live-verify-gitlab-review" \
  --target-branch "main" \
  --file-changes "Created disposable live verification file through GitLab API." \
  --deployment-status "GitLab Pipeline or Pages status was checked for the MR branch." \
  --rollback-draft "Rollback draft listed the source branch, file path, and revert path." \
  --execute

script/record_storekit_sandbox_evidence.sh \
  --product-lookup "Sandbox product lookup loaded personal.site.publisher.pro from the App Store sandbox product catalog." \
  --purchase "Purchase completed and entitlement source changed to StoreKit." \
  --restore "Restore reapplied Pro entitlement after clearing local state." \
  --free-quota "Free quota boundary showed upgrade copy before purchase and no quota consumption after Pro unlock." \
  --boundary-events "Recent Pro boundary events showed free-plan block before purchase and Pro no-quota allow after unlock." \
  --dry-run

script/record_storekit_sandbox_evidence.sh \
  --product-lookup "Sandbox product lookup loaded personal.site.publisher.pro from the App Store sandbox product catalog." \
  --purchase "Purchase completed and entitlement source changed to StoreKit." \
  --restore "Restore reapplied Pro entitlement after clearing local state." \
  --free-quota "Free quota boundary showed upgrade copy before purchase and no quota consumption after Pro unlock." \
  --boundary-events "Recent Pro boundary events showed free-plan block before purchase and Pro no-quota allow after unlock." \
  --execute

script/record_remote_recovery_evidence.sh \
  --remote-conflict-preview "Direct publish was blocked after a same-path remote edit; conflict package listed the changed path." \
  --pending-offline-state "Failed or unknown deployment state was kept as pending retry in the release ledger." \
  --deployment-retry "Deployment polling and manual retry refreshed the provider status." \
  --rollback-package "Rollback package included branch, files, and PR/MR draft URL." \
  --dry-run

script/record_remote_recovery_evidence.sh \
  --remote-conflict-preview "Direct publish was blocked after a same-path remote edit; conflict package listed the changed path." \
  --pending-offline-state "Failed or unknown deployment state was kept as pending retry in the release ledger." \
  --deployment-retry "Deployment polling and manual retry refreshed the provider status." \
  --rollback-package "Rollback package included branch, files, and PR/MR draft URL." \
  --execute

script/record_external_verification_evidence.sh \
  --item app-store-screenshots \
  --summary "Nine manifest screenshots captured; screenshot privacy and strict screenshot gates passed." \
  --screenshot-set "Captured manifest screenshot IDs: writing, ai-chat, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock." \
  --screenshot-privacy-gate "check_screenshot_privacy.sh passed with no local paths, tokens, or private article text." \
  --screenshot-strict-gate "STRICT_SCREENSHOTS=1 check_screenshots.sh and strict release gate output were reviewed." \
  --screenshot-source-fingerprint "$(script/screenshot_evidence_fingerprint.py)" \
  --execute

# Preferred shortcut after all screenshot files are captured:
script/record_app_store_screenshot_evidence.sh --execute
```

### App Store 截图和严格门禁
- Nine manifest screenshots captured; screenshot privacy and strict screenshot gates passed.
- Screenshot set: Captured manifest screenshot IDs: writing, ai-chat, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.
- Screenshot privacy gate: check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.
- Screenshot strict gate: STRICT_SCREENSHOTS=1 check_screenshots.sh and screenshot manifest sync passed.
- Screenshot source fingerprint: stale legacy evidence; recapture required.
- 9 App Store screenshots captured; screenshot privacy and strict screenshot gates passed.
- Screenshot set: Captured manifest screenshot IDs: writing, ai-chat, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.
- Screenshot privacy gate: check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.
- Screenshot strict gate: STRICT_SCREENSHOTS=1 check_screenshots.sh and screenshot manifest sync passed.
- Screenshot source fingerprint: sha256:64c53923544993c231c2ac6683e3b268b05ca53635398299965e24efe91c5a9f
- 9 App Store screenshots captured; screenshot privacy and strict screenshot gates passed.
- Screenshot set: Captured manifest screenshot IDs: writing, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.
- Screenshot privacy gate: check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.
- Screenshot strict gate: STRICT_SCREENSHOTS=1 check_screenshots.sh and screenshot manifest sync passed.
- Screenshot source fingerprint: sha256:b16c650465d9acf349b13114cafdd65c59818ebfc51983dc02cedc16a7111953
- 9 App Store screenshots captured; screenshot privacy and strict screenshot gates passed.
- Screenshot set: Captured manifest screenshot IDs: writing, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.
- Screenshot privacy gate: check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.
- Screenshot strict gate: STRICT_SCREENSHOTS=1 check_screenshots.sh and screenshot manifest sync passed.
- Screenshot source fingerprint: sha256:be62cbd7dc4a0515df0ed053d9733b8e272232e7add1381f5f98f9355ffb81d7
- 9 App Store screenshots captured; screenshot privacy and strict screenshot gates passed.
- Screenshot set: Captured manifest screenshot IDs: writing, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.
- Screenshot privacy gate: check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.
- Screenshot strict gate: STRICT_SCREENSHOTS=1 check_screenshots.sh and screenshot manifest sync passed.
- Screenshot source fingerprint: sha256:5ebd59b16247b3408a194d9d192e09f905111a2918596365e5988c965605880e
- 9 App Store screenshots captured; screenshot privacy and strict screenshot gates passed.
- Screenshot set: Captured manifest screenshot IDs: writing, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.
- Screenshot privacy gate: check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.
- Screenshot strict gate: STRICT_SCREENSHOTS=1 check_screenshots.sh and screenshot manifest sync passed.
- Screenshot source fingerprint: sha256:e1a74c08e164072cfd2a46a9de4f1fb591afba70030c68437e61d1516f6e379e
- 10 App Store screenshots captured; screenshot privacy and strict screenshot gates passed.
- Screenshot set: Captured manifest screenshot IDs: writing, ai-chat, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.
- Screenshot privacy gate: check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.
- Screenshot strict gate: STRICT_SCREENSHOTS=1 check_screenshots.sh and screenshot manifest sync passed.
- Screenshot source fingerprint: sha256:7ba3f5dbc31bf943cd555fc9af3ef5ea54e448649c4ce5190c9db3bb3734d304
