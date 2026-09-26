#!/usr/bin/env python3
"""Behavior tests for the Release artifact hand-off manifest."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("release_artifact_manifest.py")


class ReleaseArtifactManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.manifest = self.root / ".build" / "release-artifact-manifest.json"
        self.bundle = self.root / "dist" / "RepoPress Studio.app"
        self.executable = self.bundle / "Contents" / "MacOS" / "PersonalSitePublisherMac"

        (self.root / "Sources" / "App").mkdir(parents=True)
        (self.root / "Packaging").mkdir()
        (self.root / "ShareExtension").mkdir()
        (self.root / "ShortcutExtension").mkdir()
        self.shared_package = self.root / "Shared" / "RepoPressCoreContracts" / "swift"
        (self.shared_package / "Sources" / "RepoPressCore").mkdir(parents=True)
        (self.shared_package / "Package.swift").write_text("// shared package\n")
        (self.shared_package / "Sources" / "RepoPressCore" / "Contract.swift").write_text("// shared source\n")
        (self.root / "script").mkdir()
        (self.bundle / "Contents" / "MacOS").mkdir(parents=True)
        (self.root / "Package.swift").write_text("// swift-tools-version: 6.0\n")
        (self.root / "Package.resolved").write_text("{}\n")
        (self.root / "Sources" / "App" / "main.swift").write_text("print(\"ok\")\n")
        (self.root / "Packaging" / "BuildVersion.xcconfig").write_text("MARKETING_VERSION = 1\n")
        (self.root / "ShareExtension" / "Info.plist").write_text("share\n")
        (self.root / "ShortcutExtension" / "Info.plist").write_text("shortcuts\n")
        (self.root / "script" / "build_and_run.sh").write_text("#!/usr/bin/env bash\n")
        (self.bundle / "Contents" / "Info.plist").write_text("plist\n")
        self.executable.write_text("binary\n")
        self.executable.chmod(0o755)

        environment = os.environ | {
            "GIT_AUTHOR_NAME": "Gate Test",
            "GIT_AUTHOR_EMAIL": "gate@example.invalid",
            "GIT_COMMITTER_NAME": "Gate Test",
            "GIT_COMMITTER_EMAIL": "gate@example.invalid",
        }
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, env=environment)
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True, env=environment)
        subprocess.run(
            ["git", "-C", str(self.root), "commit", "-qm", "fixture"],
            check=True,
            env=environment,
        )
        self.run_manifest("create", check=True)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_manifest(self, command: str, *, check: bool = False) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                command,
                "--root",
                str(self.root),
                "--manifest",
                str(self.manifest),
            ],
            check=check,
            capture_output=True,
            text=True,
        )

    def test_created_manifest_validates_without_drift(self) -> None:
        completed = self.run_manifest("validate")
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_dirty_build_input_change_invalidates_manifest(self) -> None:
        (self.root / "Sources" / "App" / "main.swift").write_text("print(\"changed\")\n")

        completed = self.run_manifest("validate")

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("build inputs changed", completed.stderr)

    def test_bundle_content_or_mode_change_invalidates_manifest(self) -> None:
        self.executable.chmod(0o644)

        completed = self.run_manifest("validate")

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("artifact content digest changed", completed.stderr)

    def test_shared_package_changes_invalidate_manifest(self) -> None:
        for relative in ("Package.swift", "Sources/RepoPressCore/Contract.swift"):
            with self.subTest(relative=relative):
                path = self.shared_package / relative
                original = path.read_text()
                path.write_text(original + "// changed shared input\n")
                completed = self.run_manifest("validate")
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("build inputs changed", completed.stderr)
                path.write_text(original)

    def test_missing_shared_package_manifest_rejects_artifact(self) -> None:
        (self.shared_package / "Package.swift").unlink()
        completed = self.run_manifest("validate")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("build input is missing: Shared/RepoPressCoreContracts/swift/Package.swift", completed.stderr)

    def test_shared_package_build_cache_does_not_invalidate_manifest(self) -> None:
        cache = self.shared_package / ".build"
        cache.mkdir()
        (cache / "generated-object.o").write_text("generated cache\n")
        completed = self.run_manifest("validate")
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
