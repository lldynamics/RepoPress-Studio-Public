#!/usr/bin/env python3
"""Offline contract tests for the final iCloud signing/profile check."""

from datetime import datetime, timedelta, timezone
import plistlib
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import verify_cloud_signature as cloud


class VerifyCloudSignatureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = TemporaryDirectory(prefix="repopress-cloud-sign-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "RepoPress Studio.app"
        contents = self.app / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": cloud.BUNDLE})
        )
        self.profile = self.root / "embedded.provisionprofile"
        self.profile.write_bytes(b"fixture")
        self.rights = {
            "com.apple.application-identifier": f"{cloud.TEAM}.{cloud.BUNDLE}",
            "com.apple.developer.team-identifier": cloud.TEAM,
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.aps-environment": "production",
            "com.apple.developer.icloud-container-identifiers": [cloud.CONTAINER],
            "com.apple.developer.ubiquity-container-identifiers": [cloud.CONTAINER],
            "com.apple.developer.icloud-services": ["CloudKit", "CloudDocuments"],
        }
        self.profile_data = {
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=7),
            "Entitlements": dict(self.rights),
            "DeveloperCertificates": [b"authorized-certificate"],
        }
        self.signer = b"authorized-certificate"

    def fake_output(self, *arguments: str) -> bytes:
        if arguments[:4] == ("/usr/bin/security", "cms", "-D", "-i"):
            return plistlib.dumps(self.profile_data)
        if arguments[:4] == ("/usr/bin/codesign", "-d", "--entitlements", ":-"):
            return plistlib.dumps(self.rights)
        if arguments[:3] == ("/usr/bin/codesign", "-d", "--extract-certificates"):
            Path(arguments[3] + "0").write_bytes(self.signer)
            return b""
        raise AssertionError(f"unexpected command: {arguments}")

    def verify(self) -> None:
        with patch.object(cloud, "output", side_effect=self.fake_output):
            cloud.verify(self.profile, self.app, "Production")

    def test_matching_profile_and_signer_pass(self) -> None:
        self.verify()

    def test_different_signing_certificate_fails(self) -> None:
        self.signer = b"another-team-certificate"
        with self.assertRaisesRegex(ValueError, "not authorized"):
            self.verify()

    def test_expired_profile_fails(self) -> None:
        self.profile_data["ExpirationDate"] = datetime.now(timezone.utc) - timedelta(days=1)
        with self.assertRaisesRegex(ValueError, "expired"):
            self.verify()

    def test_missing_signed_cloud_documents_fails(self) -> None:
        self.rights["com.apple.developer.icloud-services"] = ["CloudKit"]
        with self.assertRaisesRegex(ValueError, "CloudDocuments"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
