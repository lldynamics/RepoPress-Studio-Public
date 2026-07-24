#!/usr/bin/env python3
"""Behavior tests for check_typography.py."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "script" / "check_typography.py"


def run_fixture(source: str, filename: str = "FixtureView.swift") -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="mac-editor-typography-") as temporary_directory:
        root = Path(temporary_directory)
        view_root = root / "Sources" / "PersonalSitePublisherMac" / "Views"
        view_root.mkdir(parents=True)
        (view_root / filename).write_text(source, encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(CHECKER), "--root", str(root)],
            check=False,
            capture_output=True,
            text=True,
        )


def assert_passes(source: str, filename: str = "FixtureView.swift") -> None:
    result = run_fixture(source, filename)
    if result.returncode != 0:
        raise AssertionError(result.stderr)


def assert_fails(source: str, rule: str, filename: str = "FixtureView.swift") -> None:
    result = run_fixture(source, filename)
    if result.returncode == 0 or rule not in result.stderr:
        raise AssertionError(
            f"expected {rule} failure, got exit={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
        )


def main() -> int:
    assert_passes(
        """
import SwiftUI
struct FixtureView: View {
  var body: some View {
    VStack {
      Text("Readable").font(.callout)
      Text("Metadata").font(.caption)
      Image(systemName: "photo").font(.system(size: 32))
      Button("Secondary") {}.controlSize(.small)
    }
  }
}
"""
    )
    assert_fails('Text("Too small").font(.caption2)\n', "TYP001")
    assert_fails('Button("Tiny") {}.controlSize(.mini)\n', "TYP002")
    assert_fails(
        'Text("Writing").lineLimit(1).minimumScaleFactor(0.8)\n',
        "TYP003",
        filename="WorkspaceRailView.swift",
    )
    assert_fails(
        'Text("Fixed")\n  .font(.system(size: 11, weight: .medium))\n',
        "TYP004",
    )
    assert_passes('Image(systemName: "photo")\n  .font(.system(size: 20))\n')
    print("typography gate tests: pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
