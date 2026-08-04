#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_FILE="${CLEAN_RUNTIME_EVIDENCE_FILE:-$ROOT_DIR/docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md}"
STRICT=0

usage() {
  cat <<'USAGE'
Usage: script/check_clean_runtime_evidence.sh [--strict]

Validates the clean-user runtime evidence template. Default mode requires the
template and rejects private-looking evidence. Strict mode also requires every
runtime smoke item to be checked with non-empty Evidence.
USAGE
}

fail() {
  echo "clean runtime evidence: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    --dry-run)
      STRICT="${STRICT_CLEAN_RUNTIME_EVIDENCE_ONLY:-0}"
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

[[ -f "$EVIDENCE_FILE" ]] || fail "missing evidence file: ${EVIDENCE_FILE#$ROOT_DIR/}"

python3 - "$EVIDENCE_FILE" "$STRICT" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
strict = sys.argv[2] == "1"
text = path.read_text(encoding="utf-8")
required_titles = [
    "App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.",
    "Quick hide, private-content masking, settings, and workspace switching were verified without exposing private content.",
    "Keyboard navigation, focus visibility, VoiceOver labels, and primary commands were smoke checked in the running app.",
]
private_pattern = re.compile(
    r"(/Users/|/Volumes/|file:///Users/|file:///Volumes/|"
    r"github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|"
    r"Authorization:[ \t]*Bearer[ \t]+[A-Za-z0-9._-]{20,}|"
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|"
    r"Apple[ \t]*ID|TeamIdentifier=|Receipt[ \t]*ID|receipt[ \t]*id|"
    r"private article|私人文章|私密文章)"
)

lines = text.splitlines()
items = {}
private_titles = []
for index, line in enumerate(lines):
    match = re.match(r"^- \[([ xX])\] (.+)$", line.strip())
    if not match:
        continue
    checked = match.group(1).lower() == "x"
    title = match.group(2)
    evidence = ""
    if index + 1 < len(lines):
        evidence_match = re.match(r"^\s*Evidence:\s*(.*)$", lines[index + 1])
        if evidence_match:
            evidence = evidence_match.group(1).strip()
    if evidence and private_pattern.search(evidence):
        private_titles.append(title)
    items[title] = (checked, evidence)

if private_titles:
    print(
        "clean runtime evidence: private-looking evidence in item(s): "
        + "; ".join(private_titles),
        file=sys.stderr,
    )
    sys.exit(1)

missing = [title for title in required_titles if title not in items]
if missing:
    print(
        "clean runtime evidence: missing required item(s): " + "; ".join(missing),
        file=sys.stderr,
    )
    sys.exit(1)

empty_checked = [
    title for title in required_titles
    if items[title][0] and not items[title][1]
]
if empty_checked:
    print(
        "clean runtime evidence: checked item(s) need non-empty Evidence: "
        + "; ".join(empty_checked),
        file=sys.stderr,
    )
    sys.exit(1)

if strict:
    incomplete = [title for title in required_titles if not items[title][0]]
    if incomplete:
        print(
            "clean runtime evidence: strict mode requires completed item(s): "
            + "; ".join(incomplete),
            file=sys.stderr,
        )
        sys.exit(1)

checked_count = sum(1 for title in required_titles if items[title][0])
print(f"clean runtime evidence: template valid; completed {checked_count}/{len(required_titles)} item(s)")
PY
