#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT_DIR/script/verify_remote_publish_live.sh"
EXECUTE=0
WRITE_EVIDENCE=1

usage() {
  cat <<'USAGE'
Usage: script/verify_remote_publish_live_matrix.sh [--execute] [--no-write-evidence]

Plans or runs all four live remote publishing verification flows:
  github direct, github review, gitlab direct, gitlab review.

Provider-specific environment:
  REMOTE_VERIFY_GITHUB_TOKEN
  REMOTE_VERIFY_GITHUB_OWNER
  REMOTE_VERIFY_GITHUB_REPO
  REMOTE_VERIFY_GITHUB_BASE_URL
  REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER
  REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER

  REMOTE_VERIFY_GITLAB_TOKEN
  REMOTE_VERIFY_GITLAB_OWNER
  REMOTE_VERIFY_GITLAB_REPO
  REMOTE_VERIFY_GITLAB_BASE_URL
  REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER
  REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER

Optional shared environment:
  REMOTE_VERIFY_BRANCH
  REMOTE_VERIFY_EVIDENCE_FILE
  REMOTE_VERIFY_ALLOW_CUSTOM_PATH
  REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH
  REMOTE_VERIFY_REVIEW_CLEANUP Optional. Set to 1 to close PR/MR and delete disposable review branches after review evidence is recorded.
  REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY Optional operator note appended to provider API permission evidence.

Optional provider/mode overrides:
  REMOTE_VERIFY_GITHUB_DIRECT_PATH
  REMOTE_VERIFY_GITHUB_REVIEW_PATH
  REMOTE_VERIFY_GITLAB_DIRECT_PATH
  REMOTE_VERIFY_GITLAB_REVIEW_PATH
  REMOTE_VERIFY_GITHUB_REVIEW_BRANCH_NAME
  REMOTE_VERIFY_GITLAB_REVIEW_BRANCH_NAME

By default this is a dry-run and only prints the four planned verifier commands.
Copy docs/release-evidence/remote-publish-live.env.example outside the
repository, fill it with disposable test repository details and least-privilege
tokens, source that private copy, then pass --execute. It delegates to
script/verify_remote_publish_live.sh for safety checks, provider API calls,
deployment status checks, and evidence recording.
USAGE
}

fail() {
  echo "remote publish live matrix: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --execute)
      EXECUTE=1
      shift
      ;;
    --no-write-evidence)
      WRITE_EVIDENCE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -x "$VERIFIER" || -f "$VERIFIER" ]] || fail "verify_remote_publish_live.sh is missing"

require_execute_env() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "${value//[[:space:]]/}" ]] || fail "$name is required with --execute"
}

provider_env_name() {
  local provider="$1"
  local suffix="$2"
  case "$provider" in
    github) echo "REMOTE_VERIFY_GITHUB_${suffix}" ;;
    gitlab) echo "REMOTE_VERIFY_GITLAB_${suffix}" ;;
    *) fail "unsupported provider: $provider" ;;
  esac
}

mode_env_name() {
  local provider="$1"
  local mode="$2"
  local suffix="$3"
  local provider_upper mode_upper
  provider_upper="$(printf "%s" "$provider" | tr '[:lower:]' '[:upper:]')"
  mode_upper="$(printf "%s" "$mode" | tr '[:lower:]' '[:upper:]')"
  echo "REMOTE_VERIFY_${provider_upper}_${mode_upper}_${suffix}"
}

provider_value() {
  local provider="$1"
  local suffix="$2"
  local name
  name="$(provider_env_name "$provider" "$suffix")"
  printf "%s" "${!name:-}"
}

mode_value() {
  local provider="$1"
  local mode="$2"
  local suffix="$3"
  local name
  name="$(mode_env_name "$provider" "$mode" "$suffix")"
  printf "%s" "${!name:-}"
}

