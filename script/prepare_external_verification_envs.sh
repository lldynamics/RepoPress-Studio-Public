#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${EXTERNAL_VERIFY_ENV_DIR:-/private/tmp/personal-site-publisher-release-envs}"
DRY_RUN=0
FORCE=0
TARGET="all"

usage() {
  cat <<'USAGE'
Usage: script/prepare_external_verification_envs.sh [--output-dir <path>] [--force] [--dry-run] [--target <name>]

Copies release verification .env templates to a private directory outside the
repository. Fill the copied files, not the repo templates, before running live
GitHub/GitLab, remote recovery, screenshot, or App Store archive checks.

Options:
  --output-dir <path>  Destination outside the repository.
  --force             Overwrite existing copied env files.
  --dry-run           Validate and print the planned copies without writing.
  --target <name>      all, remaining, remote-publish, remote-recovery,
                       app-store-screenshots, or app-store-archive.
USAGE
}

fail() {
  echo "external verification env prep: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ "$#" -ge 2 ]] || fail "--output-dir requires a path"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --target)
      [[ "$#" -ge 2 ]] || fail "--target requires a value"
      TARGET="$2"
      shift 2
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

if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$(pwd -P)/$OUTPUT_DIR"
fi

case "$OUTPUT_DIR" in
  "$ROOT_DIR"|"$ROOT_DIR"/*)
    fail "output directory must be outside the repository"
    ;;
esac

case "$TARGET" in
  all|remaining|remote-publish|remote-recovery|app-store-screenshots|app-store-archive) ;;
  *) fail "--target must be all, remaining, remote-publish, remote-recovery, app-store-screenshots, or app-store-archive" ;;
esac

templates=(
  "remote-publish:docs/release-evidence/remote-publish-live.env.example:remote-publish-live.env"
  "remote-recovery:docs/release-evidence/remote-recovery.env.example:remote-recovery.env"
  "app-store-screenshots:docs/release-evidence/app-store-screenshots.env.example:app-store-screenshots.env"
  "app-store-archive:docs/release-evidence/app-store-archive-validation.env.example:app-store-archive-validation.env"
)

for entry in "${templates[@]}"; do
  rest="${entry#*:}"
  source_path="${rest%%:*}"
  [[ -f "$ROOT_DIR/$source_path" ]] || fail "missing template: $source_path"
done

external_evidence_file() {
  printf '%s' "${EXTERNAL_VERIFY_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md}"
}

external_item_complete() {
  local item_id="$1"
  local file
  file="$(external_evidence_file)"
  [[ -f "$file" ]] && grep -Eq "^- \[[xX]\][[:space:]]+\`$item_id\`" "$file"
}

app_store_archive_complete() {
  STRICT_ARCHIVE_EVIDENCE_ONLY=1 APP_STORE_ARCHIVE_EVIDENCE_FILE="${APP_STORE_ARCHIVE_EVIDENCE_FILE:-}" \
    bash "$ROOT_DIR/script/check_app_store_archive_readiness.sh" --dry-run >/dev/null 2>&1
}

target_is_remaining() {
  local target="$1"
  case "$target" in
    app-store-archive)
      ! app_store_archive_complete
      ;;
    remote-publish)
      ! external_item_complete github-direct-publish \
        || ! external_item_complete github-review-publish \
        || ! external_item_complete gitlab-direct-publish \
        || ! external_item_complete gitlab-review-publish
      ;;
    remote-recovery)
      ! external_item_complete remote-conflict-deployment-rollback
      ;;
    app-store-screenshots)
      ! external_item_complete app-store-screenshots
      ;;
    *)
      return 1
      ;;
  esac
}

should_copy_target() {
  local target="$1"
  if [[ "$TARGET" == "all" ]]; then
    return 0
  fi
  if [[ "$TARGET" == "remaining" ]]; then
    target_is_remaining "$target"
    return $?
  fi
  [[ "$TARGET" == "$target" ]]
}

if [[ "$DRY_RUN" != "1" ]]; then
  mkdir -p "$OUTPUT_DIR"
  chmod 700 "$OUTPUT_DIR"
fi

echo "external verification env prep: output directory $OUTPUT_DIR"
echo "external verification env prep: target $TARGET"

copied_targets=()

for entry in "${templates[@]}"; do
  target="${entry%%:*}"
  rest="${entry#*:}"
  source_path="${rest%%:*}"
  target_name="${rest##*:}"
  target_path="$OUTPUT_DIR/$target_name"

  should_copy_target "$target" || continue

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "external verification env prep: would copy $source_path -> $target_path"
  else
    if [[ -e "$target_path" && "$FORCE" != "1" ]]; then
      fail "refusing to overwrite existing file: $target_path"
    fi
    cp "$ROOT_DIR/$source_path" "$target_path"
    chmod 600 "$target_path"
    echo "external verification env prep: copied $source_path -> $target_path"
  fi
  copied_targets+=("$target_name")
done

if [[ "${#copied_targets[@]}" -eq 0 ]]; then
  echo "external verification env prep: no env files needed for target $TARGET"
fi

cat <<EOF

Fill these private files, then source only the copied files required for the live check:
EOF

for target_name in "${copied_targets[@]}"; do
  echo "  source \"$OUTPUT_DIR/$target_name\""
done

cat <<EOF

Do not copy filled values back into docs/release-evidence/*.env.example.
EOF
