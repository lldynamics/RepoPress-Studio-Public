#!/usr/bin/env python3
"""Resolve a Mac App Store profile into concrete application entitlements."""

from __future__ import annotations

from datetime import datetime, timezone
import plistlib
from pathlib import Path
import sys
from typing import Any


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"app store package: {message}")


def resolve_entitlements(
    profile: dict[str, Any],
    base: dict[str, Any],
    bundle_id: str,
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        fail("provisioning profile has no expiration date")
    expiration = expiration.replace(tzinfo=expiration.tzinfo or timezone.utc)
    if expiration <= (now or datetime.now(timezone.utc)):
        fail("provisioning profile is expired")

    profile_entitlements = profile.get("Entitlements", {})
    if not isinstance(profile_entitlements, dict):
        fail("provisioning profile entitlements are invalid")

    application_identifier = profile_entitlements.get(
        "com.apple.application-identifier", ""
    )
    if not isinstance(application_identifier, str) or not application_identifier.endswith(
        "." + bundle_id
    ):
        fail("provisioning profile does not match the app bundle identifier")
    if profile_entitlements.get("com.apple.security.get-task-allow") is True:
        fail("development provisioning profile is not valid for distribution")

    team_identifiers = profile.get("TeamIdentifier", [])
    if (
        not isinstance(team_identifiers, list)
        or len(team_identifiers) != 1
        or not isinstance(team_identifiers[0], str)
        or not team_identifiers[0]
    ):
        fail("provisioning profile must contain exactly one TeamIdentifier")
    profile_team = team_identifiers[0]
    if not application_identifier.startswith(profile_team + "."):
        fail("application identifier does not belong to the profile team")

    entitlement_team = profile_entitlements.get("com.apple.developer.team-identifier")
    if entitlement_team and entitlement_team != profile_team:
        fail("profile team entitlement does not match TeamIdentifier")

    resolved = dict(base)
    resolved["com.apple.application-identifier"] = application_identifier
    if entitlement_team:
        resolved["com.apple.developer.team-identifier"] = entitlement_team

    keychain_groups = profile_entitlements.get("keychain-access-groups")
    if keychain_groups is not None:
        if not isinstance(keychain_groups, list) or not all(
            isinstance(group, str) and group for group in keychain_groups
        ):
            fail("profile keychain access groups are invalid")

        resolved_groups: list[str] = []
        wildcard_group = profile_team + ".*"
        for group in keychain_groups:
            if group == wildcard_group:
                resolved_groups.append(application_identifier)
            elif "*" in group:
                fail(f"unsupported wildcard keychain access group: {group}")
            else:
                resolved_groups.append(group)
        resolved["keychain-access-groups"] = list(dict.fromkeys(resolved_groups))

    return resolved


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print(
            "usage: resolve_app_store_entitlements.py "
            "<profile.plist> <base.entitlements> <output.plist> <bundle-id>",
            file=sys.stderr,
        )
        return 2

    profile_path = Path(argv[1])
    base_path = Path(argv[2])
    output_path = Path(argv[3])
    bundle_id = argv[4]

    with profile_path.open("rb") as handle:
        profile = plistlib.load(handle)
    with base_path.open("rb") as handle:
        base = plistlib.load(handle)

    resolved = resolve_entitlements(profile, base, bundle_id)
    with output_path.open("wb") as handle:
        plistlib.dump(resolved, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
