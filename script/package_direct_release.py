#!/usr/bin/env python3
"""Build, Developer ID sign, optionally notarize, and verify the Direct macOS release."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "PersonalSitePublisherMac"
BUNDLE_ID = "com.jinfang.PersonalSitePublisherMac"
NATIVE_HOST_NAME = "KnowledgeNativeMessagingHost"
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}$")
SUBMISSION_ID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


class DirectReleaseError(RuntimeError):
    pass


def tool(name: str, default: str) -> str:
    return os.environ.get(name, default)


def run(
    arguments: list[str],
    *,
    cwd: Path,
    environment: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            cwd=cwd,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    except OSError as error:
        raise DirectReleaseError(f"Could not run {arguments[0]}: {error}") from error
    if check and result.returncode != 0:
        raise DirectReleaseError(
            f"Command failed ({result.returncode}): {' '.join(arguments[:3])}\n{result.stdout.strip()}"
        )
    return result


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def validated_identity(root: Path, identity: str) -> str:
    if not identity or identity == "-" or any(character in identity for character in "\r\n"):
        raise DirectReleaseError("An explicit Developer ID Application identity is required")
    result = run(
        [tool("SECURITY_TOOL", "/usr/bin/security"), "find-identity", "-v", "-p", "codesigning"],
        cwd=root,
    )
    matches = [
        line.strip()
        for line in result.stdout.splitlines()
        if identity in line and "Developer ID Application:" in line
    ]
    if len(matches) != 1:
        raise DirectReleaseError(
            "The selected identity is not one unique valid Developer ID Application certificate"
        )
    return matches[0]


def validate_direct_entitlements(root: Path) -> Path:
    path = root / "Packaging" / "DirectDistribution.entitlements"
    try:
        with path.open("rb") as handle:
            entitlements = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise DirectReleaseError(f"Cannot read Direct distribution entitlements: {error}") from error
    if not isinstance(entitlements, dict):
        raise DirectReleaseError("Direct distribution entitlements must be a plist dictionary")
    if entitlements.get("com.apple.security.get-task-allow") is True:
        raise DirectReleaseError("Direct distribution entitlements must not enable get-task-allow")
    return path


def load_info(app_bundle: Path) -> dict:
    path = app_bundle / "Contents" / "Info.plist"
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise DirectReleaseError(f"Cannot read packaged Info.plist: {error}") from error
    if not isinstance(value, dict):
        raise DirectReleaseError("Packaged Info.plist must be a dictionary")
    expected = {
        "CFBundleIdentifier": BUNDLE_ID,
        "PersonalSitePublisherBuildConfiguration": "Release",
        "PersonalSitePublisherDistributionChannel": "Direct",
        "PersonalSitePublisherBrowserExtensionAvailable": True,
        "PersonalSitePublisherFirefoxSignedPackageAvailable": True,
        "PersonalSitePublisherHardenedRuntimeEnabled": True,
    }
    for key, expected_value in expected.items():
        if value.get(key) != expected_value:
            raise DirectReleaseError(f"Packaged Info.plist has invalid {key}: {value.get(key)!r}")
    version = value.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise DirectReleaseError("Packaged app has an invalid marketing version")
    return value


def signature_details(root: Path, path: Path) -> tuple[str, str]:
    codesign = tool("CODESIGN_TOOL", "/usr/bin/codesign")
    run([codesign, "--verify", "--strict", "--verbose=4", str(path)], cwd=root)
    details = run([codesign, "-dv", "--verbose=4", str(path)], cwd=root).stdout
    if "Authority=Developer ID Application:" not in details:
        raise DirectReleaseError(f"Developer ID Application authority is missing: {path}")
    if not re.search(r"flags=.*\bruntime\b", details):
        raise DirectReleaseError(f"Hardened Runtime is missing: {path}")
    if "Timestamp=" not in details:
        raise DirectReleaseError(f"Secure signing timestamp is missing: {path}")
    team_match = re.search(r"^TeamIdentifier=(?!not set$)([A-Z0-9]{10})$", details, re.MULTILINE)
    if team_match is None:
        raise DirectReleaseError(f"Valid Developer Team identifier is missing: {path}")
    return details, team_match.group(1)


def validate_signed_bundle(root: Path, app_bundle: Path) -> tuple[dict, str]:
    info = load_info(app_bundle)
    native_host = app_bundle / "Contents" / "MacOS" / NATIVE_HOST_NAME
    if not native_host.is_file():
        raise DirectReleaseError("Direct package omitted the Native Messaging host")
    firefox_release = app_bundle / "Contents" / "Resources" / "BrowserExtension" / "Release"
    xpis = sorted(firefox_release.glob("knowledge-capture-firefox-*.xpi"))
    if len(xpis) != 1 or not (firefox_release / "updates.json").is_file():
        raise DirectReleaseError("Direct package omitted its verified Firefox release artifacts")

    _, app_team = signature_details(root, app_bundle)
    _, host_team = signature_details(root, native_host)
    if app_team != host_team:
        raise DirectReleaseError("App and Native Messaging host use different Developer ID teams")
    run(
        [
            tool("CODESIGN_TOOL", "/usr/bin/codesign"),
            "--verify",
            "--deep",
            "--strict",
            "--verbose=4",
            str(app_bundle),
        ],
        cwd=root,
    )
    return info, app_team


def create_zip(root: Path, app_bundle: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if destination.is_dir():
            raise DirectReleaseError(f"Archive destination is a directory: {destination}")
        destination.unlink()
    run(
        [
            tool("DITTO_TOOL", "/usr/bin/ditto"),
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            str(app_bundle),
            str(destination),
        ],
        cwd=root,
    )
    if not destination.is_file() or destination.stat().st_size <= 0:
        raise DirectReleaseError(f"Direct release archive was not created: {destination}")


def notarize(
    root: Path,
    app_bundle: Path,
    submission_zip: Path,
    output_dir: Path,
    profile: str,
) -> tuple[Path, str]:
    if not profile or any(character in profile for character in "\r\n"):
        raise DirectReleaseError("--notarize requires a notarytool keychain profile")
    xcrun = tool("XCRUN_TOOL", "/usr/bin/xcrun")
    result = run(
        [
            xcrun,
            "notarytool",
            "submit",
            str(submission_zip),
            "--keychain-profile",
            profile,
            "--wait",
            "--output-format",
            "json",
        ],
        cwd=root,
    )
    try:
        receipt = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise DirectReleaseError(f"notarytool returned invalid JSON: {error}") from error
    submission_id = receipt.get("id") if isinstance(receipt, dict) else None
    status = receipt.get("status") if isinstance(receipt, dict) else None
    if not isinstance(submission_id, str) or not SUBMISSION_ID_PATTERN.fullmatch(submission_id):
        raise DirectReleaseError("notarytool response omitted a valid submission ID")
    receipt_path = output_dir / "notarytool-submission.json"
    atomic_write(
        receipt_path,
        (json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    )
    if status != "Accepted":
        log_path = output_dir / f"notarytool-{submission_id}.json"
        run(
            [
                xcrun,
                "notarytool",
                "log",
                submission_id,
                "--keychain-profile",
                profile,
                str(log_path),
            ],
            cwd=root,
            check=False,
        )
        raise DirectReleaseError(
            f"Apple notarization was not accepted (status={status!r}); receipt: {receipt_path}"
        )

    run([xcrun, "stapler", "staple", str(app_bundle)], cwd=root)
    run([xcrun, "stapler", "validate", str(app_bundle)], cwd=root)
    spctl_result = run(
        [tool("SPCTL_TOOL", "/usr/sbin/spctl"), "-a", "-vv", "--type", "execute", str(app_bundle)],
        cwd=root,
    )
    if "accepted" not in spctl_result.stdout.lower():
        raise DirectReleaseError("Gatekeeper did not accept the notarized app")
    return receipt_path, submission_id


def check_readiness(root: Path, profile: str) -> None:
    if not profile or any(character in profile for character in "\r\n"):
        raise DirectReleaseError("--check-readiness requires a notarytool keychain profile")
    manifest_path = root / "BrowserExtension" / "Firefox" / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DirectReleaseError(f"Cannot read Firefox manifest for Direct release: {error}") from error
    version = manifest.get("version") if isinstance(manifest, dict) else None
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise DirectReleaseError("Firefox manifest has an invalid release version")
    signed_xpi = (
        root
        / "dist"
        / "browser-extension"
        / f"knowledge-capture-firefox-{version}.xpi"
    )
    run(
        [
            sys.executable,
            str(root / "script" / "firefox_extension_release.py"),
            "verify-signed",
            "--signed-xpi",
            str(signed_xpi),
        ],
        cwd=root,
    )
    run(
        [
            tool("XCRUN_TOOL", "/usr/bin/xcrun"),
            "notarytool",
            "history",
            "--keychain-profile",
            profile,
            "--output-format",
            "json",
        ],
        cwd=root,
    )
    print(f"Verified signed Firefox XPI: {signed_xpi}")
    print(f"notarytool keychain profile: {profile}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help=argparse.SUPPRESS)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prepare-only", action="store_true", help="build and Developer ID sign without submitting")
    mode.add_argument("--notarize", action="store_true", help="submit, wait, staple, and verify Gatekeeper")
    mode.add_argument(
        "--check-readiness",
        action="store_true",
        help="verify identity, signed Firefox XPI, and notarytool credentials without building",
    )
    parser.add_argument("--identity", default=os.environ.get("DIRECT_CODE_SIGN_IDENTITY"))
    parser.add_argument("--keychain-profile", default=os.environ.get("NOTARYTOOL_KEYCHAIN_PROFILE"))
    parser.add_argument("--output-dir", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    root = args.root.resolve()
    output_dir = (args.output_dir or root / "dist" / "direct-release").resolve()
    app_bundle = root / "dist" / f"{APP_NAME}.app"
    try:
        if (args.notarize or args.check_readiness) and (
            not args.keychain_profile
            or any(character in args.keychain_profile for character in "\r\n")
        ):
            raise DirectReleaseError(
                "notarization readiness requires a notarytool keychain profile"
            )
        identity_line = validated_identity(root, args.identity or "")
        validate_direct_entitlements(root)
        if args.check_readiness:
            check_readiness(root, args.keychain_profile or "")
            print(f"Developer ID identity: {identity_line}")
            print("Direct release signing and notarization credentials: ready")
            return 0
        environment = os.environ.copy()
        environment.update(
            {
                "CODE_SIGN_IDENTITY": args.identity,
                "DIRECT_DISTRIBUTION_BUILD": "1",
                "CODESIGN_TOOL": tool("CODESIGN_TOOL", "/usr/bin/codesign"),
                "SECURITY_TOOL": tool("SECURITY_TOOL", "/usr/bin/security"),
            }
        )
        build = run(
            ["bash", str(root / "script" / "build_and_run.sh"), "--package-only", "--release"],
            cwd=root,
            environment=environment,
        )
        if build.stdout.strip():
            print(build.stdout.strip())
        info, team_id = validate_signed_bundle(root, app_bundle)
        version = info["CFBundleShortVersionString"]
        submission_zip = output_dir / f"{APP_NAME}-{version}-Direct-pre-notarization.zip"
        create_zip(root, app_bundle, submission_zip)
        print(f"Developer ID identity: {identity_line}")
        print(f"Developer Team: {team_id}")
        print(f"Prepared Direct release: {submission_zip}")
        if args.prepare_only:
            print("Notarization was not submitted (--prepare-only).")
            return 0

        receipt_path, submission_id = notarize(
            root,
            app_bundle,
            submission_zip,
            output_dir,
            args.keychain_profile or "",
        )
        validate_signed_bundle(root, app_bundle)
        final_zip = output_dir / f"{APP_NAME}-{version}-Direct-notarized.zip"
        create_zip(root, app_bundle, final_zip)
        print(f"Notarization accepted: {submission_id}")
        print(f"Notarization receipt: {receipt_path}")
        print(f"Stapled Direct release: {final_zip}")
        return 0
    except DirectReleaseError as error:
        print(f"Direct release packaging error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
