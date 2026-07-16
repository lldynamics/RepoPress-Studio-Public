#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/docs/app-store-screenshots}"
MANIFEST="${SCREENSHOT_MANIFEST_FILE:-$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md}"
ACCEPTED_DIMENSIONS="${SCREENSHOT_ACCEPTED_DIMENSIONS:-1280x800 1440x900 2560x1600 2880x1800}"
MODE="write"

usage() {
  cat <<'USAGE'
Usage: script/sync_screenshot_manifest_status.sh [--check] [--dry-run]

Synchronizes docs/app-store-screenshots/SCREENSHOT_MANIFEST.md Status values
with the actual screenshot files on disk. Captured images are marked with their
pixel dimensions, missing images stay Pending capture, and invalid images are
marked Invalid with the gate reason.

Options:
  --check    Fail if the manifest status column is not already synchronized.
  --dry-run  Print the synchronized manifest without writing it.
USAGE
}

fail() {
  echo "screenshot manifest sync: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --dry-run)
      MODE="dry-run"
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

[[ -f "$MANIFEST" ]] || fail "SCREENSHOT_MANIFEST.md is missing"
[[ -d "$SCREENSHOT_DIR" ]] || fail "screenshot directory is missing"
command -v sips >/dev/null 2>&1 || fail "sips is required to inspect screenshot dimensions"

tmp_output="$(mktemp "${TMPDIR:-/tmp}/screenshot-manifest.XXXXXX")"
python3 - "$MANIFEST" "$SCREENSHOT_DIR" "$ACCEPTED_DIMENSIONS" >"$tmp_output" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

manifest = Path(sys.argv[1])
screenshot_dir = Path(sys.argv[2])
accepted_dimensions = set(sys.argv[3].split())

def image_properties(path: Path):
    try:
        output = subprocess.check_output(
            ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(path)],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except subprocess.CalledProcessError:
        return None
    width = height = None
    has_alpha = None
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("pixelWidth:"):
            width = int(stripped.split(":", 1)[1].strip())
        if stripped.startswith("pixelHeight:"):
            height = int(stripped.split(":", 1)[1].strip())
        if stripped.startswith("hasAlpha:"):
            has_alpha = stripped.split(":", 1)[1].strip()
    if width is None or height is None or has_alpha not in {"yes", "no"}:
        return None
    return width, height, has_alpha == "yes"

def privacy_findings(path: Path):
    try:
        text = path.read_bytes().decode("latin-1", errors="ignore")
    except OSError:
        return ["unreadable image"]
    findings = []
    if re.search(r"(/Users/|/Volumes/|file:///Users/|file:///Volumes/)", text):
        findings.append("local path")
    if re.search(r"(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[ \t]*Bearer[ \t]+[A-Za-z0-9._-]{20,})", text):
        findings.append("token-like secret")
    return findings

def status_for(filename: str) -> str:
    image = screenshot_dir / filename
    if not image.exists():
        return "Pending capture"
    properties = image_properties(image)
    if properties is None:
        return "Invalid: unreadable image"
    width, height, has_alpha = properties
    if f"{width}x{height}" not in accepted_dimensions:
        return f"Invalid: {width}x{height} is not an accepted Mac App Store size"
    if has_alpha:
        return "Invalid: alpha channel/transparency"
    findings = privacy_findings(image)
    if findings:
        return "Invalid: possible private content (" + ", ".join(findings) + ")"
    return f"Captured {width}x{height}"

row_pattern = re.compile(
    r"^\| `([^`]+)` \| `([^`]+)` \| ([^|]+) \| ([^|]+) \| ([^|]+) \|$"
)

updated = []
for line in manifest.read_text().splitlines():
    match = row_pattern.match(line)
    if match:
        screenshot_id, filename, screen, purpose, _status = match.groups()
        line = f"| `{screenshot_id}` | `{filename}` | {screen} | {purpose} | {status_for(filename)} |"
    updated.append(line)

print("\n".join(updated) + "\n", end="")
PY

case "$MODE" in
  dry-run)
    cat "$tmp_output"
    ;;
  check)
    if ! cmp -s "$MANIFEST" "$tmp_output"; then
      rm -f "$tmp_output"
      fail "SCREENSHOT_MANIFEST.md is out of sync; run script/sync_screenshot_manifest_status.sh"
    fi
    echo "screenshot manifest sync: manifest status is current"
    ;;
  write)
    mv "$tmp_output" "$MANIFEST"
    echo "screenshot manifest sync: updated ${MANIFEST#$ROOT_DIR/}"
    ;;
esac

[[ ! -f "$tmp_output" ]] || rm -f "$tmp_output"
