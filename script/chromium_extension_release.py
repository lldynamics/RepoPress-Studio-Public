#!/usr/bin/env python3
"""Build the deterministic Chrome Web Store submission ZIP."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
import urllib.parse
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


DEFAULT_ROOT = Path(__file__).resolve().parent.parent
EXTENSION_ROOT_NAME = Path("BrowserExtension")
SHARED_ROOT_NAME = Path("shared")
CHROME_ROOT_NAME = Path("Chrome")
SAFARI_EXTENSION_BUNDLE_ID = "com.jinfang.PersonalSitePublisherMac.SafariExtension"
CHANNELS = ("chrome",)
CHANNEL_LABELS = {
    "chrome": "Chrome Web Store",
    "edge": "Microsoft Edge Add-ons",
}
PRODUCTION_ID_FIELDS = {"chrome": "chromeProductionID"}
LISTING_URLS = {
    "chrome": "https://chromewebstore.google.com/detail/{extension_id}",
    "edge": "https://microsoftedge.microsoft.com/addons/detail/{extension_id}",
}
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
ICON_PATHS = {
    "16": "icons/icon16.png",
    "32": "icons/icon32.png",
    "48": "icons/icon48.png",
    "128": "icons/icon128.png",
}
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){2,3}$")
CHROMIUM_ID_PATTERN = re.compile(r"^[a-p]{32}$")
MAXIMUM_PACKAGE_BYTES = 50 * 1_024 * 1_024
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)


class ReleaseError(RuntimeError):
    pass


def source_path(root: Path, relative: str) -> Path:
    extension_root = root / EXTENSION_ROOT_NAME
    if relative == "manifest.json":
        return extension_root / CHROME_ROOT_NAME / relative
    return extension_root / SHARED_ROOT_NAME / relative


def object_without_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    value = {}
    for key, item in pairs:
        if key in value:
            raise ReleaseError(f"Duplicate JSON field: {key}")
        value[key] = item
    return value


def load_json(path: Path) -> dict:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=object_without_duplicate_keys,
        )
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Cannot read valid JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"Expected a JSON object in {path}")
    return value


def require_exact_keys(value: dict, expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise ReleaseError(
            f"{label} fields do not match the release contract; "
            f"missing={sorted(expected - set(value))}, extra={sorted(set(value) - expected)}"
        )


def require_https_url(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise ReleaseError(f"{label} must be a string")
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ReleaseError(f"{label} must be an HTTPS URL without embedded credentials")
    return value


def validated_metadata(extension_root: Path, manifest: dict) -> dict:
    metadata = load_json(extension_root / "chromium-store-listing.json")
    require_exact_keys(
        metadata,
        {
            "documentVersion",
            "defaultLocale",
            "privacyPolicyURL",
            "supportURL",
            "localizations",
            "permissionJustifications",
            "requiredHostPermissionJustifications",
            "optionalHostPermissionJustifications",
            "optionalPermissionJustifications",
        },
        "store listing",
    )
    if metadata["documentVersion"] != 1 or metadata["defaultLocale"] != "zh_CN":
        raise ReleaseError("Unsupported store listing documentVersion or defaultLocale")
    require_https_url(metadata["privacyPolicyURL"], "privacyPolicyURL")
    require_https_url(metadata["supportURL"], "supportURL")

    localizations = metadata["localizations"]
    if not isinstance(localizations, dict) or set(localizations) != {"zh_CN", "en"}:
        raise ReleaseError("Store listing must include exactly zh_CN and en localizations")
    for locale, localization in localizations.items():
        if not isinstance(localization, dict):
            raise ReleaseError(f"Store listing localization {locale} must be an object")
        require_exact_keys(
            localization,
            {"name", "shortDescription", "actionTitle", "singlePurpose", "description"},
            f"store listing localization {locale}",
        )
        for field, minimum, maximum in (
            ("name", 3, 75),
            ("shortDescription", 10, 132),
            ("actionTitle", 3, 75),
            ("singlePurpose", 20, 1_000),
            ("description", 80, 16_000),
        ):
            text = localization[field]
            if not isinstance(text, str) or not minimum <= len(text.strip()) <= maximum:
                raise ReleaseError(f"Store listing {locale}.{field} is outside its length limit")

    required_permissions = manifest.get("permissions")
    required_host_permissions = manifest.get("host_permissions", [])
    optional_host_permissions = manifest.get("optional_host_permissions")
    optional_permissions = manifest.get("optional_permissions", [])
    justifications = metadata["permissionJustifications"]
    required_host_justifications = metadata["requiredHostPermissionJustifications"]
    optional_host_justifications = metadata["optionalHostPermissionJustifications"]
    optional_justifications = metadata["optionalPermissionJustifications"]
    if not isinstance(required_permissions, list) or not all(
        isinstance(item, str) for item in required_permissions
    ):
        raise ReleaseError("Chromium manifest permissions must be a string array")
    if not isinstance(optional_host_permissions, list) or not all(
        isinstance(item, str) for item in optional_host_permissions
    ):
        raise ReleaseError("Chromium optional_host_permissions must be a string array")
    if not isinstance(required_host_permissions, list) or not all(
        isinstance(item, str) for item in required_host_permissions
    ):
        raise ReleaseError("Chromium host_permissions must be a string array")
    if not isinstance(optional_permissions, list) or not all(
        isinstance(item, str) for item in optional_permissions
    ):
        raise ReleaseError("Chromium optional_permissions must be a string array")
    if not isinstance(justifications, dict) or set(justifications) != set(required_permissions):
        raise ReleaseError("Store permission justifications must match manifest permissions exactly")
    if not isinstance(required_host_justifications, dict) or set(
        required_host_justifications
    ) != set(required_host_permissions):
        raise ReleaseError(
            "Store required-host justifications must match host_permissions exactly"
        )
    if not isinstance(optional_host_justifications, dict) or set(optional_host_justifications) != set(
        optional_host_permissions
    ):
        raise ReleaseError(
            "Store optional-host justifications must match optional_host_permissions exactly"
        )
    if any(not isinstance(value, str) or len(value.strip()) < 10 for value in justifications.values()):
        raise ReleaseError("Every required permission needs a meaningful justification")
    if any(
        not isinstance(value, str) or len(value.strip()) < 10
        for value in required_host_justifications.values()
    ):
        raise ReleaseError("Every required host permission needs a meaningful justification")
    if any(
        not isinstance(value, str) or len(value.strip()) < 10
        for value in optional_host_justifications.values()
    ):
        raise ReleaseError("Every optional host permission needs a meaningful justification")
    if not isinstance(optional_justifications, dict) or set(optional_justifications) != set(
        optional_permissions
    ):
        raise ReleaseError(
            "Store optional-permission justifications must match optional_permissions exactly"
        )
    if any(
        not isinstance(value, str) or len(value.strip()) < 10
        for value in optional_justifications.values()
    ):
        raise ReleaseError("Every optional permission needs a meaningful justification")
    return metadata


def validated_release(
    root: Path,
    required_production_channels: set[str] | None = None,
) -> tuple[dict, dict, str]:
    extension_root = root / "BrowserExtension"
    manifest = load_json(source_path(root, "manifest.json"))
    definition = load_json(extension_root / "browser-extension-protocol.json")
    if definition.get("activeExtensions") != ["safari", "chrome", "firefox"]:
        raise ReleaseError("This release must enable exactly Safari, Chrome, and Firefox")
    extensions = definition.get("extensions")
    if not isinstance(extensions, dict):
        raise ReleaseError("browser-extension-protocol.json extensions must be an object")
    expected_identity_fields = {
        "chromiumDevelopmentID",
        "firefoxID",
        "chromeProductionID",
        "edgeProductionID",
        "safariBundleID",
    }
    if set(extensions) != expected_identity_fields:
        raise ReleaseError("Browser extension identity fields do not match the store contract")
    if extensions["safariBundleID"] != SAFARI_EXTENSION_BUNDLE_ID:
        raise ReleaseError("Safari Web Extension bundle ID does not match the app extension contract")
    development_id = extensions["chromiumDevelopmentID"]
    if not isinstance(development_id, str) or not CHROMIUM_ID_PATTERN.fullmatch(development_id):
        raise ReleaseError("Chromium development extension ID is invalid")
    required_channels = required_production_channels or set()
    production_ids: list[str] = []
    for channel, field in PRODUCTION_ID_FIELDS.items():
        extension_id = extensions[field]
        if extension_id is not None and (
            not isinstance(extension_id, str) or not CHROMIUM_ID_PATTERN.fullmatch(extension_id)
        ):
            raise ReleaseError(f"{CHANNEL_LABELS[channel]} production extension ID is invalid")
        if channel in required_channels and extension_id is None:
            raise ReleaseError(
                f"{CHANNEL_LABELS[channel]} production ID is pending; upload the initial ZIP, "
                "then record the store-assigned ID in browser-extension-protocol.json"
            )
        if extension_id is not None:
            if extension_id == development_id:
                raise ReleaseError(f"{CHANNEL_LABELS[channel]} production ID still uses the development ID")
            production_ids.append(extension_id)
    if len(production_ids) != len(set(production_ids)):
        raise ReleaseError("Chrome Web Store production ID is duplicated")

    if manifest.get("manifest_version") != 3:
        raise ReleaseError("Chromium store package must use Manifest V3")
    if manifest.get("default_locale") != "zh_CN":
        raise ReleaseError("Chromium store package default_locale must be zh_CN")
    if manifest.get("name") != "__MSG_extensionName__":
        raise ReleaseError("Chromium manifest name must use the extensionName locale message")
    if manifest.get("description") != "__MSG_extensionDescription__":
        raise ReleaseError(
            "Chromium manifest description must use the extensionDescription locale message"
        )
    if manifest.get("action", {}).get("default_title") != "__MSG_actionTitle__":
        raise ReleaseError("Chromium action title must use the actionTitle locale message")
    version = manifest.get("version")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ReleaseError("Chromium extension version must be a three- or four-part numeric version")
    if "update_url" in manifest:
        raise ReleaseError("Store submission manifest must not contain a self-hosted update_url")
    if manifest.get("icons") != ICON_PATHS:
        raise ReleaseError("Chromium manifest must declare the complete store icon set")
    action_icons = manifest.get("action", {}).get("default_icon")
    if action_icons != {"16": ICON_PATHS["16"], "32": ICON_PATHS["32"]}:
        raise ReleaseError("Chromium action must declare 16px and 32px toolbar icons")
    for name in REQUIRED_SOURCE_FILES:
        path = source_path(root, name)
        if not path.is_file() or path.is_symlink():
            raise ReleaseError(f"Required regular Chromium source file is missing: {path}")
    metadata = validated_metadata(extension_root, manifest)
    locale_message_keys: dict[str, set[str]] = {}
    for locale in ("zh_CN", "en"):
        messages = load_json(source_path(root, f"_locales/{locale}/messages.json"))
        locale_message_keys[locale] = set(messages)
        expected_messages = {
            "extensionName": metadata["localizations"][locale]["name"],
            "extensionDescription": metadata["localizations"][locale]["shortDescription"],
            "actionTitle": metadata["localizations"][locale]["actionTitle"],
        }
        missing_messages = set(expected_messages).difference(messages)
        if missing_messages:
            raise ReleaseError(
                f"Chromium locale {locale} is missing messages: {sorted(missing_messages)}"
            )
        for key, value in messages.items():
            if set(value) != {"message"} or not isinstance(value["message"], str) \
                    or not value["message"]:
                raise ReleaseError(f"Chromium locale {locale}.{key} must contain one message")
        for key, expected in expected_messages.items():
            if messages[key] != {"message": expected}:
                raise ReleaseError(
                    f"Chromium locale {locale}.{key} does not match the store listing source"
                )
    if locale_message_keys["zh_CN"] != locale_message_keys["en"]:
        raise ReleaseError("Chromium zh_CN and en locale message keys must match")
    return manifest, extensions, version


def encoded_json(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def release_manifest(development_manifest: dict) -> dict:
    manifest = json.loads(json.dumps(development_manifest))
    manifest.pop("key", None)
    manifest.pop("update_url", None)
    return manifest


def expected_payloads(root: Path, manifest: dict) -> dict[str, bytes]:
    payloads = {
        name: source_path(root, name).read_bytes()
        for name in REQUIRED_SOURCE_FILES
        if name != "manifest.json"
    }
    payloads["manifest.json"] = encoded_json(release_manifest(manifest))
    return payloads


def write_deterministic_zip(destination: Path, payloads: dict[str, bytes]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise ReleaseError(f"Refusing to overwrite an existing ZIP candidate: {destination}")
    with zipfile.ZipFile(
        destination,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for name in sorted(payloads):
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, payloads[name])


def validate_zip(path: Path, expected_payloads_by_name: dict[str, bytes]) -> None:
    if not path.is_file() or path.stat().st_size > MAXIMUM_PACKAGE_BYTES:
        raise ReleaseError(f"Store ZIP is missing or exceeds 50 MB: {path}")
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if len(names) != len(set(names)) or set(names) != set(expected_payloads_by_name):
                raise ReleaseError(f"Store ZIP has unexpected entries: {sorted(names)}")
            if archive.testzip() is not None:
                raise ReleaseError(f"Store ZIP is corrupt: {path}")
            for info in infos:
                if info.is_dir() or info.filename.startswith("/") or ".." in Path(info.filename).parts:
                    raise ReleaseError(f"Store ZIP contains an unsafe path: {info.filename}")
                if info.date_time != FIXED_ZIP_TIME:
                    raise ReleaseError(f"Store ZIP timestamp is not deterministic: {info.filename}")
                if ((info.external_attr >> 16) & 0o170000) == 0o120000:
                    raise ReleaseError(f"Store ZIP contains a symbolic link: {info.filename}")
                if archive.read(info) != expected_payloads_by_name[info.filename]:
                    raise ReleaseError(f"Store ZIP payload does not match source: {info.filename}")
            archived_manifest = json.loads(archive.read("manifest.json"))
            if "key" in archived_manifest or "update_url" in archived_manifest:
                raise ReleaseError("Store ZIP leaked a development key or self-hosted update URL")
    except zipfile.BadZipFile as error:
        raise ReleaseError(f"Store ZIP is invalid: {path}") from error


def package_all(root: Path, output_dir: Path, record_in_ledger: bool = False) -> list[Path]:
    manifest, _, version = validated_release(root)
    ledger_version, _ = assert_source_version_allowed(root)
    if ledger_version != version:
        raise ReleaseError("Release ledger version does not match the Chromium manifest")
    payloads = expected_payloads(root, manifest)
    output_dir.mkdir(parents=True, exist_ok=True)
    if output_dir.is_symlink():
        raise ReleaseError(f"Store ZIP output directory must not be a symbolic link: {output_dir}")
    packages: list[Path] = []
    with tempfile.TemporaryDirectory(prefix="chromium-store-candidate-", dir=output_dir) as directory:
        candidate_dir = Path(directory)
        candidates: list[tuple[str, Path, Path]] = []
        for channel in CHANNELS:
            name = f"knowledge-capture-{channel}-{version}.zip"
            candidate = candidate_dir / name
            destination = output_dir / name
            write_deterministic_zip(candidate, payloads)
            validate_zip(candidate, payloads)
            assert_artifact_matches_record(root, version, f"{channel}-zip", candidate)
            candidates.append((channel, candidate, destination))
        for _, candidate, destination in candidates:
            install_immutable_artifact(candidate, destination)
            validate_zip(destination, payloads)
            packages.append(destination)
    if record_in_ledger:
        record_artifacts(
            root,
            version,
            [
                (f"{channel}-zip", path)
                for channel, path in zip(CHANNELS, packages)
            ],
        )
    return packages


def check_release(root: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="chromium-store-release-") as directory:
        first = Path(directory) / "first"
        second = Path(directory) / "second"
        first_packages = package_all(root, first)
        second_packages = package_all(root, second)
        for first_path, second_path in zip(first_packages, second_packages):
            if first_path.read_bytes() != second_path.read_bytes():
                raise ReleaseError(f"Store ZIP is not reproducible: {first_path.name}")


def readiness(root: Path, channel: str | None = None) -> None:
    required_channels = {channel} if channel else set(CHANNELS)
    _, extensions, version = validated_release(
        root,
        required_production_channels=required_channels,
    )
    selected_channels = (channel,) if channel else CHANNELS
    print(f"Chromium store release {version}: ready")
    for selected_channel in selected_channels:
        extension_id = extensions[PRODUCTION_ID_FIELDS[selected_channel]]
        listing_url = LISTING_URLS[selected_channel].format(extension_id=extension_id)
        print(f"{CHANNEL_LABELS[selected_channel]}: {extension_id} ({listing_url})")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help=argparse.SUPPRESS)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("check", help="validate and reproducibly build the Chrome package in a temporary directory")
    package = subparsers.add_parser("package", help="write the Chrome store submission ZIP")
    package.add_argument("--output-dir", type=Path)
    readiness_parser = subparsers.add_parser(
        "readiness",
        help="require the Chrome store-assigned production ID",
    )
    readiness_parser.add_argument("--channel", choices=CHANNELS)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    root = args.root.resolve()
    try:
        if args.command == "check":
            check_release(root)
            print("Chrome Web Store package: reproducible")
        elif args.command == "package":
            output_dir = args.output_dir or root / "dist" / "browser-extension"
            packages = package_all(root, output_dir.resolve(), record_in_ledger=True)
            for package in packages:
                print(package)
            print(
                "Chrome Store ZIP is ready for upload; run the readiness command after "
                "recording the store-assigned production ID."
            )
        elif args.command == "readiness":
            readiness(root, args.channel)
    except (OSError, ReleaseError, ReleaseLedgerError) as error:
        print(f"Chromium extension release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
