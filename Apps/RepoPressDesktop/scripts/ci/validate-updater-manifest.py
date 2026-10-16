#!/usr/bin/env python3
"""Offline structural and cryptographic checks for a Tauri updater candidate."""

import argparse
import base64
import datetime
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import socket
import subprocess
import tempfile
import unicodedata
from urllib.parse import unquote, urlsplit


def fail(message: str):
    raise SystemExit(message)


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def contains_control(value: str) -> bool:
    return any(unicodedata.category(character) == "Cc" for character in value)


def is_canonical_base64(value: str) -> bool:
    if not re.fullmatch(
        r"(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?",
        value,
    ):
        return False
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        return False
    return base64.b64encode(decoded).decode("ascii") == value


RFC3339_PATTERN = re.compile(
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})"
)


def is_rfc3339(value: str) -> bool:
    if not RFC3339_PATTERN.fullmatch(value):
        return False
    try:
        datetime.datetime.fromisoformat(value.removesuffix("Z") + ("+00:00" if value.endswith("Z") else ""))
    except ValueError:
        return False
    return True


def is_ip_hostname(hostname: str) -> bool:
    try:
        ipaddress.ip_address(hostname)
        return True
    except ValueError:
        pass
    try:
        socket.inet_aton(hostname)
        return True
    except OSError:
        return False


def has_public_hostname_syntax(hostname: str) -> bool:
    try:
        ascii_hostname = hostname.encode("idna").decode("ascii")
    except UnicodeError:
        return False
    if len(ascii_hostname) > 253:
        return False
    return all(
        re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
        for label in ascii_hostname.split(".")
    )


parser = argparse.ArgumentParser()
parser.add_argument("--bundle-dir", type=pathlib.Path, required=True)
parser.add_argument("--manifest", type=pathlib.Path, required=True)
parser.add_argument("--version", required=True)
parser.add_argument("--release-tag", required=True)
parser.add_argument("--public-key", type=pathlib.Path, required=True)
parser.add_argument("--review-summary", type=pathlib.Path, required=True)
args = parser.parse_args()

if args.release_tag != f"v{args.version}":
    fail("release tag does not exactly match manifest version")
if not args.bundle_dir.is_dir():
    fail("bundle directory does not exist")
images = sorted(args.bundle_dir.glob("*.AppImage"))
sigs = sorted(args.bundle_dir.glob("*.AppImage.sig"))
if len(images) != 1 or len(sigs) != 1:
    fail("expected exactly one AppImage and signature")
if sigs[0].name != f"{images[0].name}.sig":
    fail("signature filename must exactly match the AppImage filename")
for artifact in (images[0], sigs[0], args.manifest, args.public_key):
    if artifact.is_symlink():
        fail("updater artifacts and public key must not be symbolic links")
    if not artifact.is_file():
        fail(f"required updater file is missing: {artifact}")
if images[0].stat().st_size == 0:
    fail("AppImage is empty")
if images[0].stat().st_size > 536_870_912:
    fail("AppImage exceeds the 512 MiB client download limit")
if not 1 <= sigs[0].stat().st_size <= 65_536:
    fail("signature file is empty or too large")
if not 1 <= args.public_key.stat().st_size <= 8_192:
    fail("public key file is empty or too large")
if not 1 <= args.manifest.stat().st_size <= 65_536:
    fail("manifest is empty or exceeds the 64 KiB client limit")

try:
    data = json.loads(
        args.manifest.read_text(encoding="utf-8"),
        object_pairs_hook=reject_duplicate_keys,
    )
except Exception as exc:
    fail(f"invalid JSON: {exc}")
if not isinstance(data, dict) or set(data) != {"version", "notes", "pub_date", "platforms"}:
    fail("manifest must contain exactly version, notes, pub_date, and platforms")
if data.get("version") != args.version:
    fail("manifest version mismatch")
if (
    not isinstance(data.get("notes"), str)
    or not 1 <= len(data["notes"]) <= 4_096
    or not data["notes"].strip()
    or contains_control(data["notes"])
):
    fail("manifest notes must be 1-4096 control-free characters")
if not isinstance(data.get("pub_date"), str) or not is_rfc3339(data["pub_date"]):
    fail("manifest publication date must be RFC 3339")
