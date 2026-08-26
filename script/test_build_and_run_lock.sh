#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_HELPER="$ROOT_DIR/script/bundle_output_lock.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/repopress-bundle-lock.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

bundle_a="$TEMP_ROOT/dist-a/RepoPress Studio.app"
bundle_b="$TEMP_ROOT/dist-b/RepoPress Studio.app"
mkdir -p "$(dirname "$bundle_a")" "$(dirname "$bundle_b")"

first_ready="$TEMP_ROOT/first-ready"
(
  source "$LOCK_HELPER"
  acquire_bundle_output_lock "$bundle_a"
  trap release_bundle_output_lock EXIT
  touch "$first_ready"
  sleep 1
) &
first_pid="$!"
for _ in {1..40}; do
  [[ -e "$first_ready" ]] && break
  sleep 0.025
done
[[ -e "$first_ready" ]]

set +e
same_output="$(
  bash -c 'source "$1"; acquire_bundle_output_lock "$2"' \
    _ "$LOCK_HELPER" "$bundle_a" 2>&1
)"
same_status="$?"
set -e
[[ "$same_status" == "73" ]]
grep -Fq 'app bundle packaging lock is busy' <<<"$same_output"
grep -Fq 'owner process is still running' <<<"$same_output"
grep -Fq 'use a distinct PERSONAL_SITE_PUBLISHER_DIST_DIR' <<<"$same_output"

# A separate output directory has a separate lock and is allowed to proceed
# while the first bundle is being assembled.
bash -c 'source "$1"; acquire_bundle_output_lock "$2"; trap release_bundle_output_lock EXIT' \
  _ "$LOCK_HELPER" "$bundle_b"
[[ ! -e "$bundle_b.build-lock" ]]

wait "$first_pid"
[[ ! -e "$bundle_a.build-lock" ]]

# An EXIT path releases only the lock owned by that process.
crashing_ready="$TEMP_ROOT/crashing-ready"
set +e
(
  source "$LOCK_HELPER"
  acquire_bundle_output_lock "$bundle_a"
  trap release_bundle_output_lock EXIT
  touch "$crashing_ready"
  exit 19
)
crashing_status="$?"
set -e
[[ "$crashing_status" == "19" ]]
[[ -e "$crashing_ready" ]]
[[ ! -e "$bundle_a.build-lock" ]]

# A process with a foreign token must not remove the active owner lock.
foreign_ready="$TEMP_ROOT/foreign-ready"
(
  source "$LOCK_HELPER"
  acquire_bundle_output_lock "$bundle_a"
  trap release_bundle_output_lock EXIT
  touch "$foreign_ready"
  sleep 0.5
) &
foreign_pid="$!"
for _ in {1..40}; do
  [[ -e "$foreign_ready" ]] && break
  sleep 0.025
done
[[ -e "$foreign_ready" ]]
set +e
foreign_status="$(
  bash -c '
    source "$1"
    BUNDLE_OUTPUT_LOCK_PATH="$2.build-lock"
    BUNDLE_OUTPUT_LOCK_OWNER_FILE="$2.build-lock/owner"
    BUNDLE_OUTPUT_LOCK_TOKEN=not-the-owner
    BUNDLE_OUTPUT_LOCK_OWNED=1
    release_bundle_output_lock
  ' _ "$LOCK_HELPER" "$bundle_a" 2>&1
)"
foreign_code="$?"
set -e
[[ "$foreign_code" != "0" ]]
grep -Fq 'refusing to release an app bundle lock not owned by this process' <<<"$foreign_status"
[[ -e "$bundle_a.build-lock" ]]
wait "$foreign_pid"
[[ ! -e "$bundle_a.build-lock" ]]

# A failed release from an EXIT trap must preserve the original command exit
# code and must leave the lock in place rather than deleting a foreign lock.
bundle_c="$TEMP_ROOT/dist-c/RepoPress Studio.app"
set +e
(
  source "$LOCK_HELPER"
  acquire_bundle_output_lock "$bundle_c"
  trap release_bundle_output_lock EXIT
  BUNDLE_OUTPUT_LOCK_TOKEN=not-the-owner
  exit 23
)
tampered_code="$?"
set -e
[[ "$tampered_code" == "23" ]]
[[ -e "$bundle_c.build-lock" ]]
rm -f "$bundle_c.build-lock/owner"
rmdir "$bundle_c.build-lock"

echo "bundle output lock contract: passed"
