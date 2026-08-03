#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firefox-extension-release.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$ROOT_DIR/BrowserExtension/Firefox/manifest.json")"
XPI="$TMP_DIR/knowledge-capture-firefox-$VERSION-unsigned.xpi"
AMO_XPI="$TMP_DIR/knowledge-capture-firefox-$VERSION-amo.xpi"

python3 "$ROOT_DIR/script/firefox_extension_release.py" package-amo \
  --output-dir "$TMP_DIR" \
  --no-record-ledger >/dev/null
[[ -f "$AMO_XPI" ]] || {
  echo "Firefox AMO upload XPI was not generated." >&2
  exit 1
}
FIRST_AMO_HASH="$(shasum -a 256 "$AMO_XPI" | awk '{print $1}')"
python3 "$ROOT_DIR/script/firefox_extension_release.py" package-amo \
  --output-dir "$TMP_DIR" \
  --no-record-ledger >/dev/null
SECOND_AMO_HASH="$(shasum -a 256 "$AMO_XPI" | awk '{print $1}')"
[[ "$FIRST_AMO_HASH" == "$SECOND_AMO_HASH" ]] || {
  echo "Firefox AMO upload XPI is not deterministic." >&2
  exit 1
}
python3 - "$AMO_XPI" <<'PY'
import json
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    manifest = json.loads(archive.read("manifest.json"))
gecko = manifest["browser_specific_settings"]["gecko"]
assert "update_url" not in gecko
assert gecko["data_collection_permissions"]["required"] == [
    "authenticationInfo",
    "browsingActivity",
    "websiteContent",
]
PY

"$ROOT_DIR/script/package_firefox_extension.sh" "$TMP_DIR" --no-record-ledger >/dev/null
[[ -f "$XPI" ]] || {
  echo "Unsigned Firefox validation XPI was not generated." >&2
  exit 1
}
FIRST_HASH="$(shasum -a 256 "$XPI" | awk '{print $1}')"

"$ROOT_DIR/script/package_firefox_extension.sh" "$TMP_DIR" --no-record-ledger >/dev/null
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
VALID_SIGNED_XPI="$TMP_DIR/knowledge-capture-firefox-$VERSION.xpi"
SIGNATURE_MANIFEST="$TMP_DIR/manifest.mf"
SIGNATURE_FILE="$TMP_DIR/signature.sf"
SIGNATURE_RSA="$TMP_DIR/signature.rsa"
SIGNING_CERTIFICATE="$TMP_DIR/signing-certificate.pem"
SIGNING_KEY="$TMP_DIR/signing-key.pem"
UPDATES_JSON="$TMP_DIR/updates.json"

python3 - "$XPI" "$EMPTY_SIGNATURE_XPI" "$TAMPERED_PAYLOAD_XPI" "$EXTRA_PAYLOAD_XPI" "$FORGED_SIGNATURE_XPI" "$SIGNATURE_MANIFEST" "$SIGNATURE_FILE" <<'PY'
import base64
import hashlib
import sys
import zipfile

(
    source_path,
    empty_path,
    tampered_path,
    extra_path,
    forged_path,
    signature_manifest_path,
    signature_file_path,
) = sys.argv[1:]
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
open(signature_manifest_path, "wb").write(signature_manifest)
open(signature_file_path, "wb").write(signature_file)
write_xpi(
    forged_path,
    extra_entries={
        "META-INF/manifest.mf": signature_manifest,
        "META-INF/fake.sf": signature_file,
        "META-INF/fake.rsa": plausible_pkcs7,
    },
)
PY

openssl req -x509 -newkey rsa:2048 -nodes \
  -subj "/CN=Firefox release tooling test/" \
  -keyout "$SIGNING_KEY" \
  -out "$SIGNING_CERTIFICATE" \
  -days 1 >/dev/null 2>&1
openssl smime -sign -binary \
  -in "$SIGNATURE_FILE" \
  -signer "$SIGNING_CERTIFICATE" \
  -inkey "$SIGNING_KEY" \
  -outform DER \
  -out "$SIGNATURE_RSA"

python3 - "$XPI" "$VALID_SIGNED_XPI" "$SIGNATURE_MANIFEST" "$SIGNATURE_FILE" "$SIGNATURE_RSA" <<'PY'
import sys
import zipfile

source_path, destination_path, manifest_path, signature_file_path, signature_path = sys.argv[1:]
with zipfile.ZipFile(source_path) as source:
    payloads = {name: source.read(name) for name in source.namelist()}