platforms = data.get("platforms")
if not isinstance(platforms, dict) or set(platforms) != {"linux-x86_64"}:
    fail("manifest must contain exactly the linux-x86_64 platform")
entry = platforms["linux-x86_64"]
if not isinstance(entry, dict) or set(entry) != {"signature", "url"}:
    fail("linux-x86_64 manifest entry must contain exactly signature and url")
signature = entry.get("signature")
url = entry.get("url")
if (
    not isinstance(signature, str)
    or not 1 <= len(signature) <= 65_536
    or contains_control(signature)
    or not is_canonical_base64(signature)
):
    fail("signature missing or malformed")
try:
    signature_file = sigs[0].read_text(encoding="utf-8")
except (OSError, UnicodeError) as exc:
    fail(f"signature is not readable UTF-8: {exc}")
if signature_file != signature:
    fail("manifest signature does not match .AppImage.sig")

if (
    not isinstance(url, str)
    or not 1 <= len(url) <= 8_192
    or contains_control(url)
    or any(character.isspace() for character in url)
):
    fail("updater URL must be a bounded control-free URL")
try:
    parsed = urlsplit(url)
    hostname = (parsed.hostname or "").rstrip(".").lower()
except ValueError as exc:
    fail(f"updater URL is invalid: {exc}")
try:
    parsed_port = parsed.port
except ValueError as exc:
    fail(f"updater URL port is invalid: {exc}")
if (
    parsed.scheme != "https"
    or not parsed.netloc
    or "@" in parsed.netloc
    or parsed.username
    or parsed.password
    or "#" in url
    or parsed.fragment
    or parsed_port not in (None, 443)
    or not hostname
    or not has_public_hostname_syntax(hostname)
    or hostname == "localhost"
    or hostname.endswith(".localhost")
    or hostname.endswith(".local")
    or "." not in hostname
    or is_ip_hostname(hostname)
):
    fail("updater URL must be HTTPS without credentials, fragments, or a nonstandard port")
try:
    url_filename = unquote(pathlib.PurePosixPath(parsed.path).name, errors="strict")
except (UnicodeError, ValueError) as exc:
    fail(f"updater URL filename is invalid: {exc}")
if url_filename != images[0].name:
    fail("updater URL filename does not exactly match the AppImage")

verifier = pathlib.Path(__file__).resolve().parents[1] / "release" / "updater-signature.mjs"
verification = subprocess.run(
    [
        "node",
        str(verifier),
        "--artifact",
        str(images[0]),
        "--signature",
        str(sigs[0]),
        "--public-key",
        str(args.public_key),
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    check=False,
)
if verification.returncode != 0:
    detail = verification.stderr.strip() or "unknown verifier failure"
    fail(f"cryptographic updater signature verification failed: {detail}")
try:
    verified = json.loads(verification.stdout)
except json.JSONDecodeError as exc:
    fail(f"signature verifier returned invalid JSON: {exc}")
if verified.get("algorithm") != "ED" or not re.fullmatch(
    r"[0-9a-f]{16}", str(verified.get("keyId", ""))
):
    fail("signature verifier returned invalid algorithm or key identity")

digest = hashlib.sha256()
with images[0].open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
summary = {
    "version": data["version"],
    "release_tag": args.release_tag,
    "appimage": images[0].name,
    "url": url,
    "sha256": digest.hexdigest(),
    "signature_bytes": len(signature),
    "signature_algorithm": verified.get("algorithm"),
    "signing_key_id": verified.get("keyId"),
}
if args.review_summary.exists() and args.review_summary.is_symlink():
    fail("review summary must not be a symbolic link")
args.review_summary.parent.mkdir(parents=True, exist_ok=True)
temporary_summary = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=args.review_summary.parent,
        prefix=f".{args.review_summary.name}.",
        suffix=".tmp",
        delete=False,
    ) as stream:
        temporary_summary = pathlib.Path(stream.name)
        stream.write(f"{json.dumps(summary, sort_keys=True, indent=2)}\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary_summary, args.review_summary)
    temporary_summary = None
finally:
    if temporary_summary is not None:
        temporary_summary.unlink(missing_ok=True)
print(json.dumps(summary, sort_keys=True))
