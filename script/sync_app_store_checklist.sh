#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKLIST="${APP_STORE_CHECKLIST_FILE:-$ROOT_DIR/APP_STORE_CHECKLIST.md}"
EVIDENCE_FILE="${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
ARCHIVE_EVIDENCE_FILE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md}"
CLEAN_RUNTIME_EVIDENCE_FILE="${CLEAN_RUNTIME_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md}"
EXECUTE=0

usage() {
  cat <<'USAGE'
Usage: script/sync_app_store_checklist.sh [--execute]

Synchronizes APP_STORE_CHECKLIST.md with evidence-backed local gates and
external verification records. By default it previews the changes and does not
write. It never marks clean runtime, archive/upload, StoreKit sandbox,
GitHub/GitLab live publishing, or screenshot capture items complete unless the
matching evidence is already recorded.
USAGE
}

fail() {
  echo "app store checklist sync: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
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

[[ -f "$CHECKLIST" ]] || fail "APP_STORE_CHECKLIST.md is missing"
[[ -f "$EVIDENCE_FILE" ]] || fail "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md is missing"
[[ -f "$ARCHIVE_EVIDENCE_FILE" ]] || fail "docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md is missing"
[[ -f "$CLEAN_RUNTIME_EVIDENCE_FILE" ]] || fail "docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md is missing"

run_gate() {
  local name="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "$name gate failed; not updating checklist"
}

run_gate "localization" bash "$ROOT_DIR/script/check_localization_gate.sh"
run_gate "app store metadata" bash "$ROOT_DIR/script/check_app_store_metadata.sh"
run_gate "app store archive readiness" bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh"
run_gate "ui runtime" bash "$ROOT_DIR/script/check_ui_runtime.sh"
run_gate "clean runtime evidence" env CLEAN_RUNTIME_EVIDENCE_FILE="$CLEAN_RUNTIME_EVIDENCE_FILE" bash "$ROOT_DIR/script/check_clean_runtime_evidence.sh"
run_gate "privacy support copy" bash "$ROOT_DIR/script/check_privacy_support_copy.sh"
run_gate "storekit static" bash "$ROOT_DIR/script/check_storekit.sh"
run_gate "screenshot manifest" bash "$ROOT_DIR/script/check_screenshots.sh"
run_gate "external verification" env STRICT_EXTERNAL_STRUCTURE_ONLY=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" bash "$ROOT_DIR/script/check_external_verification_evidence.sh"
run_gate "screenshot privacy" bash "$ROOT_DIR/script/check_screenshot_privacy.sh"

completed_external_ids() {
  grep -E '^- \[[xX]\][[:space:]]+`[^`]+`' "$EVIDENCE_FILE" \
    | sed -E 's/^- \[[xX]\][[:space:]]+`([^`]+)`.*/\1/' \
    | sort -u
}

has_external_id() {
  local id="$1"
  grep -Eq "^- \[[xX]\][[:space:]]+\`$id\`" "$EVIDENCE_FILE"
}

archive_validation_complete() {
  STRICT_ARCHIVE_EVIDENCE_ONLY=0 APP_STORE_ARCHIVE_EVIDENCE_FILE="$ARCHIVE_EVIDENCE_FILE" \
    bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null 2>&1 || return 1
  local required_checked=(
    "Clean Release archive produced from a clean checkout."
    "Distribution signing and hardened runtime verified on the archive."
    "Archive validated with App Store Connect or Transporter before upload."
  )
  for title in "${required_checked[@]}"; do
    grep -Fq -- "- [x] $title" "$ARCHIVE_EVIDENCE_FILE" \
      || grep -Fq -- "- [X] $title" "$ARCHIVE_EVIDENCE_FILE" \
      || return 1
  done
  ! grep -Eq '^- \[ \]' "$ARCHIVE_EVIDENCE_FILE"
}

clean_runtime_validation_complete() {
  CLEAN_RUNTIME_EVIDENCE_FILE="$CLEAN_RUNTIME_EVIDENCE_FILE" \
    bash "$ROOT_DIR/script/check_clean_runtime_evidence.sh" --strict >/dev/null 2>&1 || return 1
  local required_checked=(
    'App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.'
    "First launch, privacy lock, settings, and workspace switching were verified without exposing private content."
    "Keyboard navigation, focus visibility, VoiceOver labels, and primary commands were smoke checked in the running app."
  )
  for title in "${required_checked[@]}"; do
    grep -Fq -- "- [x] $title" "$CLEAN_RUNTIME_EVIDENCE_FILE" \
      || grep -Fq -- "- [X] $title" "$CLEAN_RUNTIME_EVIDENCE_FILE" \
      || return 1
  done
  ! grep -Eq '^- \[ \]' "$CLEAN_RUNTIME_EVIDENCE_FILE"
}

evidence_for_title() {
  local title_lc="$1"
  if [[ "$title_lc" == *"signing team"* ||
        "$title_lc" == *"hardened runtime"* ]]; then
    archive_validation_complete && {
      echo "已记录归档 app 的 distribution signing 和 hardened runtime 验证证据。"
      return 0
    }
    return 1
  fi
  if [[ "$title_lc" == *"bundle identifier"* ||
        "$title_lc" == *"version"* ||
        "$title_lc" == *"build number"* ||
        "$title_lc" == *"minimum macos"* ||
        "$title_lc" == *"sandbox entitlements"* ]]; then
    echo "App Store 元数据门禁已通过。"
    return 0
  fi
  if [[ "$title_lc" == *"clean release archive"* ||
        "$title_lc" == *"clean checkout"* ]]; then
    archive_validation_complete && {
      echo "已记录 clean checkout 生成 Release archive 的归档验证证据。"
      return 0
    }
    return 1
  fi
  if [[ "$title_lc" == *"validate the archive"* ||
        "$title_lc" == *"app store connect"* ||
        "$title_lc" == *"transporter"* ]]; then
    archive_validation_complete && {
      echo "已记录 Transporter/App Store Connect 归档验证证据。"
      return 0
    }
    return 1
  fi
  if [[ "$title_lc" == *"localization catalog"* ||
        "$title_lc" == *"localizable.strings"* ]]; then
    echo "本地化资源门禁已通过。"
    return 0
  fi
  if [[ "$title_lc" == *"simplified chinese"* ||
        "$title_lc" == *"english copy"* ]]; then
    echo "中英语言覆盖门禁已通过。"
    return 0
  fi
  if [[ "$title_lc" == *"localization gate"* ]]; then
    echo "本地化自动门禁已通过。"
    return 0
  fi
  if [[ "$title_lc" == *"script/build_and_run.sh"* ||
        "$title_lc" == *"clean macos account"* ]]; then
    clean_runtime_validation_complete && {
      echo "已记录 clean macOS account 或等价测试用户运行证据。"
      return 0
    }
    return 1
  fi
  if [[ "$title_lc" == *"keyboard navigation"* ||
        "$title_lc" == *"focus rings"* ||
        "$title_lc" == *"voiceover labels"* ||
        "$title_lc" == *"privacy lock behavior"* ]]; then
    echo "UI runtime/accessibility 门禁已通过。"
    return 0
  fi
  if [[ "$title_lc" == *"screenshot capture"* ||
        "$title_lc" == *"verification script"* ]]; then
    echo "截图采集/验证脚本门禁已覆盖。"
    return 0
  fi
  if [[ "$title_lc" == *"screenshots contain no private"* ||
        "$title_lc" == *"local tokens"* ||
        "$title_lc" == *"personal paths"* ]]; then
    if find "$ROOT_DIR/docs/app-store-screenshots" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | grep -q .; then
      echo "截图隐私门禁已通过。"
      return 0
    fi
    return 1
  fi
  if [[ "$title_lc" == *"privacy policy"* ||
        "$title_lc" == *"support copy"* ||
        "$title_lc" == *"private-content behavior"* ]]; then
    echo "隐私/支持文案门禁已通过，已覆盖隐私锁、私密内容遮挡和敏感信息 redaction 规则。"
    return 0
  fi
  if [[ "$title_lc" == *"storekit"* ||
        "$title_lc" == *"free quota"* ]]; then
    has_external_id "storekit-sandbox" && {
      echo "已记录 StoreKit sandbox 外部验收证据。"
      return 0
    }
    return 1
  fi
  if [[ "$title_lc" == *"github direct"* ]]; then
    has_external_id "github-direct-publish" && has_external_id "github-review-publish" && {
      echo "已记录 GitHub 直接提交和 PR 外部验收证据。"
      return 0
    }
    return 1
  fi
  if [[ "$title_lc" == *"gitlab direct"* ]]; then
    has_external_id "gitlab-direct-publish" && has_external_id "gitlab-review-publish" && {
      echo "已记录 GitLab 直接提交和 MR 外部验收证据。"
      return 0
    }
    return 1
  fi
  if [[ "$title_lc" == *"remote conflict"* ||
        "$title_lc" == *"pending/offline"* ||
        "$title_lc" == *"deployment checks"* ||
        "$title_lc" == *"rollback guidance"* ]]; then
    has_external_id "remote-conflict-deployment-rollback" && {
      echo "已记录远端冲突、部署和回滚外部验收证据。"
      return 0
    }
    return 1
  fi
  if [[ "$title_lc" == *"capture writing"* ||
        "$title_lc" == *"release gate screens"* ]]; then
    has_external_id "app-store-screenshots" && {
      echo "已记录 App Store 截图外部验收证据。"
      return 0
    }
    return 1
  fi
  return 1
}

TMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/app-store-checklist.XXXXXX")"
UPDATED_COUNT_FILE="$(mktemp "${TMPDIR:-/tmp}/app-store-checklist-count.XXXXXX")"
UPDATED_TITLES_FILE="$(mktemp "${TMPDIR:-/tmp}/app-store-checklist-titles.XXXXXX")"
trap 'rm -f "$TMP_OUTPUT" "$UPDATED_COUNT_FILE" "$UPDATED_TITLES_FILE"' EXIT
printf '0' > "$UPDATED_COUNT_FILE"

while IFS= read -r line || [[ -n "$line" ]]; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  if [[ "$trimmed" == "- [ ]"* ]]; then
    title="${trimmed#"- [ ] "}"
    title_lc="$(printf "%s" "$title" | tr '[:upper:]' '[:lower:]')"
    if evidence="$(evidence_for_title "$title_lc")"; then
      leading="${line%%"- [ ]"*}"
      {
        printf "%s- [x] %s\n" "$leading" "$title"
        printf "%s  Evidence: %s\n" "$leading" "$evidence"
      } >> "$TMP_OUTPUT"
      count="$(cat "$UPDATED_COUNT_FILE")"
      printf "%s" "$((count + 1))" > "$UPDATED_COUNT_FILE"
      printf "%s\n" "$title" >> "$UPDATED_TITLES_FILE"
      continue
    fi
  fi
  printf "%s\n" "$line" >> "$TMP_OUTPUT"
done < "$CHECKLIST"

updated_count="$(cat "$UPDATED_COUNT_FILE")"
if [[ "$EXECUTE" == "1" ]]; then
  mv "$TMP_OUTPUT" "$CHECKLIST"
  trap 'rm -f "$UPDATED_COUNT_FILE"' EXIT
  echo "app store checklist sync: updated $updated_count item(s)"
else
  external_ids="$(completed_external_ids 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
  [[ -n "$external_ids" ]] || external_ids="none"
  echo "app store checklist sync: dry-run would update $updated_count item(s)"
  echo "- completed external evidence ids: $external_ids"
  if [[ "$updated_count" -gt 0 ]]; then
    sed 's/^/- /' "$UPDATED_TITLES_FILE"
  fi
fi
