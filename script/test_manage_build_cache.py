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
        tauri_node_modules = root / "Apps" / "RepoPressDesktop" / "node_modules"
        tauri_dist = root / "Apps" / "RepoPressDesktop" / "dist"
        tauri_rust_target = root / "Apps" / "RepoPressDesktop" / "src-tauri" / "target"
        tauri_node_modules.mkdir(parents=True)
        tauri_dist.mkdir(parents=True)
        tauri_rust_target.mkdir(parents=True)
        (tauri_node_modules / "package.js").write_bytes(b"dependency")
        (tauri_dist / "index.html").write_bytes(b"bundle")
        (tauri_rust_target / "binary").write_bytes(b"rust")

        dry_run = invoke(root, "--remove", "coverage")
        assert dry_run.returncode == 0, dry_run.stderr
        dry_payload = json.loads(dry_run.stdout)
        assert dry_payload["dryRun"] is True
        assert dry_payload["actions"][0]["removed"] is False
        assert coverage.exists() and checkout.exists()
        inventory_names = {row["name"] for row in dry_payload["inventory"]}
        assert {
            "tauri-node-modules",
            "tauri-dist",
            "tauri-rust-target",
        }.issubset(inventory_names)

        applied = invoke(root, "--remove", "coverage", "--apply")
        assert applied.returncode == 0, applied.stderr
        applied_payload = json.loads(applied.stdout)
        assert applied_payload["actions"][0]["removed"] is True
        assert not coverage.exists() and checkout.exists()

        tauri_applied = invoke(root, "--remove", "tauri-dist", "--apply")
        assert tauri_applied.returncode == 0, tauri_applied.stderr
        tauri_payload = json.loads(tauri_applied.stdout)
        assert tauri_payload["actions"][0]["name"] == "tauri-dist"
        assert tauri_payload["actions"][0]["removed"] is True
        assert not tauri_dist.exists()
        assert tauri_node_modules.exists() and tauri_rust_target.exists()

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

        outside_tauri = root / "outside-tauri"
        outside_tauri.mkdir()
        shutil_target = root / "tauri-symlink-root"
        (shutil_target / "Apps").mkdir(parents=True)
        (shutil_target / "Apps" / "RepoPressDesktop").symlink_to(
            outside_tauri, target_is_directory=True
        )
        refused_tauri = invoke(
            shutil_target, "--remove", "tauri-node-modules", "--apply"
        )
        assert refused_tauri.returncode != 0
        assert outside_tauri.exists()

    print("build cache policy test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
