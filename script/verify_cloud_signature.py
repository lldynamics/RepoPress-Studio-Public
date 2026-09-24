#!/usr/bin/env python3
"""Verify that a signed RepoPress Mac app is authorized by its embedded iCloud profile."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import plistlib
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory


TEAM = "3H8UVVUCP3"
BUNDLE = "com.jinfang.PersonalSitePublisherMac"
CONTAINER = "iCloud.com.chengjinfang.repopress"


def output(*arguments: str) -> bytes:
    return subprocess.check_output(arguments, stderr=subprocess.DEVNULL)


def verify(profile_path: Path, app_path: Path, environment: str) -> None:
    if environment not in {"Development", "Production"}:
        raise ValueError("unsupported iCloud environment")
    profile = plistlib.loads(output("/usr/bin/security", "cms", "-D", "-i", str(profile_path)))
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        raise ValueError("provisioning profile has no expiration date")
    if expiration.replace(tzinfo=expiration.tzinfo or timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError("provisioning profile has expired")

    profile_rights = profile.get("Entitlements", {})
    expected = {
        "com.apple.application-identifier": f"{TEAM}.{BUNDLE}",
        "com.apple.developer.team-identifier": TEAM,
        "com.apple.developer.icloud-container-environment": environment,
        "com.apple.developer.aps-environment":
            "development" if environment == "Development" else "production",
    }
    for key, value in expected.items():
        if profile_rights.get(key) != value:
            raise ValueError(f"profile has the wrong {key}")
    for key in (
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.ubiquity-container-identifiers",
    ):
        if CONTAINER not in profile_rights.get(key, []):
            raise ValueError(f"profile does not authorize {key}")
    if not {"CloudKit", "CloudDocuments"}.issubset(
        set(profile_rights.get("com.apple.developer.icloud-services", []))
    ):
        raise ValueError("profile does not authorize CloudKit and CloudDocuments")

    info_path = app_path / "Contents" / "Info.plist"
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise ValueError("signed app has the wrong bundle identifier")

    signature_rights = plistlib.loads(
        output("/usr/bin/codesign", "-d", "--entitlements", ":-", str(app_path))
    )
    for key, value in expected.items():
        if signature_rights.get(key) != value:
            raise ValueError(f"signed app has the wrong {key}")
    for key in (
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.ubiquity-container-identifiers",
    ):
        if CONTAINER not in signature_rights.get(key, []):
            raise ValueError(f"signed app lacks {key}")
    if not {"CloudKit", "CloudDocuments"}.issubset(
        set(signature_rights.get("com.apple.developer.icloud-services", []))
    ):
        raise ValueError("signed app lacks CloudKit or CloudDocuments")

    certificates = profile.get("DeveloperCertificates", [])
    if not certificates or not all(isinstance(value, bytes) for value in certificates):
        raise ValueError("provisioning profile has no signing certificates")
    with TemporaryDirectory(prefix="repopress-cloud-cert-") as temporary:
        prefix = str(Path(temporary) / "signer-")
        output("/usr/bin/codesign", "-d", "--extract-certificates", prefix, str(app_path))
        signer = Path(prefix + "0").read_bytes()
    if signer not in certificates:
        raise ValueError("app signing certificate is not authorized by its provisioning profile")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("app", type=Path)
    parser.add_argument("environment", choices=("Development", "Production"))
    args = parser.parse_args()
    try:
        verify(args.profile, args.app, args.environment)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError) as error:
        print(f"cloud signature verification failed: {error}", file=sys.stderr)
        return 1
    print("cloud signature and provisioning profile match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
