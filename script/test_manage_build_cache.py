#!/usr/bin/env python3
"""Contract tests for the fail-closed local build-cache policy."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "script" / "manage_build_cache.py"


def invoke(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--root", str(root), *arguments],
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="build-cache-policy.") as temporary:
        root = Path(temporary)
        coverage = root / ".build" / "coverage"
        checkout = root / ".build" / "checkouts"
        coverage.mkdir(parents=True)
        checkout.mkdir(parents=True)
        (coverage / "profile.profraw").write_bytes(b"coverage")
        (checkout / "dependency.swift").write_bytes(b"preserve")

        dry_run = invoke(root, "--remove", "coverage")
        assert dry_run.returncode == 0, dry_run.stderr
        dry_payload = json.loads(dry_run.stdout)
        assert dry_payload["dryRun"] is True
        assert dry_payload["actions"][0]["removed"] is False
        assert coverage.exists() and checkout.exists()

        applied = invoke(root, "--remove", "coverage", "--apply")
        assert applied.returncode == 0, applied.stderr
        applied_payload = json.loads(applied.stdout)
        assert applied_payload["actions"][0]["removed"] is True
        assert not coverage.exists() and checkout.exists()

        refused = invoke(root, "--remove", "checkouts", "--apply")
        assert refused.returncode != 0
        assert checkout.exists()

        outside = root / "outside"
        outside.mkdir()
        coverage.symlink_to(outside, target_is_directory=True)
        symlink = invoke(root, "--remove", "coverage", "--apply")
        assert symlink.returncode != 0
        assert outside.exists()

        symlink_root = root / "symlink-root"
        symlink_target = root / "symlink-target"
        (symlink_target / "coverage").mkdir(parents=True)
        symlink_root.mkdir()
        (symlink_root / ".build").symlink_to(symlink_target, target_is_directory=True)
        refused_root = invoke(symlink_root, "--remove", "coverage", "--apply")
        assert refused_root.returncode != 0
        assert (symlink_target / "coverage").exists()

    print("build cache policy test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
