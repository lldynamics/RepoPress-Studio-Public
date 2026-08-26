#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${PUBLIC_SNAPSHOT_SOURCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
  echo "public snapshot export: $*" >&2
  exit 1
}

usage() {
  echo "usage: export_public_snapshot.sh [--allow-dirty] <empty-output-directory>"
}

ALLOW_DIRTY=0
if [[ "${1:-}" == "--allow-dirty" ]]; then
  ALLOW_DIRTY=1
  shift
fi
[[ "$#" -eq 1 ]] || { usage >&2; exit 2; }
command -v rsync >/dev/null 2>&1 || fail "rsync is required"

[[ -d "$ROOT_DIR" ]] || fail "source directory is missing: $ROOT_DIR"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd -P)"
[[ "$(git -C "$ROOT_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]] \
  || fail "source is not a Git worktree: $ROOT_DIR"

source_revision="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)" \
  || fail "source worktree has no committed HEAD"
source_changes="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)"
if [[ -n "$source_changes" && "$ALLOW_DIRTY" != "1" ]]; then
  fail "source worktree has uncommitted changes; review them and rerun with --allow-dirty to export them deliberately"
fi
if [[ -n "$source_changes" ]]; then
  echo "public snapshot export: warning: deliberately exporting reviewed uncommitted changes" >&2
fi

OUTPUT_DIR="$1"
if [[ -e "$OUTPUT_DIR" ]]; then
  [[ -d "$OUTPUT_DIR" ]] || fail "output path is not a directory: $OUTPUT_DIR"
  [[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || fail "output directory must be empty: $OUTPUT_DIR"
else
  mkdir -p "$OUTPUT_DIR"
fi
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

case "$OUTPUT_DIR/" in
  "$ROOT_DIR/"*) fail "output directory must be outside the source worktree" ;;
esac

copy_file() {
  local source_relative="$1"
  local destination_relative="${2:-$1}"
  [[ -f "$ROOT_DIR/$source_relative" ]] || fail "required source file is missing: $source_relative"
  mkdir -p "$OUTPUT_DIR/$(dirname "$destination_relative")"
  cp -p "$ROOT_DIR/$source_relative" "$OUTPUT_DIR/$destination_relative"
}

copy_tree() {
  local source_relative="$1"
  [[ -d "$ROOT_DIR/$source_relative" ]] || fail "required source directory is missing: $source_relative"
  mkdir -p "$OUTPUT_DIR/$source_relative"
  rsync -a \
    --exclude '.DS_Store' \
    --exclude '._*' \
    --exclude '*.zip' \
    --exclude '*.xpi' \
    "$ROOT_DIR/$source_relative/" "$OUTPUT_DIR/$source_relative/"
}

for file in \
  .gitignore \
  CONTRIBUTING.md \
  LICENSE \
  Package.resolved \
  Package.swift \
  SECURITY.md \
  TRADEMARKS.md \
  package-lock.json \
  package.json; do
  copy_file "$file"
done
copy_file README.public.md README.md

copy_tree BrowserExtension
copy_tree Packaging
copy_tree Sources
copy_tree Tests
copy_tree UITests

rm -f "$OUTPUT_DIR/BrowserExtension/release-ledger.json"

mkdir -p "$OUTPUT_DIR/script"
rsync -a \
  --exclude '.DS_Store' \
  --exclude '._*' \
  --exclude 'public-repository/' \
  --exclude 'export_public_snapshot.sh' \
  --exclude 'test_public_snapshot_export.sh' \
  "$ROOT_DIR/script/" "$OUTPUT_DIR/script/"

mkdir -p "$OUTPUT_DIR/docs"
copy_file docs/release-versioning.md

copy_file .github/CODEOWNERS
copy_file .github/dependabot.yml
copy_file script/public-repository/quality.yml .github/workflows/quality.yml

bash "$OUTPUT_DIR/script/check_public_snapshot.sh" "$OUTPUT_DIR"

file_count="$(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ')"
echo "public snapshot export: source revision ${source_revision:0:12}"
echo "public snapshot export: wrote $file_count reviewed file(s) to $OUTPUT_DIR"
