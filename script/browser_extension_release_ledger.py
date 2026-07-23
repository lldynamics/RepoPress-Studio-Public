#!/usr/bin/env python3
"""Maintain the append-only browser-extension release ledger."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Sequence


DEFAULT_ROOT = Path(__file__).resolve().parent.parent
LEDGER_RELATIVE_PATH = Path("BrowserExtension/release-ledger.json")
SCHEMA_VERSION = 1
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){2,3}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
TIMESTAMP_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
ARTIFACT_KINDS = frozenset(
    (
        "chrome-zip",
        "edge-zip",
        "firefox-amo-xpi",
        "firefox-unsigned-xpi",
        "firefox-signed-xpi",
        "firefox-updates-json",
    )
)
PUBLICATION_CHANNELS = frozenset(("chrome", "edge", "firefox", "firefox-amo"))
PUBLICATION_ARTIFACTS = {
    "chrome": frozenset(("chrome-zip",)),
    "edge": frozenset(("edge-zip",)),
    "firefox": frozenset(("firefox-signed-xpi", "firefox-updates-json")),
    "firefox-amo": frozenset(("firefox-amo-xpi",)),
}
SHARED_SOURCE_FILES = (
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
    "popup.css",
    "popup.html",
    "popup.js",
    "protocol.generated.js",
)
RELEASE_SOURCE_FILES = (
    "BrowserExtension/_locales/en/messages.json",
    "BrowserExtension/_locales/zh_CN/messages.json",
    "BrowserExtension/background-capture.js",
    "BrowserExtension/background-queue-operations.js",
    "BrowserExtension/background-queue-storage.js",
    "BrowserExtension/background-security.js",
    "BrowserExtension/background.js",
    "BrowserExtension/firefox-release.json",
    "BrowserExtension/Firefox/manifest.json",
    "BrowserExtension/icons/icon16.png",
    "BrowserExtension/icons/icon32.png",
    "BrowserExtension/icons/icon48.png",
    "BrowserExtension/icons/icon128.png",
    "BrowserExtension/manifest.json",
    "BrowserExtension/popup.css",
    "BrowserExtension/popup.html",
    "BrowserExtension/popup.js",
    "BrowserExtension/protocol.generated.js",
)


class ReleaseLedgerError(RuntimeError):
    pass


def _object_without_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    value = {}
    for key, item in pairs:
        if key in value:
            raise ReleaseLedgerError(f"Duplicate JSON field in release ledger: {key}")
        value[key] = item
    return value


def _load_json(path: Path) -> dict:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_object_without_duplicate_keys,
        )
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseLedgerError(f"Cannot read valid JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseLedgerError(f"Expected a JSON object in {path}")
    return value


def _require_exact_keys(value: dict, expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise ReleaseLedgerError(
            f"{label} fields do not match the ledger schema; "
            f"missing={sorted(expected - set(value))}, extra={sorted(set(value) - expected)}"
        )


def _parse_timestamp(value: object, label: str) -> datetime:
    if not isinstance(value, str) or not TIMESTAMP_PATTERN.fullmatch(value):
        raise ReleaseLedgerError(f"{label} must be an RFC 3339 UTC timestamp without fractions")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise ReleaseLedgerError(f"{label} is not a valid UTC timestamp") from error


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def _version_key(version: str) -> tuple[int, int, int, int]:
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ReleaseLedgerError(f"Invalid browser extension version: {version!r}")
    components = tuple(int(component) for component in version.split("."))
    return components + (0,) * (4 - len(components))


def _artifact_filename(kind: str, version: str) -> str:
    names = {
        "chrome-zip": f"knowledge-capture-chrome-{version}.zip",
        "edge-zip": f"knowledge-capture-edge-{version}.zip",
        "firefox-amo-xpi": f"knowledge-capture-firefox-{version}-amo.xpi",
        "firefox-unsigned-xpi": f"knowledge-capture-firefox-{version}-unsigned.xpi",
        "firefox-signed-xpi": f"knowledge-capture-firefox-{version}.xpi",
        "firefox-updates-json": "updates.json",
    }
    try:
        return names[kind]
    except KeyError as error:
        raise ReleaseLedgerError(f"Unknown browser extension artifact kind: {kind}") from error


def _sha256_file(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise ReleaseLedgerError(f"Release artifact must be a regular file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1_048_576), b""):
            digest.update(chunk)
    return digest.hexdigest()


def current_version(root: Path) -> str:
    chromium_manifest = _load_json(root / "BrowserExtension/manifest.json")
    firefox_manifest = _load_json(root / "BrowserExtension/Firefox/manifest.json")
    chromium_version = chromium_manifest.get("version")
    firefox_version = firefox_manifest.get("version")
    _version_key(chromium_version)
    _version_key(firefox_version)
    if chromium_version != firefox_version:
        raise ReleaseLedgerError("Chromium and Firefox extension versions must match")
    return chromium_version


def release_source_sha256(root: Path) -> str:
    root = root.resolve()
    current_version(root)
    extension_root = root / "BrowserExtension"
    firefox_root = extension_root / "Firefox"
    for name in SHARED_SOURCE_FILES:
        shared_path = extension_root / name
        firefox_path = firefox_root / name
        if not shared_path.is_file() or shared_path.is_symlink():
            raise ReleaseLedgerError(f"Release source must be a regular file: {shared_path}")
        if not firefox_path.is_file() or firefox_path.is_symlink():
            raise ReleaseLedgerError(f"Release source must be a regular file: {firefox_path}")
        if shared_path.read_bytes() != firefox_path.read_bytes():
            raise ReleaseLedgerError(f"Shared Firefox extension source is out of sync: {name}")

    digest = hashlib.sha256()
    digest.update(b"browser-extension-release-source-v1\0")
    for relative_name in RELEASE_SOURCE_FILES:
        path = root / relative_name
        if not path.is_file() or path.is_symlink():
            raise ReleaseLedgerError(f"Release source must be a regular file: {path}")
        encoded_name = relative_name.encode("utf-8")
        contents = path.read_bytes()
        digest.update(len(encoded_name).to_bytes(4, "big"))
        digest.update(encoded_name)
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def empty_ledger() -> dict:
    return {"schemaVersion": SCHEMA_VERSION, "releases": []}


def _validate_ledger(value: dict) -> dict:
    _require_exact_keys(value, {"schemaVersion", "releases"}, "release ledger")
    if value["schemaVersion"] != SCHEMA_VERSION:
        raise ReleaseLedgerError("Unsupported browser extension release ledger schemaVersion")
    releases = value["releases"]
    if not isinstance(releases, list):
        raise ReleaseLedgerError("Release ledger releases must be an array")

    previous_version_key = None
    seen_versions: set[str] = set()
    for release_index, release in enumerate(releases):
        label = f"release ledger entry {release_index}"
        if not isinstance(release, dict):
            raise ReleaseLedgerError(f"{label} must be an object")
        _require_exact_keys(
            release,
            {"version", "sourceSHA256", "createdAt", "artifacts", "publications"},
            label,
        )
        version = release["version"]
        version_key = _version_key(version)
        if version in seen_versions or (
            previous_version_key is not None and version_key <= previous_version_key
        ):
            raise ReleaseLedgerError("Release ledger versions must be unique and strictly increasing")
        seen_versions.add(version)
        previous_version_key = version_key
        if not isinstance(release["sourceSHA256"], str) or not SHA256_PATTERN.fullmatch(
            release["sourceSHA256"]
        ):
            raise ReleaseLedgerError(f"{label} sourceSHA256 is invalid")
        created_at = _parse_timestamp(release["createdAt"], f"{label} createdAt")

        artifacts = release["artifacts"]
        if not isinstance(artifacts, list):
            raise ReleaseLedgerError(f"{label} artifacts must be an array")
        seen_artifact_kinds: set[str] = set()
        artifact_recorded_at: dict[str, datetime] = {}
        for artifact_index, artifact in enumerate(artifacts):
            artifact_label = f"{label} artifact {artifact_index}"
            if not isinstance(artifact, dict):
                raise ReleaseLedgerError(f"{artifact_label} must be an object")
            _require_exact_keys(
                artifact,
                {"kind", "file", "sha256", "recordedAt"},
                artifact_label,
            )
            kind = artifact["kind"]
            if kind not in ARTIFACT_KINDS or kind in seen_artifact_kinds:
                raise ReleaseLedgerError(f"{artifact_label} kind is unknown or duplicated")
            seen_artifact_kinds.add(kind)
            if artifact["file"] != _artifact_filename(kind, version):
                raise ReleaseLedgerError(f"{artifact_label} file does not match its version and kind")
            if not isinstance(artifact["sha256"], str) or not SHA256_PATTERN.fullmatch(
                artifact["sha256"]
            ):
                raise ReleaseLedgerError(f"{artifact_label} sha256 is invalid")
            recorded_at = _parse_timestamp(artifact["recordedAt"], f"{artifact_label} recordedAt")
            if recorded_at < created_at:
                raise ReleaseLedgerError(f"{artifact_label} predates its release entry")
            artifact_recorded_at[kind] = recorded_at

        publications = release["publications"]
        if not isinstance(publications, list):
            raise ReleaseLedgerError(f"{label} publications must be an array")
        seen_channels: set[str] = set()
        for publication_index, publication in enumerate(publications):
            publication_label = f"{label} publication {publication_index}"
            if not isinstance(publication, dict):
                raise ReleaseLedgerError(f"{publication_label} must be an object")
            _require_exact_keys(publication, {"channel", "publishedAt"}, publication_label)
            channel = publication["channel"]
            if channel not in PUBLICATION_CHANNELS or channel in seen_channels:
                raise ReleaseLedgerError(f"{publication_label} channel is unknown or duplicated")
            seen_channels.add(channel)
            published_at = _parse_timestamp(
                publication["publishedAt"], f"{publication_label} publishedAt"
            )
            if published_at < created_at:
                raise ReleaseLedgerError(f"{publication_label} predates its release entry")
            missing_artifacts = PUBLICATION_ARTIFACTS[channel] - seen_artifact_kinds
            if missing_artifacts:
                raise ReleaseLedgerError(
                    f"{publication_label} is missing immutable artifacts: {sorted(missing_artifacts)}"
                )
            latest_required_artifact = max(
                artifact_recorded_at[kind] for kind in PUBLICATION_ARTIFACTS[channel]
            )
            if published_at < latest_required_artifact:
                raise ReleaseLedgerError(
                    f"{publication_label} predates a required immutable artifact"
                )
    return value


def load_ledger(root: Path, require_exists: bool = False) -> dict:
    path = root.resolve() / LEDGER_RELATIVE_PATH
    if not path.exists():
        if require_exists:
            raise ReleaseLedgerError(f"Browser extension release ledger is missing: {path}")
        return empty_ledger()
    if path.is_symlink() or not path.is_file():
        raise ReleaseLedgerError(f"Browser extension release ledger must be a regular file: {path}")
    return _validate_ledger(_load_json(path))


def _release_for_version(ledger: dict, version: str) -> dict | None:
    return next((release for release in ledger["releases"] if release["version"] == version), None)


def assert_source_version_allowed(root: Path, require_recorded: bool = False) -> tuple[str, str]:
    root = root.resolve()
    version = current_version(root)
    source_sha256 = release_source_sha256(root)
    ledger = load_ledger(root, require_exists=require_recorded)
    releases = ledger["releases"]
    matching = _release_for_version(ledger, version)
    if releases:
        latest = releases[-1]
        if _version_key(version) < _version_key(latest["version"]):
            raise ReleaseLedgerError(
                f"Browser extension version downgrade rejected: {version} < {latest['version']}"
            )
        if _version_key(version) == _version_key(latest["version"]) and version != latest["version"]:
            raise ReleaseLedgerError(
                f"Browser extension version alias rejected: {version} conflicts with {latest['version']}"
            )
    if matching is not None and matching["sourceSHA256"] != source_sha256:
        raise ReleaseLedgerError(
            f"Same-version different-source release rejected for {version}: "
            f"ledger={matching['sourceSHA256']}, current={source_sha256}"
        )
    if require_recorded and matching is None:
        raise ReleaseLedgerError(
            f"Browser extension release {version} has not been recorded in the immutable ledger"
        )
    return version, source_sha256


@contextmanager
def _ledger_lock(root: Path) -> Iterator[None]:
    lock_id = hashlib.sha256(str(root.resolve()).encode("utf-8")).hexdigest()[:24]
    lock_path = Path(tempfile.gettempdir()) / f"browser-extension-release-ledger-{lock_id}.lock"
    with lock_path.open("a+b") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _write_ledger(root: Path, ledger: dict) -> None:
    path = root.resolve() / LEDGER_RELATIVE_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(ledger, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=".release-ledger-", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def record_artifacts(
    root: Path,
    version: str,
    artifacts: Sequence[tuple[str, Path]],
    recorded_at: str | None = None,
) -> dict:
    root = root.resolve()
    current, source_sha256 = assert_source_version_allowed(root)
    if version != current:
        raise ReleaseLedgerError(
            f"Artifact version {version} does not match repository version {current}"
        )
    timestamp = recorded_at or _utc_now()
    _parse_timestamp(timestamp, "artifact recordedAt")
    prepared: list[dict] = []
    seen_kinds: set[str] = set()
    for kind, path in artifacts:
        if kind not in ARTIFACT_KINDS or kind in seen_kinds:
            raise ReleaseLedgerError(f"Unknown or duplicated artifact kind: {kind}")
        seen_kinds.add(kind)
        expected_name = _artifact_filename(kind, version)
        if path.name != expected_name:
            raise ReleaseLedgerError(
                f"Artifact file name for {kind} must be {expected_name}, found {path.name}"
            )
        prepared.append(
            {
                "kind": kind,
                "file": path.name,
                "sha256": _sha256_file(path),
                "recordedAt": timestamp,
            }
        )

    with _ledger_lock(root):
        ledger = load_ledger(root)
        releases = ledger["releases"]
        matching = _release_for_version(ledger, version)
        if releases and _version_key(version) < _version_key(releases[-1]["version"]):
            raise ReleaseLedgerError(
                f"Browser extension version downgrade rejected: {version} < {releases[-1]['version']}"
            )
        if matching is None:
            matching = {
                "version": version,
                "sourceSHA256": source_sha256,
                "createdAt": timestamp,
                "artifacts": [],
                "publications": [],
            }
            releases.append(matching)
        elif matching["sourceSHA256"] != source_sha256:
            raise ReleaseLedgerError(
                f"Same-version different-source release rejected for {version}"
            )

        changed = False
        existing_by_kind = {artifact["kind"]: artifact for artifact in matching["artifacts"]}
        for artifact in prepared:
            existing = existing_by_kind.get(artifact["kind"])
            if existing is None:
                matching["artifacts"].append(artifact)
                existing_by_kind[artifact["kind"]] = artifact
                changed = True
            elif existing["file"] != artifact["file"] or existing["sha256"] != artifact["sha256"]:
                raise ReleaseLedgerError(
                    f"Immutable artifact replacement rejected for {version} {artifact['kind']}"
                )
        _validate_ledger(ledger)
        if changed:
            _write_ledger(root, ledger)
        return matching


def assert_artifact_matches_record(
    root: Path,
    version: str,
    kind: str,
    path: Path,
) -> bool:
    if kind not in ARTIFACT_KINDS:
        raise ReleaseLedgerError(f"Unknown browser extension artifact kind: {kind}")
    ledger = load_ledger(root.resolve())
    release = _release_for_version(ledger, version)
    if release is None:
        return False
    artifact = next(
        (item for item in release["artifacts"] if item["kind"] == kind),
        None,
    )
    if artifact is None:
        return False
    if _sha256_file(path) != artifact["sha256"]:
        raise ReleaseLedgerError(
            f"Release artifact does not match immutable ledger for {version} {kind}: {path}"
        )
    return True


def record_publication(root: Path, version: str, channel: str, published_at: str) -> dict:
    root = root.resolve()
    if channel not in PUBLICATION_CHANNELS:
        raise ReleaseLedgerError(f"Unknown publication channel: {channel}")
    _parse_timestamp(published_at, "publishedAt")
    with _ledger_lock(root):
        ledger = load_ledger(root, require_exists=True)
        release = _release_for_version(ledger, version)
        if release is None:
            raise ReleaseLedgerError(f"Cannot publish unrecorded browser extension version {version}")
        artifact_kinds = {artifact["kind"] for artifact in release["artifacts"]}
        missing_artifacts = PUBLICATION_ARTIFACTS[channel] - artifact_kinds
        if missing_artifacts:
            raise ReleaseLedgerError(
                f"Cannot publish {channel}; immutable artifacts are missing: {sorted(missing_artifacts)}"
            )
        existing = next(
            (item for item in release["publications"] if item["channel"] == channel),
            None,
        )
        if existing is not None:
            if existing["publishedAt"] != published_at:
                raise ReleaseLedgerError(
                    f"Immutable publication timestamp replacement rejected for {version} {channel}"
                )
            return release
        release["publications"].append(
            {"channel": channel, "publishedAt": published_at}
        )
        _validate_ledger(ledger)
        _write_ledger(root, ledger)
        return release


def install_immutable_artifact(candidate: Path, destination: Path) -> bool:
    candidate_digest = _sha256_file(candidate)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.parent.is_symlink():
        raise ReleaseLedgerError(
            f"Release artifact directory must not be a symbolic link: {destination.parent}"
        )
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_file():
            raise ReleaseLedgerError(f"Release artifact path must be a regular file: {destination}")
        if _sha256_file(destination) != candidate_digest:
            raise ReleaseLedgerError(
                f"Refusing to replace same-version release artifact with different bytes: {destination}"
            )
        return False
    try:
        with candidate.open("rb") as source, destination.open("xb") as target:
            shutil.copyfileobj(source, target, length=1_048_576)
            target.flush()
            os.fsync(target.fileno())
    except FileExistsError:
        if _sha256_file(destination) != candidate_digest:
            raise ReleaseLedgerError(
                f"Concurrent process created a different release artifact: {destination}"
            )
        return False
    if _sha256_file(destination) != candidate_digest:
        destination.unlink(missing_ok=True)
        raise ReleaseLedgerError(f"Release artifact changed while being installed: {destination}")
    return True


def _command_check(args: argparse.Namespace) -> None:
    version, source_sha256 = assert_source_version_allowed(args.root, require_recorded=True)
    ledger = load_ledger(args.root, require_exists=True)
    release = _release_for_version(ledger, version)
    print(f"Browser extension release ledger {version}: verified")
    print(f"Source SHA-256: {source_sha256}")
    print(f"Recorded artifacts: {len(release['artifacts'])}")


def _command_publish(args: argparse.Namespace) -> None:
    record_publication(args.root, args.version, args.channel, args.published_at)
    print(
        f"Browser extension publication recorded: {args.version} "
        f"{args.channel} at {args.published_at}"
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help=argparse.SUPPRESS)
    subparsers = parser.add_subparsers(dest="command", required=True)
    check = subparsers.add_parser("check", help="verify current source against the immutable ledger")
    check.set_defaults(function=_command_check)
    publish = subparsers.add_parser(
        "publish", help="append an immutable store publication timestamp"
    )
    publish.add_argument("--version", required=True)
    publish.add_argument("--channel", choices=sorted(PUBLICATION_CHANNELS), required=True)
    publish.add_argument("--published-at", required=True)
    publish.set_defaults(function=_command_publish)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    args.root = args.root.resolve()
    try:
        args.function(args)
    except (OSError, ReleaseLedgerError) as error:
        print(f"Browser extension release ledger error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
