#!/usr/bin/env bash

# A small, directory-backed lock for one assembled app bundle.  `mkdir` is an
# atomic operation on the local filesystems used by the packaging scripts, so
# two builders cannot both enter the destructive bundle replacement section.
# Keep this file side-effect free when sourced; the caller owns the EXIT trap.

BUNDLE_OUTPUT_LOCK_PATH=""
BUNDLE_OUTPUT_LOCK_OWNER_FILE=""
BUNDLE_OUTPUT_LOCK_TOKEN=""
BUNDLE_OUTPUT_LOCK_OWNED=0

bundle_output_lock_path() {
  local app_bundle="$1"
  printf '%s.build-lock\n' "$app_bundle"
}

bundle_output_lock_owner_pid() {
  local owner_file="$1"
  if [[ -r "$owner_file" ]]; then
    /usr/bin/awk -F= '$1 == "pid" {print $2; exit}' "$owner_file"
  fi
}

acquire_bundle_output_lock() {
  local app_bundle="$1"
  local lock_path
  local owner_file
  local token
  local started_at
  local owner_pid

  lock_path="$(bundle_output_lock_path "$app_bundle")"
  owner_file="$lock_path/owner"
  mkdir -p "$(dirname "$lock_path")"

  if ! mkdir "$lock_path" 2>/dev/null; then
    echo "app bundle packaging lock is busy: $lock_path" >&2
    if [[ -r "$owner_file" ]]; then
      owner_pid="$(bundle_output_lock_owner_pid "$owner_file")"
      sed 's/^/  /' "$owner_file" >&2 || true
      if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        echo "  owner process is still running (pid $owner_pid)" >&2
      elif [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
        echo "  owner pid $owner_pid is not running; inspect the lock before removing it" >&2
      else
        echo "  owner pid is unavailable; inspect the lock before removing it" >&2
      fi
    else
      echo "  owner metadata is unavailable; inspect the lock before removing it" >&2
    fi
    echo "  use a distinct PERSONAL_SITE_PUBLISHER_DIST_DIR for an independent output" >&2
    return 73
  fi

  # The token prevents an EXIT trap from deleting a lock acquired by another
  # process after a PID has been reused.  The lock directory is deliberately
  # never removed recursively; release only removes the owner file we wrote
  # and then removes the now-empty lock directory.
  token="${BASHPID:-$$}.${RANDOM}.$(date +%s)"
  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if ! {
    printf 'pid=%s\n' "${BASHPID:-$$}"
    printf 'startedAt=%s\n' "$started_at"
    printf 'token=%s\n' "$token"
    printf 'bundle=%s\n' "$app_bundle"
  } >"$owner_file"; then
    # We own the directory at this point.  Keep cleanup scoped to this lock.
    rmdir "$lock_path" 2>/dev/null || true
    return 1
  fi

  BUNDLE_OUTPUT_LOCK_PATH="$lock_path"
  BUNDLE_OUTPUT_LOCK_OWNER_FILE="$owner_file"
  BUNDLE_OUTPUT_LOCK_TOKEN="$token"
  BUNDLE_OUTPUT_LOCK_OWNED=1
}

release_bundle_output_lock() {
  [[ "$BUNDLE_OUTPUT_LOCK_OWNED" == "1" ]] || return 0
  [[ -n "$BUNDLE_OUTPUT_LOCK_OWNER_FILE" ]] || return 0
  [[ -n "$BUNDLE_OUTPUT_LOCK_TOKEN" ]] || return 0

  local recorded_token=""
  if [[ -r "$BUNDLE_OUTPUT_LOCK_OWNER_FILE" ]]; then
    recorded_token="$(/usr/bin/awk -F= '$1 == "token" {print $2; exit}' "$BUNDLE_OUTPUT_LOCK_OWNER_FILE")"
  fi
  if [[ "$recorded_token" != "$BUNDLE_OUTPUT_LOCK_TOKEN" ]]; then
    echo "refusing to release an app bundle lock not owned by this process: $BUNDLE_OUTPUT_LOCK_PATH" >&2
    return 1
  fi

  # `rm` targets one exact owner file, and `rmdir` succeeds only if no other
  # process has placed anything in the lock directory.
  rm "$BUNDLE_OUTPUT_LOCK_OWNER_FILE" 2>/dev/null || return 1
  rmdir "$BUNDLE_OUTPUT_LOCK_PATH" 2>/dev/null || return 1
  BUNDLE_OUTPUT_LOCK_OWNED=0
  BUNDLE_OUTPUT_LOCK_PATH=""
  BUNDLE_OUTPUT_LOCK_OWNER_FILE=""
  BUNDLE_OUTPUT_LOCK_TOKEN=""
}
