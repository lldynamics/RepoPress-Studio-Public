#!/usr/bin/env python3
"""Build and validate Firefox extension release artifacts without publishing them."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from browser_extension_release_ledger import (
    ReleaseLedgerError,
    assert_artifact_matches_record,
    assert_source_version_allowed,
    install_immutable_artifact,
    record_artifacts,
)


ROOT = Path(__file__).resolve().parent.parent
EXTENSION_ROOT = ROOT / "BrowserExtension"
FIREFOX_ROOT = EXTENSION_ROOT / "Firefox"
CONFIG_PATH = EXTENSION_ROOT / "firefox-release.json"
REQUIRED_SOURCE_FILES = (
    "_locales/en/messages.json",
    "_locales/zh_CN/messages.json",
    "background-capture.js",
    "background-queue-operations.js",
    "background-queue-storage.js",
    "background-security.js",
    "background.js",
    "icons/icon16.png",
    "icons/icon32.png",
    "icons/icon48.png",
    "icons/icon128.png",
    "manifest.json",
    "popup.css",
    "popup.html",
    "popup.js",
    "protocol.generated.js",
)
SHARED_SOURCE_FILES = tuple(name for name in REQUIRED_SOURCE_FILES if name != "manifest.json")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){2,3}$")
LEGACY_SIGNATURE_MANIFEST = "meta-inf/manifest.mf"
COSE_SIGNATURE_MANIFEST = "meta-inf/cose.manifest"
COSE_SIGNATURE = "meta-inf/cose.sig"
MAXIMUM_SIGNATURE_METADATA_BYTES = 8 * 1_024 * 1_024
MAXIMUM_REMOTE_UPDATE_BYTES = 1 * 1_024 * 1_024
MAXIMUM_REMOTE_XPI_BYTES = 50 * 1_024 * 1_024
PKCS7_SIGNED_DATA_OID = bytes.fromhex("06092a864886f70d010702")
AMO_REQUIRED_DATA_COLLECTION = (
    "authenticationInfo",
    "browsingActivity",
    "websiteContent",
)
UPDATE_CONTENT_TYPES = frozenset(("application/json", "text/json"))
XPI_CONTENT_TYPES = frozenset(
    ("application/x-xpinstall", "application/zip", "application/octet-stream")
)


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

    ledger_version, _ = assert_source_version_allowed(ROOT)
    if ledger_version != version:
        raise ReleaseError("Release ledger version does not match the Firefox manifest")

    return chromium_manifest, firefox_manifest, config


def release_manifest(firefox_manifest: dict, config: dict) -> dict:
    manifest = json.loads(json.dumps(firefox_manifest))
    manifest["browser_specific_settings"]["gecko"]["update_url"] = require_https_url(
        config["updateManifestURL"], "updateManifestURL"
    )
    return manifest


def amo_manifest(firefox_manifest: dict) -> dict:
    manifest = json.loads(json.dumps(firefox_manifest))
    gecko = manifest["browser_specific_settings"]["gecko"]
    gecko.pop("update_url", None)
    gecko["data_collection_permissions"] = {
        "required": list(AMO_REQUIRED_DATA_COLLECTION)
    }
    return manifest


def expected_release_payloads(firefox_manifest: dict, config: dict) -> dict[str, bytes]:
    payloads = {
        name.lower(): (FIREFOX_ROOT / name).read_bytes()
        for name in REQUIRED_SOURCE_FILES
        if name != "manifest.json"
    }
    payloads["manifest.json"] = encoded_json(release_manifest(firefox_manifest, config))
    return payloads


def _source_directory_payloads(path: Path) -> dict[str, bytes]:
    if not path.is_dir() or path.is_symlink():
        raise ReleaseError(f"Firefox release source must be a regular directory: {path}")
    expected_directories = {
        parent.as_posix()
        for name in REQUIRED_SOURCE_FILES
        for parent in Path(name).parents
        if parent != Path(".")
    }
    payloads: dict[str, bytes] = {}
    for item in path.rglob("*"):
        relative_name = item.relative_to(path).as_posix()
        if item.is_symlink():
            raise ReleaseError(f"Unexpected Firefox release source entry: {item}")
        if item.is_dir():
            if relative_name not in expected_directories:
                raise ReleaseError(f"Unexpected Firefox release source entry: {item}")
            continue
        if not item.is_file():
            raise ReleaseError(f"Unexpected Firefox release source entry: {item}")
        payloads[relative_name] = item.read_bytes()
    if set(payloads) != set(REQUIRED_SOURCE_FILES):
        raise ReleaseError(f"Firefox release source has unexpected entries: {sorted(payloads)}")
    return payloads


def _install_immutable_source_directory(candidate: Path, destination: Path) -> None:
    candidate_payloads = _source_directory_payloads(candidate)
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_dir():
            raise ReleaseError(f"Firefox release source path is not a regular directory: {destination}")
        if _source_directory_payloads(destination) != candidate_payloads:
            raise ReleaseError(
                f"Refusing to replace same-version Firefox release source: {destination}"
            )
        return
    try:
        shutil.copytree(candidate, destination)
    except FileExistsError:
        if _source_directory_payloads(destination) != candidate_payloads:
            raise ReleaseError(
                f"Concurrent process created different Firefox release source: {destination}"
            )


def prepare_source(output_dir: Path, record_in_ledger: bool = True) -> tuple[str, Path, Path]:
    _, firefox_manifest, config = validated_release()
    version = firefox_manifest["version"]
    source_dir = output_dir / f"firefox-source-{version}"
    unsigned_xpi = output_dir / f"knowledge-capture-firefox-{version}-unsigned.xpi"
    output_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.is_symlink():
        raise ReleaseError("Firefox release output directory must not be a symbolic link")

    prepared_manifest = release_manifest(firefox_manifest, config)
    with tempfile.TemporaryDirectory(prefix="firefox-release-candidate-", dir=output_dir) as directory:
        candidate_root = Path(directory)
        candidate_source = candidate_root / source_dir.name
        candidate_source.mkdir()
        for name in REQUIRED_SOURCE_FILES:
            if name != "manifest.json":
                destination = candidate_source / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(FIREFOX_ROOT / name, destination)
        write_json(candidate_source / "manifest.json", prepared_manifest)
        candidate_xpi = candidate_root / unsigned_xpi.name
        write_deterministic_xpi(candidate_source, candidate_xpi)
        validate_unsigned_xpi(candidate_xpi, prepared_manifest)
        assert_artifact_matches_record(
            ROOT,
            version,
            "firefox-unsigned-xpi",
            candidate_xpi,
        )
        _install_immutable_source_directory(candidate_source, source_dir)
        install_immutable_artifact(candidate_xpi, unsigned_xpi)
    validate_unsigned_xpi(unsigned_xpi, prepared_manifest)
    if record_in_ledger:
        record_artifacts(
            ROOT,
            version,
            [("firefox-unsigned-xpi", unsigned_xpi)],
        )
    return version, source_dir, unsigned_xpi


def prepare_amo_package(output_dir: Path, record_in_ledger: bool = True) -> tuple[str, Path]:
    _, firefox_manifest, _ = validated_release()
    version = firefox_manifest["version"]
    amo_xpi = output_dir / f"knowledge-capture-firefox-{version}-amo.xpi"
    output_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.is_symlink():
        raise ReleaseError("Firefox AMO output directory must not be a symbolic link")

    prepared_manifest = amo_manifest(firefox_manifest)
    with tempfile.TemporaryDirectory(prefix="firefox-amo-candidate-", dir=output_dir) as directory:
        candidate_root = Path(directory)
        candidate_source = candidate_root / "source"
        candidate_source.mkdir()
        for name in REQUIRED_SOURCE_FILES:
            destination = candidate_source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            if name == "manifest.json":
                write_json(destination, prepared_manifest)
            else:
                shutil.copyfile(FIREFOX_ROOT / name, destination)
        candidate_xpi = candidate_root / amo_xpi.name
        write_deterministic_xpi(candidate_source, candidate_xpi)
        validate_unsigned_xpi(candidate_xpi, prepared_manifest)
        assert_artifact_matches_record(
            ROOT,
            version,
            "firefox-amo-xpi",
            candidate_xpi,
        )
        install_immutable_artifact(candidate_xpi, amo_xpi)
    validate_unsigned_xpi(amo_xpi, prepared_manifest)
    if record_in_ledger:
        record_artifacts(
            ROOT,
            version,
            [("firefox-amo-xpi", amo_xpi)],
        )
    return version, amo_xpi


def write_deterministic_xpi(source_dir: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise ReleaseError(f"Refusing to overwrite an existing XPI candidate: {destination}")
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(REQUIRED_SOURCE_FILES):
            path = source_dir / name
            if not path.is_file() or path.is_symlink():
                raise ReleaseError(f"Unexpected Firefox release source entry: {path}")
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
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
    validate_updates_manifest(signed_xpi, encoded_json(result))
    print(f"Firefox update manifest: {output_path}")


def _version_key(version: str) -> tuple[int, int, int, int]:
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError(f"Invalid Firefox updates manifest version: {version!r}")
    components = tuple(int(component) for component in version.split("."))
    return components + (0,) * (4 - len(components))


def _updates_manifest_version(path: Path) -> str:
    try:
        value = load_json(path)
        addon = next(iter(value["addons"].values()))
        version = addon["updates"][0]["version"]
    except (KeyError, IndexError, StopIteration, TypeError) as error:
        raise ReleaseError(f"Existing Firefox updates manifest is invalid: {path}") from error
    _version_key(version)
    return version


def _install_latest_updates_manifest(candidate: Path, destination: Path, version: str) -> None:
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_file():
            raise ReleaseError(f"Firefox updates manifest path is not a regular file: {destination}")
        existing_version = _updates_manifest_version(destination)
        if _version_key(version) < _version_key(existing_version):
            raise ReleaseError(
                f"Firefox updates manifest version downgrade rejected: {version} < {existing_version}"
            )
        if _version_key(version) == _version_key(existing_version):
            if version != existing_version:
                raise ReleaseError(
                    f"Firefox updates manifest version alias rejected: {version} vs {existing_version}"
                )
            install_immutable_artifact(candidate, destination)
            return
        temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
        temporary.unlink(missing_ok=True)
        shutil.copyfile(candidate, temporary)
        os.replace(temporary, destination)
        return
    install_immutable_artifact(candidate, destination)


def install_signed_release(signed_candidate: Path, output_dir: Path) -> tuple[Path, Path]:
    manifest, _, _ = inspect_signed_xpi(signed_candidate)
    version = manifest["version"]
    output_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.is_symlink():
        raise ReleaseError("Firefox release output directory must not be a symbolic link")
    signed_xpi = output_dir / f"knowledge-capture-firefox-{version}.xpi"
    updates_path = output_dir / "updates.json"
    assert_artifact_matches_record(
        ROOT,
        version,
        "firefox-signed-xpi",
        signed_candidate,
    )
    install_immutable_artifact(signed_candidate, signed_xpi)
    with tempfile.TemporaryDirectory(prefix="firefox-updates-candidate-", dir=output_dir) as directory:
        candidate_updates = Path(directory) / "updates.json"
        build_updates_manifest(signed_xpi, candidate_updates)
        assert_artifact_matches_record(
            ROOT,
            version,
            "firefox-updates-json",
            candidate_updates,
        )
        _install_latest_updates_manifest(candidate_updates, updates_path, version)
    validate_updates_manifest(signed_xpi, updates_path.read_bytes())
    record_artifacts(
        ROOT,
        version,
        [
            ("firefox-signed-xpi", signed_xpi),
            ("firefox-updates-json", updates_path),
        ],
    )
    return signed_xpi, updates_path


def validate_updates_manifest(signed_xpi: Path, data: bytes) -> tuple[dict, str, str]:
    manifest, digest, _ = inspect_signed_xpi(signed_xpi)
    config = load_json(CONFIG_PATH)
    addon_id = config["addonID"]
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Firefox updates manifest is invalid JSON: {error}") from error
    if not isinstance(value, dict) or set(value) != {"addons"}:
        raise ReleaseError("Firefox updates manifest must contain only the addons object")
    addons = value.get("addons")
    if not isinstance(addons, dict) or set(addons) != {addon_id}:
        raise ReleaseError("Firefox updates manifest add-on ID does not match the release config")
    addon = addons[addon_id]
    if not isinstance(addon, dict) or set(addon) != {"updates"}:
        raise ReleaseError("Firefox updates manifest add-on entry must contain only updates")
    updates = addon.get("updates") if isinstance(addon, dict) else None
    if not isinstance(updates, list) or len(updates) != 1 or not isinstance(updates[0], dict):
        raise ReleaseError("Firefox updates manifest must contain exactly one current update")
    update = updates[0]
    if set(update) != {"applications", "update_hash", "update_link", "version"}:
        raise ReleaseError("Firefox update entry contains unexpected or missing fields")
    applications = update["applications"]
    if not isinstance(applications, dict) or set(applications) != {"gecko"}:
        raise ReleaseError("Firefox update applications entry must contain only gecko")
    gecko_update = applications["gecko"]
    if not isinstance(gecko_update, dict) or set(gecko_update) != {"strict_min_version"}:
        raise ReleaseError("Firefox update gecko entry must contain only strict_min_version")
    expected_link = (
        f"{require_https_url(config['xpiBaseURL'], 'xpiBaseURL')}/"
        f"{urllib.parse.quote(signed_xpi.name)}"
    )
    require_https_url(update.get("update_link"), "update_link")
    expected_minimum = manifest["browser_specific_settings"]["gecko"]["strict_min_version"]
    actual_minimum = gecko_update["strict_min_version"]
    if update.get("version") != manifest.get("version"):
        raise ReleaseError("Firefox updates manifest version does not match the signed XPI")
    if update.get("update_hash") != f"sha256:{digest}":
        raise ReleaseError("Firefox updates manifest SHA-256 does not match the signed XPI")
    if update.get("update_link") != expected_link:
        raise ReleaseError("Firefox updates manifest download URL does not match xpiBaseURL")
    if actual_minimum != expected_minimum:
        raise ReleaseError("Firefox updates manifest minimum version does not match the signed XPI")
    return value, digest, expected_link


def validate_public_https_url(value: str, label: str, expected_host: str | None = None) -> str:
    url = require_https_url(value, label)
    parsed = urllib.parse.urlparse(url)
    try:
        port = parsed.port
    except ValueError as error:
        raise ReleaseError(f"{label} contains an invalid port") from error
    if parsed.fragment or port not in (None, 443):
        raise ReleaseError(f"{label} must not contain a fragment or non-default HTTPS port")
    host = parsed.hostname
    if not host:
        raise ReleaseError(f"{label} must contain a host")
    if expected_host is not None and host.lower() != expected_host.lower():
        raise ReleaseError(f"{label} redirected to an unexpected host: {host}")
    try:
        addresses = {
            item[4][0]
            for item in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
        }
    except OSError as error:
        raise ReleaseError(f"Could not resolve {label} host {host}: {error}") from error
    if not addresses:
        raise ReleaseError(f"Could not resolve {label} host {host}")
    for address in addresses:
        try:
            parsed_address = ipaddress.ip_address(address)
        except ValueError as error:
            raise ReleaseError(f"{label} resolved to an invalid address: {address}") from error
        if not parsed_address.is_global:
            raise ReleaseError(f"{label} resolved to a non-public address: {address}")
    return url


class SameHostHTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, expected_host: str) -> None:
        super().__init__()
        self.expected_host = expected_host

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        validate_public_https_url(new_url, "redirect URL", self.expected_host)
        return super().redirect_request(request, file_pointer, code, message, headers, new_url)


def download_release_resource(
    url: str,
    label: str,
    allowed_content_types: frozenset[str],
    maximum_bytes: int,
) -> tuple[bytes, str]:
    validated_url = validate_public_https_url(url, label)
    expected_host = urllib.parse.urlparse(validated_url).hostname
    assert expected_host is not None
    opener = urllib.request.build_opener(SameHostHTTPSRedirectHandler(expected_host))
    request = urllib.request.Request(
        validated_url,
        headers={
            "Accept": ", ".join(sorted(allowed_content_types)),
            "Accept-Encoding": "identity",
            "User-Agent": "PersonalSitePublisher-FirefoxReleaseVerifier/1",
        },
    )
    try:
        with opener.open(request, timeout=20) as response:
            final_url = validate_public_https_url(response.geturl(), f"final {label}", expected_host)
            status = getattr(response, "status", None)
            if status != 200:
                raise ReleaseError(f"{label} returned HTTP {status}")
            content_type = response.headers.get_content_type().lower()
            if content_type not in allowed_content_types:
                raise ReleaseError(f"{label} returned unexpected Content-Type {content_type}")
            content_length = response.headers.get("Content-Length")
            if content_length is not None:
                try:
                    declared_length = int(content_length)
                except ValueError as error:
                    raise ReleaseError(f"{label} returned an invalid Content-Length") from error
                if declared_length < 0 or declared_length > maximum_bytes:
                    raise ReleaseError(f"{label} exceeds the {maximum_bytes}-byte limit")
            data = response.read(maximum_bytes + 1)
    except urllib.error.HTTPError as error:
        raise ReleaseError(f"{label} returned HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise ReleaseError(f"Could not download {label}: {error.reason}") from error
    except TimeoutError as error:
        raise ReleaseError(f"Timed out downloading {label}") from error
    if len(data) > maximum_bytes:
        raise ReleaseError(f"{label} exceeds the {maximum_bytes}-byte limit")
    return data, final_url


def verify_remote_release(signed_xpi: Path, updates_path: Path) -> None:
    if not updates_path.is_file():
        raise ReleaseError(f"Local Firefox updates manifest is missing: {updates_path}")
    local_updates_data = updates_path.read_bytes()
    local_updates, expected_digest, expected_xpi_url = validate_updates_manifest(
        signed_xpi, local_updates_data
    )
    config = load_json(CONFIG_PATH)
    remote_updates_data, remote_updates_url = download_release_resource(
        config["updateManifestURL"],
        "remote Firefox updates manifest",
        UPDATE_CONTENT_TYPES,
        MAXIMUM_REMOTE_UPDATE_BYTES,
    )
    remote_updates, remote_digest, remote_xpi_url = validate_updates_manifest(
        signed_xpi, remote_updates_data
    )
    if remote_updates != local_updates:
        raise ReleaseError("Remote Firefox updates manifest does not match the local release artifact")
    if remote_digest != expected_digest or remote_xpi_url != expected_xpi_url:
        raise ReleaseError("Remote Firefox updates manifest resolved to an unexpected XPI")
    remote_xpi_data, final_xpi_url = download_release_resource(
        expected_xpi_url,
        "remote signed Firefox XPI",
        XPI_CONTENT_TYPES,
        MAXIMUM_REMOTE_XPI_BYTES,
    )
    if hashlib.sha256(remote_xpi_data).hexdigest() != expected_digest:
        raise ReleaseError("Remote signed Firefox XPI SHA-256 does not match updates.json")
    if remote_xpi_data != signed_xpi.read_bytes():
        raise ReleaseError("Remote signed Firefox XPI does not match the local signed artifact")
    with tempfile.TemporaryDirectory(prefix="firefox-remote-release-") as directory:
        downloaded_xpi = Path(directory) / signed_xpi.name
        downloaded_xpi.write_bytes(remote_xpi_data)
        inspect_signed_xpi(downloaded_xpi)
    print(f"Remote Firefox updates manifest verified: {remote_updates_url}")
    print(f"Remote signed Firefox XPI verified: {final_xpi_url}")


def fetch_verified_remote_release(
    output_dir: Path,
    record_in_ledger: bool = False,
) -> tuple[Path, Path]:
    _, firefox_manifest, config = validated_release()
    version = firefox_manifest["version"]
    addon_id = config["addonID"]
    xpi_name = f"knowledge-capture-firefox-{version}.xpi"
    expected_xpi_url = (
        f"{require_https_url(config['xpiBaseURL'], 'xpiBaseURL')}/"
        f"{urllib.parse.quote(xpi_name)}"
    )
    remote_updates_data, remote_updates_url = download_release_resource(
        config["updateManifestURL"],
        "remote Firefox updates manifest",
        UPDATE_CONTENT_TYPES,
        MAXIMUM_REMOTE_UPDATE_BYTES,
    )
    try:
        remote_value = json.loads(remote_updates_data)
        update = remote_value["addons"][addon_id]["updates"][0]
        remote_hash = update["update_hash"]
        remote_link = update["update_link"]
        remote_version = update["version"]
        remote_minimum = update["applications"]["gecko"]["strict_min_version"]
    except (KeyError, IndexError, TypeError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Remote Firefox updates manifest has an invalid structure: {error}") from error
    expected_minimum = firefox_manifest["browser_specific_settings"]["gecko"][
        "strict_min_version"
    ]
    if remote_version != version or remote_minimum != expected_minimum:
        raise ReleaseError("Remote Firefox updates manifest does not match the repository version")
    if remote_link != expected_xpi_url:
        raise ReleaseError("Remote Firefox updates manifest resolved to an unexpected XPI URL")
    if not isinstance(remote_hash, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", remote_hash):
        raise ReleaseError("Remote Firefox updates manifest contains an invalid SHA-256")

    remote_xpi_data, final_xpi_url = download_release_resource(
        expected_xpi_url,
        "remote signed Firefox XPI",
        XPI_CONTENT_TYPES,
        MAXIMUM_REMOTE_XPI_BYTES,
    )
    expected_digest = remote_hash.removeprefix("sha256:")
    if hashlib.sha256(remote_xpi_data).hexdigest() != expected_digest:
        raise ReleaseError("Remote signed Firefox XPI SHA-256 does not match updates.json")

    output_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.is_symlink():
        raise ReleaseError("Firefox release output directory must not be a symbolic link")
    with tempfile.TemporaryDirectory(prefix="firefox-fetch-verified-", dir=output_dir) as directory:
        temporary_xpi = Path(directory) / xpi_name
        temporary_xpi.write_bytes(remote_xpi_data)
        _, actual_digest, _ = inspect_signed_xpi(temporary_xpi)
        if actual_digest != expected_digest:
            raise ReleaseError("Verified Firefox XPI digest changed during download")
        validate_updates_manifest(temporary_xpi, remote_updates_data)
        assert_artifact_matches_record(
            ROOT,
            version,
            "firefox-signed-xpi",
            temporary_xpi,
        )

        signed_xpi = output_dir / xpi_name
        updates_path = output_dir / "updates.json"
        temporary_updates = Path(directory) / "updates.json"
        temporary_updates.write_bytes(remote_updates_data)
        assert_artifact_matches_record(
            ROOT,
            version,
            "firefox-updates-json",
            temporary_updates,
        )
        install_immutable_artifact(temporary_xpi, signed_xpi)
        _install_latest_updates_manifest(temporary_updates, updates_path, version)

    if record_in_ledger:
        record_artifacts(
            ROOT,
            version,
            [
                ("firefox-signed-xpi", signed_xpi),
                ("firefox-updates-json", updates_path),
            ],
        )

    print(f"Fetched verified Firefox updates manifest: {remote_updates_url}")
    print(f"Fetched verified signed Firefox XPI: {final_xpi_url}")
    print(f"Local signed Firefox XPI: {signed_xpi}")
    return signed_xpi, updates_path


def command_package(args: argparse.Namespace) -> None:
    output_dir = Path(args.output_dir).resolve()
    version, source_dir, unsigned_xpi = prepare_source(
        output_dir,
        record_in_ledger=not args.no_record_ledger,
    )
    print(f"Firefox release source: {source_dir}")
    print(f"Unsigned Firefox candidate {version}: {unsigned_xpi}")
    print("This candidate is for validation only and cannot be permanently installed in release Firefox.")


def command_package_amo(args: argparse.Namespace) -> None:
    output_dir = Path(args.output_dir).resolve()
    version, amo_xpi = prepare_amo_package(
        output_dir,
        record_in_ledger=not args.no_record_ledger,
    )
    print(f"Firefox AMO upload candidate {version}: {amo_xpi}")
    print("The package omits self-hosted update_url and must be signed by Mozilla during submission.")


def command_verify_signed(args: argparse.Namespace) -> None:
    path = Path(args.signed_xpi).resolve()
    manifest, digest, _ = inspect_signed_xpi(path)
    print(f"Firefox signed XPI payload and signature envelope verified: {path}")
    print("Firefox performs the final Mozilla certificate trust check during installation.")
    print(f"Version: {manifest['version']}")
    print(f"SHA-256: {digest}")


def command_install_signed(args: argparse.Namespace) -> None:
    signed_xpi, updates_path = install_signed_release(
        Path(args.signed_xpi).resolve(),
        Path(args.output_dir).resolve(),
    )
    print(f"Immutable signed Firefox XPI recorded: {signed_xpi}")
    print(f"Immutable Firefox updates manifest recorded: {updates_path}")


def command_updates(args: argparse.Namespace) -> None:
    signed_xpi = Path(args.signed_xpi).resolve()
    output = Path(args.output).resolve()
    manifest, _, _ = inspect_signed_xpi(signed_xpi)
    version = manifest["version"]
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.parent.is_symlink():
        raise ReleaseError("Firefox updates output directory must not be a symbolic link")
    with tempfile.TemporaryDirectory(prefix="firefox-updates-candidate-", dir=output.parent) as directory:
        candidate = Path(directory) / "updates.json"
        build_updates_manifest(signed_xpi, candidate)
        assert_artifact_matches_record(
            ROOT,
            version,
            "firefox-updates-json",
            candidate,
        )
        _install_latest_updates_manifest(candidate, output, version)
    print(f"Firefox update manifest installed: {output}")


def command_verify_updates(args: argparse.Namespace) -> None:
    signed_xpi = Path(args.signed_xpi).resolve()
    updates_path = Path(args.updates).resolve()
    if not updates_path.is_file():
        raise ReleaseError(f"Firefox updates manifest is missing: {updates_path}")
    validate_updates_manifest(signed_xpi, updates_path.read_bytes())
    print(f"Firefox updates manifest verified: {updates_path}")


def command_verify_remote(args: argparse.Namespace) -> None:
    _, firefox_manifest, _ = validated_release()
    version = firefox_manifest["version"]
    default_directory = ROOT / "dist" / "browser-extension"
    signed_xpi = Path(
        args.signed_xpi or default_directory / f"knowledge-capture-firefox-{version}.xpi"
    ).resolve()
    updates_path = Path(args.updates or default_directory / "updates.json").resolve()
    verify_remote_release(signed_xpi, updates_path)


def command_fetch_verified(args: argparse.Namespace) -> None:
    fetch_verified_remote_release(Path(args.output_dir).resolve(), record_in_ledger=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    package = subparsers.add_parser("package", help="prepare release source and an unsigned validation XPI")
    package.add_argument("--output-dir", default=str(ROOT / "dist" / "browser-extension"))
    package.add_argument("--no-record-ledger", action="store_true", help=argparse.SUPPRESS)
    package.set_defaults(function=command_package)

    package_amo = subparsers.add_parser(
        "package-amo", help="prepare an immutable public AMO upload XPI"
    )
    package_amo.add_argument("--output-dir", default=str(ROOT / "dist" / "browser-extension"))
    package_amo.add_argument("--no-record-ledger", action="store_true", help=argparse.SUPPRESS)
    package_amo.set_defaults(function=command_package_amo)

    verify = subparsers.add_parser("verify-signed", help="verify a Mozilla-signed XPI")
    verify.add_argument("--signed-xpi", required=True)
    verify.set_defaults(function=command_verify_signed)

    install_signed = subparsers.add_parser(
        "install-signed",
        help="immutably install and record a verified Mozilla-signed XPI",
    )
    install_signed.add_argument("--signed-xpi", required=True)
    install_signed.add_argument(
        "--output-dir",
        default=str(ROOT / "dist" / "browser-extension"),
    )
    install_signed.set_defaults(function=command_install_signed)

    updates = subparsers.add_parser("updates", help="generate updates.json from a verified signed XPI")
    updates.add_argument("--signed-xpi", required=True)
    updates.add_argument("--output", required=True)
    updates.set_defaults(function=command_updates)

    verify_updates = subparsers.add_parser(
        "verify-updates", help="verify a local updates.json against a signed XPI"
    )
    verify_updates.add_argument("--signed-xpi", required=True)
    verify_updates.add_argument("--updates", required=True)
    verify_updates.set_defaults(function=command_verify_updates)

    verify_remote = subparsers.add_parser(
        "verify-remote", help="verify the published updates.json and signed XPI"
    )
    verify_remote.add_argument("--signed-xpi")
    verify_remote.add_argument("--updates")
    verify_remote.set_defaults(function=command_verify_remote)

    fetch_verified = subparsers.add_parser(
        "fetch-verified",
        help="download remote signed release artifacts after full validation",
    )
    fetch_verified.add_argument(
        "--output-dir",
        default=str(ROOT / "dist" / "browser-extension"),
    )
    fetch_verified.set_defaults(function=command_fetch_verified)

    return parser.parse_args()


def main() -> int:
    try:
        args = parse_arguments()
        args.function(args)
    except (ReleaseError, ReleaseLedgerError) as error:
        print(f"Firefox release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
