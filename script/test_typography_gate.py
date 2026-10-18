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
      Text("Readable").font(.workbenchBody)
      Text("Metadata").font(.workbenchMetadata.monospacedDigit()).foregroundStyle(.workbenchSecondary)
      Text(attachment.caption).font(.workbenchMetadata)
      Image(systemName: "photo").font(.system(size: WorkbenchIconSize.hero))
      Button("Secondary") {}.controlSize(.small)
    }
    .onTapGesture { edit(.caption(value), style: .footnote, scope: .body, field: .title) }
  }
}
"""
    )
    assert_fails('Text("Too small").font(.caption2)\n', "TYP001")
    assert_fails('Text("Too small").font(.caption.weight(.semibold))\n', "TYP001")
    assert_fails('Text("Too small").font(.footnote)\n', "TYP001")
    assert_fails('Text("Code").font(.system(.caption, design: .monospaced))\n', "TYP001")
    assert_fails('Text("Toggle").font(isCompact ? .caption : .body)\n', "TYP001")
    assert_fails('static let workbenchMetadata: Font = .caption\n', "TYP001")
    assert_fails('Text("Wrapped").font(\n  .caption.weight(.medium))\n', "TYP001")
    assert_fails('label.font = NSFont.preferredFont(forTextStyle: .caption1)\n', "TYP001")
    assert_fails('Text("Faint").foregroundStyle(.secondary)\n', "TYP006")
    assert_fails('Text("Raw").font(.body)\n', "TYP007")
    assert_fails('Text("Raw").font(.headline.weight(.bold))\n', "TYP007")
    assert_fails('Text("Code").font(.system(.body, design: .monospaced))\n', "TYP007")
    assert_fails('Text("Toggle").font(isRead ? .workbenchBody : .title3)\n', "TYP007")
    assert_fails('piece.font = .body.weight(.semibold)\n', "TYP007")
    assert_fails('stateCopy(titleFont: .headline, messageFont: .workbenchBody)\n', "TYP007")
    assert_fails('Text("Wrapped").font(\n  .subheadline.weight(.medium))\n', "TYP007")
    assert_passes(
        'static var workbenchBody: Font { workbenchLevel(.body, baseSize: 13) }\n',
        filename="WorkbenchTypography.swift",
    )
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
    assert_passes('Image(systemName: "photo")\n  .font(.system(size: WorkbenchIconSize.prominent))\n')
    assert_fails('Image(systemName: "photo")\n  .font(.system(size: 20))\n', "TYP005")
    print("typography gate tests: pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
