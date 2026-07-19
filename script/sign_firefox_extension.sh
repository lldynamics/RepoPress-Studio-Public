#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist/browser-extension}"
MANIFEST="$ROOT_DIR/BrowserExtension/Firefox/manifest.json"

[[ -n "${AMO_JWT_ISSUER:-}" ]] || {
  echo "AMO_JWT_ISSUER is required for Mozilla unlisted signing." >&2
  exit 2
}
[[ -n "${AMO_JWT_SECRET:-}" ]] || {
  echo "AMO_JWT_SECRET is required for Mozilla unlisted signing." >&2
  exit 2
}

if [[ -x "$ROOT_DIR/node_modules/.bin/web-ext" ]]; then
  WEB_EXT="$ROOT_DIR/node_modules/.bin/web-ext"
elif command -v web-ext >/dev/null 2>&1; then
  WEB_EXT="$(command -v web-ext)"
else
  echo "web-ext is required. Install it locally with: npm install --save-dev web-ext" >&2
  exit 2
fi

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$MANIFEST")"
SOURCE_DIR="$OUTPUT_DIR/firefox-source-$VERSION"
SIGNED_TEMP="$OUTPUT_DIR/.signed-$VERSION"
SIGNED_XPI="$OUTPUT_DIR/knowledge-capture-firefox-$VERSION.xpi"
UPDATES_JSON="$OUTPUT_DIR/updates.json"

"$ROOT_DIR/script/package_firefox_extension.sh" "$OUTPUT_DIR"
rm -rf "$SIGNED_TEMP"
mkdir -p "$SIGNED_TEMP"

"$WEB_EXT" sign \
  --channel=unlisted \
  --api-key="$AMO_JWT_ISSUER" \
  --api-secret="$AMO_JWT_SECRET" \
  --source-dir="$SOURCE_DIR" \
  --artifacts-dir="$SIGNED_TEMP"

shopt -s nullglob
SIGNED_RESULTS=("$SIGNED_TEMP"/*.xpi)
shopt -u nullglob
[[ "${#SIGNED_RESULTS[@]}" -eq 1 ]] || {
  echo "Expected exactly one signed XPI, found ${#SIGNED_RESULTS[@]}." >&2
  exit 1
}
cp "${SIGNED_RESULTS[0]}" "$SIGNED_XPI"

python3 "$ROOT_DIR/script/firefox_extension_release.py" verify-signed --signed-xpi "$SIGNED_XPI"
python3 "$ROOT_DIR/script/firefox_extension_release.py" updates \
  --signed-xpi "$SIGNED_XPI" \
  --output "$UPDATES_JSON"

echo "Signed Firefox release is ready for explicit HTTPS upload:"
echo "  $SIGNED_XPI"
echo "  $UPDATES_JSON"
echo "No files were uploaded by this script."
