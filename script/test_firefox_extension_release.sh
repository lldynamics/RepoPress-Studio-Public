#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firefox-extension-release.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$ROOT_DIR/BrowserExtension/Firefox/manifest.json")"
XPI="$TMP_DIR/knowledge-capture-firefox-$VERSION-unsigned.xpi"

python3 "$ROOT_DIR/script/firefox_extension_release.py" lint >/dev/null

"$ROOT_DIR/script/package_firefox_extension.sh" "$TMP_DIR" >/dev/null
[[ -f "$XPI" ]] || {
  echo "Unsigned Firefox validation XPI was not generated." >&2
  exit 1
}
FIRST_HASH="$(shasum -a 256 "$XPI" | awk '{print $1}')"

"$ROOT_DIR/script/package_firefox_extension.sh" "$TMP_DIR" >/dev/null
SECOND_HASH="$(shasum -a 256 "$XPI" | awk '{print $1}')"
[[ "$FIRST_HASH" == "$SECOND_HASH" ]] || {
  echo "Firefox validation XPI is not deterministic." >&2
  exit 1
}

python3 - "$XPI" "$ROOT_DIR/BrowserExtension/firefox-release.json" <<'PY'
import json
import sys
import zipfile

xpi_path, config_path = sys.argv[1:]
config = json.load(open(config_path, encoding="utf-8"))
with zipfile.ZipFile(xpi_path) as archive:
    manifest = json.loads(archive.read("manifest.json"))
    assert not any(name.lower().startswith("meta-inf/") for name in archive.namelist())
gecko = manifest["browser_specific_settings"]["gecko"]
assert gecko["id"] == config["addonID"]
assert gecko["update_url"] == config["updateManifestURL"]
assert gecko["data_collection_permissions"]["required"] == ["none"]
PY

if python3 "$ROOT_DIR/script/firefox_extension_release.py" verify-signed --signed-xpi "$XPI" >/dev/null 2>&1; then
  echo "Unsigned Firefox validation XPI was incorrectly accepted as signed." >&2
  exit 1
fi

EMPTY_SIGNATURE_XPI="$TMP_DIR/empty-signature.xpi"
TAMPERED_PAYLOAD_XPI="$TMP_DIR/tampered-payload.xpi"
EXTRA_PAYLOAD_XPI="$TMP_DIR/extra-payload.xpi"
FORGED_SIGNATURE_XPI="$TMP_DIR/forged-signature.xpi"

python3 - "$XPI" "$EMPTY_SIGNATURE_XPI" "$TAMPERED_PAYLOAD_XPI" "$EXTRA_PAYLOAD_XPI" "$FORGED_SIGNATURE_XPI" <<'PY'
import base64
import hashlib
import sys
import zipfile

source_path, empty_path, tampered_path, extra_path, forged_path = sys.argv[1:]
with zipfile.ZipFile(source_path) as source:
    payloads = {name: source.read(name) for name in source.namelist()}

def write_xpi(path, payload_overrides=None, extra_entries=None):
    values = dict(payloads)
    values.update(payload_overrides or {})
    values.update(extra_entries or {})
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, value in values.items():
            archive.writestr(name, value)

write_xpi(empty_path, extra_entries={"META-INF/fake.rsa": b""})

plausible_pkcs7 = (
    b"\x30\x82\x01\x00"
    + bytes.fromhex("06092a864886f70d010702")
    + bytes(300)
)
signature_envelope = {
    "META-INF/manifest.mf": b"Manifest-Version: 1.0\r\n\r\n",
    "META-INF/fake.sf": b"Signature-Version: 1.0\r\n\r\n",
    "META-INF/fake.rsa": plausible_pkcs7,
}
write_xpi(
    tampered_path,
    payload_overrides={"popup.js": payloads["popup.js"] + b"\n// tampered\n"},
    extra_entries=signature_envelope,
)
write_xpi(
    extra_path,
    extra_entries={**signature_envelope, "unexpected.txt": b"not part of the release"},
)

manifest_lines = ["Manifest-Version: 1.0", ""]
for name in sorted(payloads):
    digest = base64.b64encode(hashlib.sha256(payloads[name]).digest()).decode("ascii")
    manifest_lines.extend([
        f"Name: {name}",
        "Digest-Algorithms: SHA256",
        f"SHA256-Digest: {digest}",
        "",
    ])
signature_manifest = "\n".join(manifest_lines).encode("utf-8")
signature_manifest_digest = base64.b64encode(
    hashlib.sha256(signature_manifest).digest()
).decode("ascii")
signature_file = (
    "Signature-Version: 1.0\n"
    f"SHA256-Digest-Manifest: {signature_manifest_digest}\n\n"
).encode("utf-8")
write_xpi(
    forged_path,
    extra_entries={
        "META-INF/manifest.mf": signature_manifest,
        "META-INF/fake.sf": signature_file,
        "META-INF/fake.rsa": plausible_pkcs7,
    },
)
PY

expect_verification_failure() {
  local xpi_path="$1"
  local expected_message="$2"
  local output
  if output="$(python3 "$ROOT_DIR/script/firefox_extension_release.py" verify-signed --signed-xpi "$xpi_path" 2>&1)"; then
    echo "Invalid Firefox XPI was incorrectly accepted: $xpi_path" >&2
    exit 1
  fi
  [[ "$output" == *"$expected_message"* ]] || {
    echo "Firefox XPI failed for the wrong reason: $output" >&2
    exit 1
  }
}

expect_verification_failure "$EMPTY_SIGNATURE_XPI" "complete, authenticated Mozilla legacy signature envelope"
expect_verification_failure "$TAMPERED_PAYLOAD_XPI" "payload does not match the prepared release source: popup.js"
expect_verification_failure "$EXTRA_PAYLOAD_XPI" "payload has unexpected entries"
expect_verification_failure "$FORGED_SIGNATURE_XPI" "PKCS#7 signature does not authenticate"

echo "Firefox extension release tooling: passed"
