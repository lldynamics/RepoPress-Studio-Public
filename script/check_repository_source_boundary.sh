#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${REPOSITORY_SOURCE_BOUNDARY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RELEASE_MODE=0

fail() {
  echo "repository source boundary: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --release)
      RELEASE_MODE=1
      shift
      ;;
    -h|--help)
      echo "usage: check_repository_source_boundary.sh [--release]"
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$(git -C "$ROOT_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]] \
  || fail "not a Git worktree: $ROOT_DIR"

critical_paths=(
  Package.swift
  Packaging
  Config
  StoreKit
  BrowserExtension
  Sources
  Tests
  script
  .github
  APP_STORE_CHECKLIST.md
  docs/release-evidence
  docs/app-store-screenshots
)

untracked=()
while IFS= read -r path; do
  [[ -n "$path" ]] && untracked+=("$path")
done < <(git -C "$ROOT_DIR" ls-files --others --exclude-standard -- "${critical_paths[@]}")

if [[ "${#untracked[@]}" -gt 0 ]]; then
  echo "repository source boundary: ${#untracked[@]} untracked build/release file(s) would be absent from a clean checkout:" >&2
  printf '  - %s\n' "${untracked[@]}" >&2
  echo "repository source boundary: review and explicitly stage the intended files before release" >&2
  exit 1
fi

if [[ "$RELEASE_MODE" == "1" ]]; then
  release_changes=()
  while IFS= read -r path; do
    [[ -n "$path" ]] && release_changes+=("$path")
  done < <(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)
  if [[ "${#release_changes[@]}" -gt 0 ]]; then
    echo "repository source boundary: release mode requires a clean commit; found ${#release_changes[@]} worktree change(s)" >&2
    printf '  - %s\n' "${release_changes[@]}" >&2
    exit 1
  fi
  commit_sha="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)" \
    || fail "release mode requires a committed HEAD"
  echo "repository source boundary: release checkout is clean at commit ${commit_sha:0:12}"
  exit 0
fi

echo "repository source boundary: clean checkout contains every build/release input"
