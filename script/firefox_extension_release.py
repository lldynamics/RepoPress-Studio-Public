#!/usr/bin/env python3
"""Build and validate Firefox extension release artifacts without publishing them."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
EXTENSION_ROOT = ROOT / "BrowserExtension"
FIREFOX_ROOT = EXTENSION_ROOT / "Firefox"
CONFIG_PATH = EXTENSION_ROOT / "firefox-release.json"
REQUIRED_SOURCE_FILES = (
    "background.js",
    "manifest.json",
    "popup.css",
    "popup.html",
    "popup.js",
)
SHARED_SOURCE_FILES = tuple(name for name in REQUIRED_SOURCE_FILES if name != "manifest.json")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){2,3}$")
LEGACY_SIGNATURE_MANIFEST = "meta-inf/manifest.mf"
COSE_SIGNATURE_MANIFEST = "meta-inf/cose.manifest"
COSE_SIGNATURE = "meta-inf/cose.sig"
MAXIMUM_SIGNATURE_METADATA_BYTES = 8 * 1_024 * 1_024
PKCS7_SIGNED_DATA_OID = bytes.fromhex("06092a864886f70d010702")
PINNED_WEB_EXT_VERSION = "10.5.0"


class ReleaseError(RuntimeError):
    pass


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Cannot read valid JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"Expected a JSON object in {path}")
    return value


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def encoded_json(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def require_https_url(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise ReleaseError(f"{label} must be a string")
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ReleaseError(f"{label} must be an HTTPS URL without embedded credentials")
    return value.rstrip("/")


def validated_release() -> tuple[dict, dict, dict]:
    chromium_manifest = load_json(EXTENSION_ROOT / "manifest.json")
    firefox_manifest = load_json(FIREFOX_ROOT / "manifest.json")
    config = load_json(CONFIG_PATH)

    version = firefox_manifest.get("version")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError("Firefox manifest version must be a three- or four-part numeric version")
    if chromium_manifest.get("version") != version:
        raise ReleaseError("Chromium and Firefox extension versions must match")

    gecko = firefox_manifest.get("browser_specific_settings", {}).get("gecko", {})
    if gecko.get("id") != config.get("addonID"):
        raise ReleaseError("Firefox manifest ID must match firefox-release.json addonID")
    if gecko.get("data_collection_permissions", {}).get("required") != ["none"]:
        raise ReleaseError('Firefox must explicitly declare required data collection as ["none"]')
    if "update_url" in gecko:
        raise ReleaseError("Development manifest must not contain update_url; release packaging injects it")
    if config.get("channel") != "unlisted":
        raise ReleaseError("Only the Mozilla unlisted/self-distributed channel is supported")
    require_https_url(config.get("updateManifestURL"), "updateManifestURL")
    require_https_url(config.get("xpiBaseURL"), "xpiBaseURL")

    for name in REQUIRED_SOURCE_FILES:
        path = FIREFOX_ROOT / name
        if not path.is_file() or path.is_symlink():
            raise ReleaseError(f"Required regular Firefox source file is missing: {path}")
    for name in SHARED_SOURCE_FILES:
        if (FIREFOX_ROOT / name).read_bytes() != (EXTENSION_ROOT / name).read_bytes():
            raise ReleaseError(f"Shared Firefox extension source is out of sync: {name}")

    return chromium_manifest, firefox_manifest, config


def release_manifest(firefox_manifest: dict, config: dict) -> dict:
    manifest = json.loads(json.dumps(firefox_manifest))
    manifest["browser_specific_settings"]["gecko"]["update_url"] = require_https_url(
        config["updateManifestURL"], "updateManifestURL"
    )
    return manifest


def expected_release_payloads(firefox_manifest: dict, config: dict) -> dict[str, bytes]:
    payloads = {
        name: (FIREFOX_ROOT / name).read_bytes()
        for name in REQUIRED_SOURCE_FILES
        if name != "manifest.json"
    }
    payloads["manifest.json"] = encoded_json(release_manifest(firefox_manifest, config))
    return payloads


def prepare_source(output_dir: Path) -> tuple[str, Path, Path]:
    _, firefox_manifest, config = validated_release()
    version = firefox_manifest["version"]
    source_dir = output_dir / f"firefox-source-{version}"
    unsigned_xpi = output_dir / f"knowledge-capture-firefox-{version}-unsigned.xpi"

    if source_dir.exists():
        shutil.rmtree(source_dir)
    source_dir.mkdir(parents=True, exist_ok=False)
    for name in REQUIRED_SOURCE_FILES:
        if name != "manifest.json":
            shutil.copyfile(FIREFOX_ROOT / name, source_dir / name)

    prepared_manifest = release_manifest(firefox_manifest, config)
    write_json(source_dir / "manifest.json", prepared_manifest)
    write_deterministic_xpi(source_dir, unsigned_xpi)
    validate_unsigned_xpi(unsigned_xpi, prepared_manifest)
    return version, source_dir, unsigned_xpi


def write_deterministic_xpi(source_dir: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        destination.unlink()
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(source_dir.iterdir(), key=lambda item: item.name):
            if not path.is_file() or path.is_symlink():
                raise ReleaseError(f"Unexpected Firefox release source entry: {path}")
            info = zipfile.ZipInfo(path.name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())


def validate_unsigned_xpi(path: Path, expected_manifest: dict) -> None:
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        if names != set(REQUIRED_SOURCE_FILES):
            raise ReleaseError(f"Unsigned XPI has unexpected entries: {sorted(names)}")
        archived_manifest = json.loads(archive.read("manifest.json"))
    if archived_manifest != expected_manifest:
        raise ReleaseError("Unsigned XPI manifest does not match the prepared release manifest")


def normalized_archive_name(name: str) -> str:
    normalized = name.replace("\\", "/")
    parts = normalized.split("/")
    if (
        not normalized
        or normalized.startswith("/")
        or any(part in ("", ".", "..") for part in parts)
    ):
        raise ReleaseError(f"Signed XPI contains an unsafe archive path: {name!r}")
    return normalized.lower()


def is_symlink(info: zipfile.ZipInfo) -> bool:
    return ((info.external_attr >> 16) & 0o170000) == 0o120000


def parse_jar_manifest(data: bytes, label: str) -> list[dict[str, str]]:
    try:
        text = data.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    except UnicodeDecodeError as error:
        raise ReleaseError(f"{label} is not valid UTF-8") from error
    unfolded: list[str] = []
    for line in text.split("\n"):
        if line.startswith(" "):
            if not unfolded:
                raise ReleaseError(f"{label} starts with an invalid continuation line")
            unfolded[-1] += line[1:]
        else:
            unfolded.append(line)
    sections: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in unfolded:
        if not line:
            if current:
                sections.append(current)
                current = {}
            continue
        if ": " not in line:
            raise ReleaseError(f"{label} contains an invalid attribute line")
        key, value = line.split(": ", 1)
        if key in current:
            raise ReleaseError(f"{label} contains a duplicate attribute: {key}")
        current[key] = value
    if current:
        sections.append(current)
    if not sections:
        raise ReleaseError(f"{label} is empty")
    return sections


def decoded_digest(value: str, label: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ReleaseError(f"{label} contains an invalid base64 digest") from error


def verify_legacy_manifest_payloads(
    archive: zipfile.ZipFile,
    entries: dict[str, zipfile.ZipInfo],
    manifest_bytes: bytes,
) -> None:
    sections = parse_jar_manifest(manifest_bytes, "META-INF/manifest.mf")
    if sections[0].get("Manifest-Version") != "1.0":
        raise ReleaseError("META-INF/manifest.mf has an unsupported manifest version")
    expected_names = {
        name
        for name in entries
        if name != LEGACY_SIGNATURE_MANIFEST
        and not name.endswith(".sf")
        and not name.endswith(".rsa")
    }
    covered_names: set[str] = set()
    for section in sections[1:]:
        raw_name = section.get("Name")
        if not raw_name:
            raise ReleaseError("META-INF/manifest.mf contains an entry without a name")
        name = normalized_archive_name(raw_name)
        if name in covered_names or name not in expected_names:
            raise ReleaseError("META-INF/manifest.mf does not match the signed XPI payload")
        expected_digest = decoded_digest(
            section.get("SHA256-Digest", ""),
            f"META-INF/manifest.mf entry {raw_name}",
        )
        actual_digest = hashlib.sha256(archive.read(entries[name])).digest()
        if expected_digest != actual_digest:
            raise ReleaseError(f"Mozilla signature manifest does not cover the payload: {raw_name}")
        covered_names.add(name)
    if covered_names != expected_names:
        raise ReleaseError("Mozilla signature manifest does not cover every release payload file")


def verify_pkcs7_signature(signature_bytes: bytes, signed_bytes: bytes) -> None:
    openssl = shutil.which("openssl")
    if openssl is None:
        raise ReleaseError("OpenSSL is required to verify the Firefox PKCS#7 signature envelope")
    with tempfile.TemporaryDirectory(prefix="firefox-xpi-signature-") as directory:
        directory_path = Path(directory)
        signature_path = directory_path / "signature.rsa"
        content_path = directory_path / "signature.sf"
        signature_path.write_bytes(signature_bytes)
        content_path.write_bytes(signed_bytes)
        try:
            result = subprocess.run(
                [
                    openssl,
                    "smime",
                    "-verify",
                    "-inform",
                    "DER",
                    "-in",
                    str(signature_path),
                    "-content",
                    str(content_path),
                    "-noverify",
                    "-binary",
                    "-out",
                    os.devnull,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReleaseError(f"Could not verify the Firefox PKCS#7 signature: {error}") from error
    if result.returncode != 0:
        raise ReleaseError("Firefox PKCS#7 signature does not authenticate its signature manifest")


def validate_signature_envelope(
    archive: zipfile.ZipFile,
    entries: dict[str, zipfile.ZipInfo],
) -> None:
    metadata_entries = {
        name: info for name, info in entries.items() if name.startswith("meta-inf/")
    }
    metadata_size = sum(info.file_size for info in metadata_entries.values())
    if metadata_size > MAXIMUM_SIGNATURE_METADATA_BYTES:
        raise ReleaseError("XPI signature metadata exceeds the 8 MB safety limit")

    legacy_manifest = metadata_entries.get(LEGACY_SIGNATURE_MANIFEST)
    legacy_pairs: list[tuple[zipfile.ZipInfo, zipfile.ZipInfo]] = []
    for name, rsa_info in metadata_entries.items():
        if not name.endswith(".rsa"):
            continue
        sf_info = metadata_entries.get(name[:-4] + ".sf")
        if sf_info is not None:
            legacy_pairs.append((rsa_info, sf_info))

    legacy_valid = False
    if legacy_manifest is not None and legacy_pairs:
        manifest_bytes = archive.read(legacy_manifest)
        if manifest_bytes.startswith(b"Manifest-Version: 1.0"):
            for rsa_info, sf_info in legacy_pairs:
                rsa_bytes = archive.read(rsa_info)
                sf_bytes = archive.read(sf_info)
                if (
                    len(rsa_bytes) >= 256
                    and rsa_bytes.startswith(b"\x30")
                    and PKCS7_SIGNED_DATA_OID in rsa_bytes
                    and sf_bytes.startswith(b"Signature-Version: 1.0")
                ):
                    signature_sections = parse_jar_manifest(sf_bytes, sf_info.filename)
                    signed_manifest_digest = decoded_digest(
                        signature_sections[0].get("SHA256-Digest-Manifest", ""),
                        sf_info.filename,
                    )
                    if signed_manifest_digest != hashlib.sha256(manifest_bytes).digest():
                        raise ReleaseError(
                            "Firefox signature file does not authenticate META-INF/manifest.mf"
                        )
                    verify_legacy_manifest_payloads(archive, entries, manifest_bytes)
                    verify_pkcs7_signature(rsa_bytes, sf_bytes)
                    legacy_valid = True
                    break

    cose_manifest = metadata_entries.get(COSE_SIGNATURE_MANIFEST)
    cose_signature = metadata_entries.get(COSE_SIGNATURE)
    cose_valid = False
    if cose_manifest is not None and cose_signature is not None:
        cose_valid = len(archive.read(cose_manifest)) > 0 and len(archive.read(cose_signature)) >= 64

    if cose_manifest is not None or cose_signature is not None:
        if not cose_valid:
            raise ReleaseError("XPI contains an incomplete or empty COSE signature envelope")

    if not legacy_valid:
        raise ReleaseError(
            "XPI does not contain a complete, authenticated Mozilla legacy signature envelope"
        )


def inspect_signed_xpi(path: Path) -> tuple[dict, str, str]:
    _, firefox_manifest, config = validated_release()
    expected_manifest = release_manifest(firefox_manifest, config)
    expected_payloads = expected_release_payloads(firefox_manifest, config)
    if not path.is_file():
        raise ReleaseError(f"Signed XPI is missing: {path}")
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            normalized_names: list[str] = []
            file_infos: list[zipfile.ZipInfo] = []
            for info in infos:
                if is_symlink(info):
                    raise ReleaseError("Signed XPI contains a symbolic-link entry")
                archive_name = info.filename[:-1] if info.is_dir() else info.filename
                normalized_name = normalized_archive_name(archive_name)
                if info.is_dir():
                    if normalized_name != "meta-inf" and not normalized_name.startswith("meta-inf/"):
                        raise ReleaseError("Signed XPI contains an unexpected directory entry")
                    continue
                normalized_names.append(normalized_name)
                file_infos.append(info)
            if len(set(normalized_names)) != len(normalized_names):
                raise ReleaseError("Signed XPI contains duplicate or case-colliding entries")
            entries = dict(zip(normalized_names, file_infos))
            payload_entries = {
                name for name in entries if not name.startswith("meta-inf/")
            }
            if payload_entries != set(expected_payloads):
                raise ReleaseError(
                    f"Signed XPI payload has unexpected entries: {sorted(payload_entries)}"
                )
            signature_metadata_size = sum(
                info.file_size
                for name, info in entries.items()
                if name.startswith("meta-inf/")
            )
            if signature_metadata_size > MAXIMUM_SIGNATURE_METADATA_BYTES:
                raise ReleaseError("XPI signature metadata exceeds the 8 MB safety limit")
            if archive.testzip() is not None:
                raise ReleaseError("Signed XPI contains a corrupt compressed entry")
            for name, expected_bytes in expected_payloads.items():
                if archive.read(entries[name]) != expected_bytes:
                    raise ReleaseError(
                        f"Signed XPI payload does not match the prepared release source: {name}"
                    )
            validate_signature_envelope(archive, entries)
            manifest = json.loads(archive.read(entries["manifest.json"]))
    except (OSError, KeyError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        raise ReleaseError(f"Signed XPI is invalid: {error}") from error
    if manifest.get("version") != expected_manifest.get("version"):
        raise ReleaseError("Signed XPI version does not match the repository manifest")
    gecko = manifest.get("browser_specific_settings", {}).get("gecko", {})
    if gecko.get("id") != config.get("addonID"):
        raise ReleaseError("Signed XPI add-on ID does not match firefox-release.json")
    expected_update_url = require_https_url(config["updateManifestURL"], "updateManifestURL")
    if gecko.get("update_url") != expected_update_url:
        raise ReleaseError("Signed XPI does not contain the configured HTTPS update_url")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return manifest, digest, expected_update_url


def web_ext_executable() -> str:
    local_executable = ROOT / "node_modules" / ".bin" / "web-ext"
    if local_executable.is_file() and os.access(local_executable, os.X_OK):
        return str(local_executable)
    executable = shutil.which("web-ext")
    if executable is None:
        raise ReleaseError(
            f"web-ext {PINNED_WEB_EXT_VERSION} is required; install it with "
            f"npm install --global web-ext@{PINNED_WEB_EXT_VERSION}"
        )
    return executable


def command_lint(_: argparse.Namespace) -> None:
    executable = web_ext_executable()
    version_result = subprocess.run(
        [executable, "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=15,
        check=False,
    )
    actual_version = version_result.stdout.strip()
    if version_result.returncode != 0 or actual_version != PINNED_WEB_EXT_VERSION:
        raise ReleaseError(
            f"Expected web-ext {PINNED_WEB_EXT_VERSION}, found {actual_version or 'unavailable'}"
        )
    environment = os.environ.copy()
    environment["NO_UPDATE_NOTIFIER"] = "1"
    lint_result = subprocess.run(
        [
            executable,
            "lint",
            "--warnings-as-errors",
            "--self-hosted",
            "--no-config-discovery",
            "--boring",
            "--source-dir",
            str(FIREFOX_ROOT),
        ],
        cwd=ROOT,
        env=environment,
        timeout=60,
        check=False,
    )
    if lint_result.returncode != 0:
        raise ReleaseError("web-ext lint rejected the Firefox extension")
    print(f"Firefox web-ext {PINNED_WEB_EXT_VERSION} lint: passed")


def build_updates_manifest(signed_xpi: Path, output_path: Path) -> None:
    manifest, digest, _ = inspect_signed_xpi(signed_xpi)
    config = load_json(CONFIG_PATH)
    addon_id = config["addonID"]
    xpi_base_url = require_https_url(config["xpiBaseURL"], "xpiBaseURL")
    xpi_name = urllib.parse.quote(signed_xpi.name)
    update_link = f"{xpi_base_url}/{xpi_name}"
    result = {
        "addons": {
            addon_id: {
                "updates": [
                    {
                        "applications": {
                            "gecko": {
                                "strict_min_version": manifest["browser_specific_settings"]["gecko"][
                                    "strict_min_version"
                                ]
                            }
                        },
                        "update_hash": f"sha256:{digest}",
                        "update_link": update_link,
                        "version": manifest["version"],
                    }
                ]
            }
        }
    }
    write_json(output_path, result)
    print(f"Firefox update manifest: {output_path}")


def command_package(args: argparse.Namespace) -> None:
    output_dir = Path(args.output_dir).resolve()
    version, source_dir, unsigned_xpi = prepare_source(output_dir)
    print(f"Firefox release source: {source_dir}")
    print(f"Unsigned Firefox candidate {version}: {unsigned_xpi}")
    print("This candidate is for validation only and cannot be permanently installed in release Firefox.")


def command_verify_signed(args: argparse.Namespace) -> None:
    path = Path(args.signed_xpi).resolve()
    manifest, digest, _ = inspect_signed_xpi(path)
    print(f"Firefox signed XPI payload and signature envelope verified: {path}")
    print("Firefox performs the final Mozilla certificate trust check during installation.")
    print(f"Version: {manifest['version']}")
    print(f"SHA-256: {digest}")


def command_updates(args: argparse.Namespace) -> None:
    build_updates_manifest(Path(args.signed_xpi).resolve(), Path(args.output).resolve())


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    lint = subparsers.add_parser("lint", help="lint the Firefox extension with the pinned web-ext")
    lint.set_defaults(function=command_lint)

    package = subparsers.add_parser("package", help="prepare release source and an unsigned validation XPI")
    package.add_argument("--output-dir", default=str(ROOT / "dist" / "browser-extension"))
    package.set_defaults(function=command_package)

    verify = subparsers.add_parser("verify-signed", help="verify a Mozilla-signed XPI")
    verify.add_argument("--signed-xpi", required=True)
    verify.set_defaults(function=command_verify_signed)

    updates = subparsers.add_parser("updates", help="generate updates.json from a verified signed XPI")
    updates.add_argument("--signed-xpi", required=True)
    updates.add_argument("--output", required=True)
    updates.set_defaults(function=command_updates)

    return parser.parse_args()


def main() -> int:
    try:
        args = parse_arguments()
        args.function(args)
    except ReleaseError as error:
        print(f"Firefox release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
