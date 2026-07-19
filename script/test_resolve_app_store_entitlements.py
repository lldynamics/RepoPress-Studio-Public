#!/usr/bin/env python3
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest


SCRIPT_PATH = Path(__file__).with_name("resolve_app_store_entitlements.py")
SPEC = importlib.util.spec_from_file_location("resolve_app_store_entitlements", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ResolveAppStoreEntitlementsTests(unittest.TestCase):
    team = "TEAM123456"
    bundle_id = "com.example.Writer"
    application_identifier = f"{team}.{bundle_id}"

    def profile(self, keychain_groups: list[str]) -> dict[str, object]:
        return {
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=30),
            "TeamIdentifier": [self.team],
            "Entitlements": {
                "com.apple.application-identifier": self.application_identifier,
                "com.apple.developer.team-identifier": self.team,
                "keychain-access-groups": keychain_groups,
            },
        }

    def test_resolves_team_wildcard_to_exact_application_identifier(self) -> None:
        resolved = MODULE.resolve_entitlements(
            self.profile([f"{self.team}.*"]),
            {"com.apple.security.app-sandbox": True},
            self.bundle_id,
        )

        self.assertEqual(
            resolved["keychain-access-groups"], [self.application_identifier]
        )
        self.assertEqual(
            resolved["com.apple.application-identifier"], self.application_identifier
        )
        self.assertTrue(resolved["com.apple.security.app-sandbox"])

    def test_preserves_explicit_profile_group(self) -> None:
        group = f"{self.team}.shared"
        resolved = MODULE.resolve_entitlements(
            self.profile([group]), {}, self.bundle_id
        )
        self.assertEqual(resolved["keychain-access-groups"], [group])

    def test_rejects_unrecognized_wildcard_group(self) -> None:
        with self.assertRaisesRegex(SystemExit, "unsupported wildcard"):
            MODULE.resolve_entitlements(
                self.profile([f"{self.team}.shared.*"]), {}, self.bundle_id
            )

    def test_rejects_wrong_bundle_identifier(self) -> None:
        with self.assertRaisesRegex(SystemExit, "does not match"):
            MODULE.resolve_entitlements(
                self.profile([f"{self.team}.*"]), {}, "com.example.Other"
            )


if __name__ == "__main__":
    unittest.main()
