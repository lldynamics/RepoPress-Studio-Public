#!/usr/bin/env python3
"""Guard the macOS workbench's minimum readable typography baseline."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    path: Path
    line: int
    rule: str
    message: str


VIEW_OWNER_PATTERN = re.compile(r"\b(Text|Label|Image)\s*\(")
FIXED_POINT_FONT_PATTERN = re.compile(r"\.font\(\.system\(size\s*:")


def nearest_view_owner(lines: list[str], font_line_index: int) -> str | None:
    lower_bound = max(0, font_line_index - 12)
    for index in range(font_line_index, lower_bound - 1, -1):
        match = VIEW_OWNER_PATTERN.search(lines[index])
        if match:
            return match.group(1)
    return None


def scan(root: Path) -> list[Finding]:
    source_root = root / "Sources" / "PersonalSitePublisherMac"
    findings: list[Finding] = []
    for path in sorted(source_root.rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            line_number = index + 1
            if ".caption2" in line:
                findings.append(
                    Finding(
                        path,
                        line_number,
                        "TYP001",
                        "caption2 is below the workbench's readable minimum; use workbenchMetadata or a larger semantic role",
                    )
                )
            if ".controlSize(.mini)" in line:
                findings.append(
                    Finding(
                        path,
                        line_number,
                        "TYP002",
                        "mini controls are too small for the workbench; use small for icon-only utilities or regular for actions",
                    )
                )
            if path.name == "WorkspaceRailView.swift" and ".minimumScaleFactor" in line:
                findings.append(
                    Finding(
                        path,
                        line_number,
                        "TYP003",
                        "primary workspace navigation must not shrink its labels",
                    )
                )
            if FIXED_POINT_FONT_PATTERN.search(line):
                owner = nearest_view_owner(lines, index)
                if owner in {"Text", "Label"}:
                    findings.append(
                        Finding(
                            path,
                            line_number,
                            "TYP004",
                            "visible text uses a fixed point size; use a semantic Font role so accessibility sizing remains effective",
                        )
                    )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root to scan",
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    findings = scan(root)
    if findings:
        for finding in findings:
            try:
                display_path = finding.path.relative_to(root)
            except ValueError:
                display_path = finding.path
            print(
                f"{display_path}:{finding.line}: {finding.rule}: {finding.message}",
                file=sys.stderr,
            )
        print(f"typography gate: {len(findings)} issue(s)", file=sys.stderr)
        return 1

    print(
        "typography gate: semantic text styles, readable metadata, navigation labels, and control sizes verified"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