with zipfile.ZipFile(destination_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name, value in payloads.items():
        archive.writestr(name, value)
    archive.writestr("META-INF/manifest.mf", open(manifest_path, "rb").read())
    archive.writestr("META-INF/test.sf", open(signature_file_path, "rb").read())
    archive.writestr("META-INF/test.rsa", open(signature_path, "rb").read())
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

python3 "$ROOT_DIR/script/firefox_extension_release.py" verify-signed \
  --signed-xpi "$VALID_SIGNED_XPI" >/dev/null
python3 "$ROOT_DIR/script/firefox_extension_release.py" updates \
  --signed-xpi "$VALID_SIGNED_XPI" \
  --output "$UPDATES_JSON" >/dev/null
python3 "$ROOT_DIR/script/firefox_extension_release.py" verify-updates \
  --signed-xpi "$VALID_SIGNED_XPI" \
  --updates "$UPDATES_JSON" >/dev/null

TAMPERED_UPDATES_JSON="$TMP_DIR/tampered-updates.json"
python3 - "$UPDATES_JSON" "$TAMPERED_UPDATES_JSON" <<'PY'
import json
import sys

source_path, destination_path = sys.argv[1:]
value = json.load(open(source_path, encoding="utf-8"))
addon = next(iter(value["addons"].values()))
addon["updates"][0]["update_hash"] = "sha256:" + "0" * 64
open(destination_path, "w", encoding="utf-8").write(json.dumps(value) + "\n")
PY

if python3 "$ROOT_DIR/script/firefox_extension_release.py" verify-updates \
  --signed-xpi "$VALID_SIGNED_XPI" \
  --updates "$TAMPERED_UPDATES_JSON" >/dev/null 2>&1; then
  echo "A Firefox updates manifest with a false hash was incorrectly accepted." >&2
  exit 1
fi

python3 - "$ROOT_DIR/script/firefox_extension_release.py" "$VALID_SIGNED_XPI" "$UPDATES_JSON" "$TMP_DIR/fetched" <<'PY'
import importlib.util
import json
import pathlib
import shutil
import sys
import zipfile

module_path, signed_xpi_value, updates_value, fetched_directory_value = sys.argv[1:]
spec = importlib.util.spec_from_file_location("firefox_extension_release", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
signed_xpi = pathlib.Path(signed_xpi_value)
updates_path = pathlib.Path(updates_value)
updates_data = updates_path.read_bytes()
xpi_data = signed_xpi.read_bytes()

def local_download(url, label, allowed_content_types, maximum_bytes):
    del allowed_content_types, maximum_bytes
    if "updates manifest" in label:
        return updates_data, url
    return xpi_data, url

module.download_release_resource = local_download
module.verify_remote_release(signed_xpi, updates_path)
fetched_xpi, fetched_updates = module.fetch_verified_remote_release(
    pathlib.Path(fetched_directory_value)
)
assert fetched_xpi.read_bytes() == xpi_data
assert fetched_updates.read_bytes() == updates_data
module.inspect_signed_xpi(fetched_xpi)
module.validate_updates_manifest(fetched_xpi, fetched_updates.read_bytes())

def tampered_xpi_download(url, label, allowed_content_types, maximum_bytes):
    del allowed_content_types, maximum_bytes
    if "updates manifest" in label:
        return updates_data, url
    return xpi_data + b"tampered", url

module.download_release_resource = tampered_xpi_download
try:
    module.verify_remote_release(signed_xpi, updates_path)
except module.ReleaseError as error:
    assert "SHA-256" in str(error)
else:
    raise AssertionError("a remote XPI with mismatched bytes was accepted")

original_getaddrinfo = module.socket.getaddrinfo
try:
    try:
        module.validate_public_https_url(
            "https://127.0.0.1/updates.json", "private test URL"
        )
    except module.ReleaseError as error:
        assert "non-public address" in str(error)
    else:
        raise AssertionError("private update host was accepted")

    module.socket.getaddrinfo = lambda *args, **kwargs: [
        (module.socket.AF_INET, module.socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))
    ]
    assert module.validate_public_https_url(
        "https://updates.example.test/updates.json", "public test URL"
    ).startswith("https://")
    try:
        module.validate_public_https_url(
            "https://other.example.test/file.xpi",
            "redirect test URL",
            "updates.example.test",
        )
    except module.ReleaseError as error:
        assert "unexpected host" in str(error)
    else:
        raise AssertionError("cross-host redirect was accepted")
finally:
    module.socket.getaddrinfo = original_getaddrinfo

repository_root = pathlib.Path(module_path).resolve().parent.parent
ledger_fixture = pathlib.Path(fetched_directory_value).parent / "signed-ledger-fixture"
shutil.copytree(repository_root / "BrowserExtension", ledger_fixture / "BrowserExtension")
module.ROOT = ledger_fixture
module.EXTENSION_ROOT = ledger_fixture / "BrowserExtension"
module.FIREFOX_ROOT = module.EXTENSION_ROOT / "Firefox"
module.CONFIG_PATH = module.EXTENSION_ROOT / "firefox-release.json"
installed_directory = ledger_fixture / "dist" / "browser-extension"
installed_xpi, installed_updates = module.install_signed_release(
    signed_xpi,
    installed_directory,
)
assert installed_xpi.read_bytes() == xpi_data
module.validate_updates_manifest(installed_xpi, installed_updates.read_bytes())
ledger_path = module.EXTENSION_ROOT / "release-ledger.json"
ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
artifact_kinds = {
    artifact["kind"] for artifact in ledger["releases"][-1]["artifacts"]
}
assert "firefox-signed-xpi" in artifact_kinds
assert "firefox-updates-json" in artifact_kinds
ledger_bytes = ledger_path.read_bytes()
module.install_signed_release(signed_xpi, installed_directory)
assert ledger_path.read_bytes() == ledger_bytes

repacked_xpi = ledger_fixture / "repacked-same-version.xpi"
with zipfile.ZipFile(signed_xpi) as source, zipfile.ZipFile(
    repacked_xpi,
    "w",
    compression=zipfile.ZIP_DEFLATED,
) as destination:
    for name in reversed(source.namelist()):
        destination.writestr(name, source.read(name))
assert repacked_xpi.read_bytes() != signed_xpi.read_bytes()
module.inspect_signed_xpi(repacked_xpi)
try:
    module.install_signed_release(repacked_xpi, installed_directory)
except module.ReleaseLedgerError as error:
    assert "does not match immutable ledger" in str(error)
else:
    raise AssertionError("a different signed XPI replaced the same ledger version")
PY

echo "Firefox extension release tooling: passed"
