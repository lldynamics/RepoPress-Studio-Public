#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-screenshot-evidence.XXXXXX)"
SCREENSHOT_DIR="$TMP_DIR/app-store-screenshots"
EVIDENCE_FILE="$TMP_DIR/EXTERNAL_VERIFICATION_EVIDENCE.md"
OCR_EXECUTABLE="$TMP_DIR/screenshot-privacy-ocr-stub"

python3 - "$OCR_EXECUTABLE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
path.chmod(0o755)
PY

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "app store screenshot evidence test: $*" >&2
  exit 1
}

required_ids=()
while IFS= read -r id; do
  [[ -n "$id" ]] && required_ids+=("$id")
done < <(sed -nE 's/^\| `([^`]+)` \|.*/\1/p' "$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md")
[[ "${#required_ids[@]}" -gt 0 ]] || fail "source screenshot manifest contains no IDs"

create_png() {
  local path="$1"
  local width="$2"
  local height="$3"
  python3 - "$path" "$width" "$height" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

path = Path(sys.argv[1])
width = int(sys.argv[2])
height = int(sys.argv[3])

def chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )

raw = b"".join(b"\x00" + (b"\xf5\xf5\xf5" * width) for _ in range(height))
png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 9))
    + chunk(b"IEND", b"")
)
path.write_bytes(png)
PY
}

reset_fixture() {
  rm -rf "$SCREENSHOT_DIR"
  mkdir -p "$SCREENSHOT_DIR"
  cp "$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md" "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md"
  cp "$ROOT_DIR/docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md" "$EVIDENCE_FILE"
}

stamp_captures() {
  local id image
  for id in "${required_ids[@]}"; do
    image="$SCREENSHOT_DIR/$id.png"
    python3 "$ROOT_DIR/script/screenshot_capture_provenance.py" record \
      --root "$ROOT_DIR" \
      --manifest "$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
      --screenshot-dir "$SCREENSHOT_DIR" \
      --id "$id" \
      --image "$image" >/dev/null
  done
}

run_recorder() {
  SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  SCREENSHOT_PRIVACY_OCR_EXECUTABLE="$OCR_EXECUTABLE" \
    bash "$ROOT_DIR/script/record_app_store_screenshot_evidence.sh" "$@"
}

reset_fixture
dry_run_output="$(run_recorder --dry-run)"
grep -q "captured screenshots: 0/${#required_ids[@]}" <<<"$dry_run_output" || fail "dry-run did not report missing screenshots"
grep -q "missing screenshots:" <<<"$dry_run_output" || fail "dry-run did not list missing screenshots"

if run_recorder --execute >/dev/null 2>&1; then
  fail "recorder accepted missing screenshot images"
fi

for id in "${required_ids[@]}"; do
  create_png "$SCREENSHOT_DIR/$id.png" 1440 900
done

if run_recorder --execute >/dev/null 2>&1; then
  fail "recorder accepted stale screenshot manifest"
fi

PENDING_EVIDENCE_FILE="$TMP_DIR/pending-screenshot-evidence.md"
cp "$EVIDENCE_FILE" "$PENDING_EVIDENCE_FILE"
cat >>"$PENDING_EVIDENCE_FILE" <<'MD'

### App Store 截图和严格门禁
- Screenshot set: Captured manifest screenshot IDs: writing, ai-chat, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.
- Screenshot privacy gate: Pending privacy gate review.
- Screenshot strict gate: TODO run STRICT_SCREENSHOTS=1 check_screenshots.sh.
MD
perl -0pi -e 's/- \[ \] `app-store-screenshots`/- [x] `app-store-screenshots`/' "$PENDING_EVIDENCE_FILE"
if STRICT_EXTERNAL_STRUCTURE_ONLY=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$PENDING_EVIDENCE_FILE" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1; then
  fail "strict external evidence gate accepted pending screenshot gate placeholder text"
fi

SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null
stamp_captures

ready_output="$(run_recorder --dry-run)"
grep -q "strict screenshot gate: ready" <<<"$ready_output" || fail "dry-run did not verify strict screenshot gate readiness"
grep -q "screenshot privacy gate: ready" <<<"$ready_output" || fail "dry-run did not verify screenshot privacy readiness"

run_recorder --execute >/dev/null
grep -q '^- \[x\] `app-store-screenshots`' "$EVIDENCE_FILE" || fail "screenshot evidence was not marked complete"
grep -q 'Screenshot set: Captured manifest screenshot IDs: writing, ai-chat, knowledge-library, sync-api-publish, seo-social-preview, deployment-status, maintenance, general-drafts, pro-settings, privacy-lock.' "$EVIDENCE_FILE" \
  || fail "structured screenshot set evidence missing"
STRICT_EXTERNAL_STRUCTURE_ONLY=1 EXTERNAL_VERIFY_EVIDENCE_FILE="$EVIDENCE_FILE" \
  SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  SCREENSHOT_DIR="$SCREENSHOT_DIR" \
  bash "$ROOT_DIR/script/check_external_verification_evidence.sh" >/dev/null 2>&1 || fail "strict external evidence gate rejected recorded screenshot evidence"

printf 'replaced-after-capture' >>"$SCREENSHOT_DIR/writing.png"
if run_recorder --execute >/dev/null 2>&1; then
  fail "recorder accepted a screenshot changed after capture provenance was recorded"
fi
stamp_captures

reset_fixture
for id in "${required_ids[@]}"; do
  create_png "$SCREENSHOT_DIR/$id.png" 1440 900
done
printf '/Users/example/private-site/content/post.md' >>"$SCREENSHOT_DIR/privacy-lock.png"
SCREENSHOT_DIR="$SCREENSHOT_DIR" SCREENSHOT_MANIFEST_FILE="$SCREENSHOT_DIR/SCREENSHOT_MANIFEST.md" \
  bash "$ROOT_DIR/script/sync_screenshot_manifest_status.sh" >/dev/null
stamp_captures
if run_recorder --execute >/dev/null 2>&1; then
  fail "recorder accepted screenshot with local path"
fi

echo "app store screenshot evidence test: passed"