run_one() {
  local provider="$1"
  local mode="$2"
  local token owner repo base_url release_ledger test_path review_branch
  token="$(provider_value "$provider" TOKEN)"
  owner="$(provider_value "$provider" OWNER)"
  repo="$(provider_value "$provider" REPO)"
  base_url="$(provider_value "$provider" BASE_URL)"
  release_ledger="$(mode_value "$provider" "$mode" RELEASE_LEDGER)"
  test_path="$(mode_value "$provider" "$mode" PATH)"
  review_branch="$(mode_value "$provider" "$mode" BRANCH_NAME)"

  if [[ "$EXECUTE" == "1" ]]; then
    require_execute_env "$(provider_env_name "$provider" TOKEN)"
    require_execute_env "$(provider_env_name "$provider" OWNER)"
    require_execute_env "$(provider_env_name "$provider" REPO)"
    if [[ "$WRITE_EVIDENCE" == "1" ]]; then
      require_execute_env "$(mode_env_name "$provider" "$mode" RELEASE_LEDGER)"
    fi
  fi

  echo "remote publish live matrix: $provider $mode"
  if [[ "$EXECUTE" == "0" ]]; then
    echo "- token: $([[ -n "$token" ]] && echo configured || echo missing)"
    echo "- owner: ${owner:-<missing>}"
    echo "- repo: ${repo:-<missing>}"
    echo "- release ledger: $([[ -n "$release_ledger" ]] && echo configured || echo missing)"
    echo "- command: script/verify_remote_publish_live.sh --provider $provider --mode $mode"
    return 0
  fi

  env_args=(
    "REMOTE_VERIFY_TOKEN=$token"
    "REMOTE_VERIFY_OWNER=$owner"
    "REMOTE_VERIFY_REPO=$repo"
  )
  if [[ -n "$base_url" ]]; then
    env_args+=("REMOTE_VERIFY_BASE_URL=$base_url")
  fi
  if [[ -n "${REMOTE_VERIFY_BRANCH:-}" ]]; then
    env_args+=("REMOTE_VERIFY_BRANCH=$REMOTE_VERIFY_BRANCH")
  fi
  if [[ -n "${REMOTE_VERIFY_EVIDENCE_FILE:-}" ]]; then
    env_args+=("REMOTE_VERIFY_EVIDENCE_FILE=$REMOTE_VERIFY_EVIDENCE_FILE")
  fi
  if [[ -n "${REMOTE_VERIFY_ALLOW_CUSTOM_PATH:-}" ]]; then
    env_args+=("REMOTE_VERIFY_ALLOW_CUSTOM_PATH=$REMOTE_VERIFY_ALLOW_CUSTOM_PATH")
  fi
  if [[ -n "${REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH:-}" ]]; then
    env_args+=("REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH=$REMOTE_VERIFY_ALLOW_CUSTOM_BRANCH")
  fi
  if [[ -n "${REMOTE_VERIFY_REVIEW_CLEANUP:-}" ]]; then
    env_args+=("REMOTE_VERIFY_REVIEW_CLEANUP=$REMOTE_VERIFY_REVIEW_CLEANUP")
  fi
  if [[ -n "${REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY:-}" ]]; then
    env_args+=("REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY=$REMOTE_VERIFY_TOKEN_SCOPE_SUMMARY")
  fi
  if [[ -n "$release_ledger" ]]; then
    env_args+=("REMOTE_VERIFY_RELEASE_LEDGER=$release_ledger")
  fi
  if [[ -n "$test_path" ]]; then
    env_args+=("REMOTE_VERIFY_PATH=$test_path")
  fi
  if [[ "$mode" == "review" && -n "$review_branch" ]]; then
    env_args+=("REMOTE_VERIFY_BRANCH_NAME=$review_branch")
  fi

  verifier_args=(--provider "$provider" --mode "$mode" --execute)
  if [[ "$WRITE_EVIDENCE" == "0" ]]; then
    verifier_args+=(--no-write-evidence)
  fi

  env "${env_args[@]}" bash "$VERIFIER" "${verifier_args[@]}"
}

echo "remote publish live matrix: dry-run=$([[ "$EXECUTE" == "1" ]] && echo no || echo yes), write evidence=$WRITE_EVIDENCE"
for provider in github gitlab; do
  for mode in direct review; do
    run_one "$provider" "$mode"
  done
done
