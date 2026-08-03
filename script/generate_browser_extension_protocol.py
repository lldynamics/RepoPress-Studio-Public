#!/usr/bin/env python3
"""Generate and verify browser-extension loopback constants from one definition."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
from pathlib import Path


DEFAULT_ROOT = Path(__file__).resolve().parent.parent
FIREFOX_ID_PATTERN = re.compile(r"^[^\s@]+@[^\s@]+$")
CHROMIUM_ID_PATTERN = re.compile(r"^[a-p]{32}$")
BUNDLE_ID_PATTERN = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
ALLOWED_METHODS = frozenset(("GET", "POST"))


class ProtocolGenerationError(RuntimeError):
    pass


def object_without_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolGenerationError(f"Duplicate JSON field in browser protocol input: {key}")
        result[key] = value
    return result


def load_object(path: Path) -> dict:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=object_without_duplicate_keys,
        )
    except (OSError, json.JSONDecodeError) as error:
        raise ProtocolGenerationError(f"Cannot read valid JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise ProtocolGenerationError(f"Expected a JSON object in {path}")
    return value


def require_exact_keys(value: dict, expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ProtocolGenerationError(
            f"{label} fields do not match the contract; missing={missing}, extra={extra}"
        )


def validated_definition(root: Path) -> dict:
    path = root / "BrowserExtension" / "browser-extension-protocol.json"
    value = load_object(path)
    require_exact_keys(
        value,
        {"documentVersion", "activeExtensions", "extensions", "loopback", "captureProtocol"},
        "protocol",
    )
    if value["documentVersion"] != 1:
        raise ProtocolGenerationError("Unsupported browser extension protocol documentVersion")

    extensions = value["extensions"]
    active_extensions = value["activeExtensions"]
    loopback = value["loopback"]
    capture = value["captureProtocol"]
    if (
        not isinstance(extensions, dict)
        or not isinstance(loopback, dict)
        or not isinstance(capture, dict)
    ):
        raise ProtocolGenerationError(
            "extensions, loopback and captureProtocol must be JSON objects"
        )
    require_exact_keys(
        extensions,
        {
            "chromiumDevelopmentID",
            "firefoxID",
            "safariBundleID",
            "chromeProductionID",
            "edgeProductionID",
        },
        "extensions",
    )
    if active_extensions != ["safari", "chrome", "firefox"]:
        raise ProtocolGenerationError(
            "activeExtensions must be exactly ['safari', 'chrome', 'firefox'] for this release"
        )
    require_exact_keys(
        loopback,
        {"host", "port", "protocolHeaderName", "protocolHeaderValue"},
        "loopback",
    )
    require_exact_keys(
        capture,
        {"maximumInputBytes", "routes", "statusPayloadVersion"},
        "captureProtocol",
    )

    if loopback["host"] != "127.0.0.1":
        raise ProtocolGenerationError("loopback.host must be the IPv4 loopback address")
    if (
        not isinstance(loopback["port"], int)
        or isinstance(loopback["port"], bool)
        or not 10_240 <= loopback["port"] <= 65_535
    ):
        raise ProtocolGenerationError("loopback.port is outside the allowed range")
    if loopback["protocolHeaderName"] != "X-RepoPress-Protocol":
        raise ProtocolGenerationError("loopback.protocolHeaderName is invalid")
    if loopback["protocolHeaderValue"] != "1":
        raise ProtocolGenerationError("loopback.protocolHeaderValue is invalid")

    if not isinstance(extensions["firefoxID"], str) or not FIREFOX_ID_PATTERN.fullmatch(
        extensions["firefoxID"]
    ):
        raise ProtocolGenerationError("extensions.firefoxID is invalid")
    if not isinstance(extensions["chromiumDevelopmentID"], str) or not CHROMIUM_ID_PATTERN.fullmatch(
        extensions["chromiumDevelopmentID"]
    ):
        raise ProtocolGenerationError("extensions.chromiumDevelopmentID is invalid")
    if (
        not isinstance(extensions["safariBundleID"], str)
        or not BUNDLE_ID_PATTERN.fullmatch(extensions["safariBundleID"])
        or not extensions["safariBundleID"].startswith(
            "com.jinfang.PersonalSitePublisherMac."
        )
    ):
        raise ProtocolGenerationError("extensions.safariBundleID is invalid")
    for field in ("chromeProductionID", "edgeProductionID"):
        extension_id = extensions[field]
        if extension_id is not None and (
            not isinstance(extension_id, str) or not CHROMIUM_ID_PATTERN.fullmatch(extension_id)
        ):
            raise ProtocolGenerationError(f"extensions.{field} must be null or a Chromium ID")
    size = capture["maximumInputBytes"]
    if (
        not isinstance(size, int)
        or isinstance(size, bool)
        or not 1_024 <= size <= 100 * 1_024 * 1_024
    ):
        raise ProtocolGenerationError(
            "captureProtocol.maximumInputBytes is outside the safety range"
        )
    status_payload_version = capture["statusPayloadVersion"]
    if (
        not isinstance(status_payload_version, int)
        or isinstance(status_payload_version, bool)
        or not 1 <= status_payload_version <= 100
    ):
        raise ProtocolGenerationError(
            "captureProtocol.statusPayloadVersion is outside the safety range"
        )

    routes = capture["routes"]
    if not isinstance(routes, dict) or not routes:
        raise ProtocolGenerationError("captureProtocol.routes must be a non-empty object")
    for route, methods in routes.items():
        if not isinstance(route, str) or not route.startswith("/v1/"):
            raise ProtocolGenerationError(f"Invalid capture route: {route!r}")
        if (
            not isinstance(methods, list)
            or not methods
            or any(not isinstance(method, str) or method not in ALLOWED_METHODS for method in methods)
            or len(set(methods)) != len(methods)
        ):
            raise ProtocolGenerationError(f"Invalid method list for capture route {route}")
    return value


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def swift_optional_string(value: str | None) -> str:
    return "nil" if value is None else swift_string(value)


def render_swift(definition: dict) -> str:
    capture = definition["captureProtocol"]
    loopback = definition["loopback"]
    extensions = definition["extensions"]
    active_extensions = definition["activeExtensions"]
    routes = []
    for route, methods in sorted(capture["routes"].items()):
        rendered_methods = ", ".join(swift_string(method) for method in sorted(methods))
        routes.append(f"    {swift_string(route)}: [{rendered_methods}],")
    return "\n".join(
        [
            "// Generated by script/generate_browser_extension_protocol.py. Do not edit.",
            "",
            "extension BrowserExtensionProtocol {",
            "  public static let activeBrowserExtensions = [",
            *[f"    {swift_string(channel)}," for channel in active_extensions],
            "  ]",
            "  public static let safariWebExtensionBundleID =",
            f"    {swift_string(extensions['safariBundleID'])}",
            "  public static let chromiumDevelopmentExtensionID =",
            f"    {swift_string(extensions['chromiumDevelopmentID'])}",
            "  public static let chromeProductionExtensionID: String? =",
            f"    {swift_optional_string(extensions['chromeProductionID'])}",
            f"  public static let loopbackHost = {swift_string(loopback['host'])}",
            f"  public static let loopbackPort: UInt16 = {loopback['port']}",
            "  public static let loopbackBaseURL =",
            '    "http://\\(loopbackHost):\\(loopbackPort)"',
            "  public static let loopbackProtocolHeaderName =",
            f"    {swift_string(loopback['protocolHeaderName'])}",
            "  public static let loopbackProtocolHeaderValue =",
            f"    {swift_string(loopback['protocolHeaderValue'])}",
            f"  public static let maximumInputBytes = {capture['maximumInputBytes']:_}",
            f"  public static let statusPayloadVersion = {capture['statusPayloadVersion']}",
            "  public static let accessControlAllowHeaders =",
            '    "Authorization, Content-Type, \\(loopbackProtocolHeaderName)"',
            "",
            "  public static let allowedRoutes: [String: Set<String>] = [",
            *routes,
            "  ]",
            "}",
            "",
        ]
    )


def render_javascript(definition: dict) -> str:
    capture = definition["captureProtocol"]
    loopback = definition["loopback"]
    payload = {
        "activeExtensions": definition["activeExtensions"],
        "maximumInputBytes": capture["maximumInputBytes"],
        "statusPayloadVersion": capture["statusPayloadVersion"],
        "routes": {
            route: sorted(methods)
            for route, methods in sorted(capture["routes"].items())
        },
        "loopback": {
            "baseURL": f"http://{loopback['host']}:{loopback['port']}",
            "protocolHeaderName": loopback["protocolHeaderName"],
            "protocolHeaderValue": loopback["protocolHeaderValue"],
        },
    }
    rendered = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True).replace(
        "\n", "\n  "
    )
    return (
        "// Generated by script/generate_browser_extension_protocol.py. Do not edit.\n"
        "(() => {\n"
        f"  const protocol = {rendered};\n"
        "  for (const methods of Object.values(protocol.routes)) Object.freeze(methods);\n"
        "  Object.freeze(protocol.routes);\n"
        "  globalThis.REPOPRESS_BROWSER_EXTENSION_PROTOCOL = Object.freeze(protocol);\n"
        "})();\n"
    )


def chromium_extension_id(manifest: dict) -> str:
    key = manifest.get("key")
    if not isinstance(key, str) or not key:
        raise ProtocolGenerationError("Chromium manifest key is missing")
    try:
        decoded = base64.b64decode(key, validate=True)
    except ValueError as error:
        raise ProtocolGenerationError("Chromium manifest key is not valid base64") from error
    digest = hashlib.sha256(decoded).digest()[:16]
    return "".join(chr(ord("a") + nibble) for byte in digest for nibble in (byte >> 4, byte & 15))


def encoded_json(value: dict) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def atomic_write(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(value, encoding="utf-8")
    os.replace(temporary, path)


def synchronize(root: Path, write: bool) -> None:
    definition = validated_definition(root)
    extension_root = root / "BrowserExtension"
    firefox_root = extension_root / "Firefox"
    safari_root = extension_root / "Safari"
    mismatches: list[str] = []
    chromium_manifest_path = extension_root / "manifest.json"
    firefox_manifest_path = firefox_root / "manifest.json"
    release_config_path = extension_root / "firefox-release.json"
    chromium_manifest = load_object(chromium_manifest_path)
    firefox_manifest = load_object(firefox_manifest_path)
    release_config = load_object(release_config_path)
    expected_chromium_id = definition["extensions"]["chromiumDevelopmentID"]
    actual_chromium_id = chromium_extension_id(chromium_manifest)
    if actual_chromium_id != expected_chromium_id:
        raise ProtocolGenerationError(
            "Chromium manifest key derives extension ID "
            f"{actual_chromium_id}, not protocol ID {expected_chromium_id}"
        )

    outputs = {
        root
        / "Sources"
        / "BrowserExtensionProtocolSupport"
        / "BrowserExtensionProtocolGenerated.swift": render_swift(definition),
        extension_root / "protocol.generated.js": render_javascript(definition),
        firefox_root / "protocol.generated.js": render_javascript(definition),
        safari_root / "protocol.generated.js": render_javascript(definition),
    }
    for path, expected in outputs.items():
        actual = path.read_text(encoding="utf-8") if path.is_file() else None
        if actual == expected:
            continue
        if write:
            atomic_write(path, expected)
        else:
            mismatches.append(str(path.relative_to(root)))

    gecko = firefox_manifest.get("browser_specific_settings", {}).get("gecko")
    if not isinstance(gecko, dict):
        raise ProtocolGenerationError("Firefox manifest gecko settings are missing")
    expected_firefox_id = definition["extensions"]["firefoxID"]
    expected_scripts = ["protocol.generated.js", "background.js"]
    firefox_changed = False
    if gecko.get("id") != expected_firefox_id:
        if write:
            gecko["id"] = expected_firefox_id
            firefox_changed = True
        else:
            mismatches.append("BrowserExtension/Firefox/manifest.json gecko.id")
    background = firefox_manifest.get("background")
    if not isinstance(background, dict):
        raise ProtocolGenerationError("Firefox manifest background settings are missing")
    if background.get("scripts") != expected_scripts:
        if write:
            background["scripts"] = expected_scripts
            firefox_changed = True
        else:
            mismatches.append("BrowserExtension/Firefox/manifest.json background.scripts")
    if firefox_changed:
        atomic_write(firefox_manifest_path, encoded_json(firefox_manifest))

    if release_config.get("addonID") != expected_firefox_id:
        if write:
            release_config["addonID"] = expected_firefox_id
            atomic_write(release_config_path, encoded_json(release_config))
        else:
            mismatches.append("BrowserExtension/firefox-release.json addonID")

    if mismatches:
        raise ProtocolGenerationError(
            "Generated browser protocol artifacts are out of sync: "
            + ", ".join(mismatches)
            + "; run python3 script/generate_browser_extension_protocol.py --write"
        )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify generated protocol artifacts")
    mode.add_argument("--write", action="store_true", help="rewrite generated protocol artifacts")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    try:
        synchronize(args.root.resolve(), args.write)
    except (OSError, ProtocolGenerationError) as error:
        print(f"Browser extension protocol error: {error}", file=sys.stderr)
        return 1
    action = "generated" if args.write else "synchronized"
    print(f"Browser extension protocol artifacts: {action}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
