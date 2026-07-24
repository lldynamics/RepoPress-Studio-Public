#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="$ROOT_DIR/script/prepare_external_verification_envs.sh"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-env-prep.XXXXXX)"
OUTPUT_DIR="$TMP_DIR/private-envs"
EVIDENCE_FIXTURE="$TMP_DIR/external-verification-evidence.md"
ARCHIVE_FIXTURE="$TMP_DIR/app-store-archive-evidence.md"

printf '%s\n' \
  '- [ ] `github-direct-publish`' \
  '- [ ] `github-review-publish`' \
  '- [ ] `gitlab-direct-publish`' \
  '- [ ] `gitlab-review-publish`' \
  '- [ ] `remote-conflict-deployment-rollback`' \
  '- [ ] `storekit-sandbox`' \
  '- [x] `app-store-screenshots`' >"$EVIDENCE_FIXTURE"
printf '%s\n' \
  '# App Store Archive Validation Evidence' \
  '- [ ] Clean Release archive produced from a clean checkout.' >"$ARCHIVE_FIXTURE"
export EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FIXTURE"
export APP_STORE_ARCHIVE_EVIDENCE_FILE="$ARCHIVE_FIXTURE"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "external verification env prep test: $*" >&2
  exit 1
}

[[ -f "$PREP" ]] || fail "prepare_external_verification_envs.sh is missing"

required_templates=(
  "docs/release-evidence/remote-publish-live.env.example:remote-publish-live.env:remote-publish"
  "docs/release-evidence/remote-recovery.env.example:remote-recovery.env:remote-recovery"
  "docs/release-evidence/storekit-sandbox.env.example:storekit-sandbox.env:storekit"
  "docs/release-evidence/app-store-screenshots.env.example:app-store-screenshots.env:app-store-screenshots"
  "docs/release-evidence/app-store-archive-validation.env.example:app-store-archive-validation.env:app-store-archive"
)

script_text="$(cat "$PREP")"
for entry in "${required_templates[@]}"; do
  template="${entry%%:*}"
  rest="${entry#*:}"
  target="${rest%%:*}"
  runner_target="${rest##*:}"
  [[ -f "$ROOT_DIR/$template" ]] || fail "required env template is missing: $template"
  [[ "$script_text" == *"$template:$target"* ]] || fail "prep script omits $template:$target"
  template_text="$(cat "$ROOT_DIR/$template")"
  env_status_report="/private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"
  [[ "$template_text" == *"check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target $runner_target --report-file $env_status_report"* ]] \
    || fail "env template omits status-report-aware filled check: $template"
  [[ "$template_text" == *"run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target $runner_target --env-status-report-file $env_status_report"* ]] \
    || fail "env template omits status-report-aware runner dry-run: $template"
  [[ "$template_text" == *"run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target $runner_target --env-status-report-file $env_status_report --execute"* ]] \
    || fail "env template omits status-report-aware runner execute: $template"
  [[ "$template_text" == *"./script/check_release_gate.sh --profile app-store"* ]] \
    || fail "env template omits final App Store gate: $template"
done

dry_output="$(bash "$PREP" --output-dir "$OUTPUT_DIR" --dry-run)"
grep -q "would copy docs/release-evidence/remote-publish-live.env.example" <<<"$dry_output" \
  || fail "dry-run did not describe remote publish copy"
grep -q "source \"$OUTPUT_DIR/remote-publish-live.env\"" <<<"$dry_output" \
  || fail "dry-run did not print source command"
[[ ! -d "$OUTPUT_DIR" ]] || fail "dry-run unexpectedly created output directory"

remaining_dry_output="$(bash "$PREP" --output-dir "$OUTPUT_DIR" --target remaining --dry-run)"
grep -q "external verification env prep: target remaining" <<<"$remaining_dry_output" \
  || fail "remaining dry-run did not report target"
grep -q "would copy docs/release-evidence/remote-publish-live.env.example" <<<"$remaining_dry_output" \
  || fail "remaining dry-run did not include remote publish env"
grep -q "would copy docs/release-evidence/app-store-archive-validation.env.example" <<<"$remaining_dry_output" \
  || fail "remaining dry-run did not include app store archive env"
if grep -q "app-store-screenshots.env.example" <<<"$remaining_dry_output"; then
  fail "remaining dry-run copied screenshot env even though screenshot evidence is complete"
fi

bash "$PREP" --output-dir "$OUTPUT_DIR" >/dev/null

for entry in "${required_templates[@]}"; do
  template="${entry%%:*}"
  rest="${entry#*:}"
  target="${rest%%:*}"
  target_path="$OUTPUT_DIR/$target"
  [[ -f "$target_path" ]] || fail "missing copied env file: $target"
  cmp -s "$ROOT_DIR/$template" "$target_path" || fail "copied env file differs from template: $target"
  mode="$(stat -f "%Lp" "$target_path")"
  [[ "$mode" == "600" ]] || fail "copied env file mode is $mode, expected 600: $target"
done

dir_mode="$(stat -f "%Lp" "$OUTPUT_DIR")"
[[ "$dir_mode" == "700" ]] || fail "output directory mode is $dir_mode, expected 700"

existing_dry_output="$(bash "$PREP" --output-dir "$OUTPUT_DIR" --dry-run)"
grep -q "would copy docs/release-evidence/remote-publish-live.env.example" <<<"$existing_dry_output" \
  || fail "dry-run with existing private env files did not remain reusable"

if bash "$PREP" --output-dir "$OUTPUT_DIR" >/dev/null 2>&1; then
  fail "prep script overwrote existing env files without --force"
fi

bash "$PREP" --output-dir "$OUTPUT_DIR" --force >/dev/null

if bash "$PREP" --output-dir "$ROOT_DIR/docs/release-evidence/private-envs" --dry-run >/dev/null 2>&1; then
  fail "prep script accepted an output directory inside the repository"
fi

if grep -R -Eq 'github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer' "$OUTPUT_DIR"; then
  fail "copied env files contain token-like content"
fi

echo "external verification env prep test: passed"
