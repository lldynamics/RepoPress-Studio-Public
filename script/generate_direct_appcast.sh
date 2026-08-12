#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${DIRECT_DISTRIBUTION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GENERATE_APPCAST_TOOL="${SPARKLE_GENERATE_APPCAST_TOOL:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"
GENERATE_KEYS_TOOL="${SPARKLE_GENERATE_KEYS_TOOL:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys}"
DOWNLOAD_URL_PREFIX="${REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX:-}"
PUBLIC_ED_KEY="${REPOPRESS_UPDATE_PUBLIC_ED_KEY:-}"
KEY_ACCOUNT="${REPOPRESS_SPARKLE_KEY_ACCOUNT:-ed25519}"
CHANNEL="${REPOPRESS_UPDATE_CHANNEL:-stable}"
ARCHIVE=""
OUTPUT=""
MODE="generate"
TMP_DIR=""

usage() {
  cat <<'USAGE'
Usage: script/generate_direct_appcast.sh [--dry-run] --archive <zip> --output <xml>

Generates a signed Sparkle appcast using the EdDSA private key stored in the
macOS Keychain. The private key is never accepted as a repository file or
written to release output.

Environment:
  REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX  Required https download directory.
  REPOPRESS_SPARKLE_KEY_ACCOUNT         Keychain account (default: ed25519).
  REPOPRESS_UPDATE_CHANNEL              stable or beta (default: stable).
USAGE
}

fail() {
  echo "direct appcast: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --archive)
      [[ "$#" -ge 2 ]] || fail "--archive requires a path"
      ARCHIVE="$2"
      shift 2
      ;;
    --output)
      [[ "$#" -ge 2 ]] || fail "--output requires a path"
      OUTPUT="$2"
      shift 2
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

case "$CHANNEL" in
  stable|beta) ;;
  *) fail "REPOPRESS_UPDATE_CHANNEL must be stable or beta" ;;
esac
[[ -n "$KEY_ACCOUNT" ]] || fail "REPOPRESS_SPARKLE_KEY_ACCOUNT must not be empty"

if [[ "$MODE" == "dry-run" ]]; then
  if [[ -z "$DOWNLOAD_URL_PREFIX" ]]; then
    echo "direct appcast: configure before release: REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX"
  else
    echo "direct appcast: download URL prefix is configured"
  fi
  echo "direct appcast: Keychain account name is $KEY_ACCOUNT; no private key was read"
  echo "direct appcast: dry-run did not verify the configured public key against the Keychain"
  echo "direct appcast: dry-run did not sign or publish an appcast"
  exit 0
fi

[[ -x "$GENERATE_APPCAST_TOOL" ]] \
  || fail "Sparkle generate_appcast is unavailable: $GENERATE_APPCAST_TOOL"
[[ -x "$GENERATE_KEYS_TOOL" ]] \
  || fail "Sparkle generate_keys is unavailable: $GENERATE_KEYS_TOOL"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || fail "--archive must point to the final ZIP"
[[ -n "$OUTPUT" ]] || fail "--output is required"
[[ -n "$DOWNLOAD_URL_PREFIX" ]] || fail "REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX is required"
[[ -n "$PUBLIC_ED_KEY" ]] || fail "REPOPRESS_UPDATE_PUBLIC_ED_KEY is required"
actual_public_key="$($GENERATE_KEYS_TOOL --account "$KEY_ACCOUNT" -p)" \
  || fail "could not read the existing Sparkle public key from the Keychain"
actual_public_key="$(printf '%s' "$actual_public_key" | tr -d '\r\n')"
[[ "$actual_public_key" == "$PUBLIC_ED_KEY" ]] \
  || fail "REPOPRESS_UPDATE_PUBLIC_ED_KEY does not match the Keychain private key account"
python3 - "$DOWNLOAD_URL_PREFIX" <<'PY'
from urllib.parse import urlparse
import sys

value = sys.argv[1]
parsed = urlparse(value)
if value != value.strip() or parsed.scheme.lower() != "https" or not parsed.netloc:
    raise SystemExit("direct appcast: REPOPRESS_UPDATE_DOWNLOAD_URL_PREFIX must be an absolute https URL")
PY

OUTPUT="$(python3 - "$OUTPUT" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
)"
mkdir -p "$(dirname "$OUTPUT")"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/repopress-appcast.XXXXXX")"
archive_name="$(basename "$ARCHIVE")"
appcast_name="$CHANNEL-appcast.xml"
generated="$TMP_DIR/$appcast_name"
/usr/bin/ditto "$ARCHIVE" "$TMP_DIR/$archive_name"
if [[ -f "$OUTPUT" ]]; then
  /usr/bin/ditto "$OUTPUT" "$generated"
fi

generate_arguments=(
  --account "$KEY_ACCOUNT"
  --download-url-prefix "${DOWNLOAD_URL_PREFIX%/}/"
  --maximum-deltas 0
  -o "$generated"
)
if [[ "$CHANNEL" == "beta" ]]; then
  generate_arguments+=(--channel beta)
fi
"$GENERATE_APPCAST_TOOL" "${generate_arguments[@]}" "$TMP_DIR" >/dev/null
[[ -f "$generated" ]] || fail "Sparkle did not create $appcast_name"
python3 - "$generated" "$archive_name" "$DOWNLOAD_URL_PREFIX" "$CHANNEL" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
archive_name = sys.argv[2]
prefix = sys.argv[3].rstrip("/") + "/"
channel = sys.argv[4]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ET.parse(path).getroot()
items = root.findall("./channel/item")
if not items:
    raise SystemExit("direct appcast: generated appcast has no update item")
matching = []
for item in items:
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    if enclosure.attrib.get("url") == prefix + archive_name:
        matching.append((item, enclosure))
if len(matching) != 1:
    raise SystemExit("direct appcast: final ZIP URL is missing or duplicated")
item, enclosure = matching[0]
if not enclosure.attrib.get(f"{{{sparkle}}}edSignature"):
    raise SystemExit("direct appcast: final ZIP has no EdDSA signature")
channel_element = item.find(f"{{{sparkle}}}channel")
if channel == "stable":
    if channel_element is not None and (channel_element.text or "").strip():
        raise SystemExit("direct appcast: stable items must not carry a Sparkle channel")
elif channel_element is None or (channel_element.text or "").strip() != "beta":
    raise SystemExit("direct appcast: beta item channel does not match")
PY
/usr/bin/ditto "$generated" "$OUTPUT"
echo "direct appcast: signed $OUTPUT"
