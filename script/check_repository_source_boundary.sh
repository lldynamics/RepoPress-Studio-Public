#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${REPOSITORY_SOURCE_BOUNDARY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
  echo "repository source boundary: $*" >&2
  exit 1
}

[[ -d "$ROOT_DIR/.git" ]] || fail "not a Git worktree: $ROOT_DIR"

critical_paths=(
  Package.swift
  Packaging
  Config
  StoreKit
  Sources
  Tests
  script
  .github
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

echo "repository source boundary: clean checkout contains every build/release input"
