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
NUMERIC_SYMBOL_SIZE_PATTERN = re.compile(r"\.system\(size\s*:\s*[0-9]")
# macOS renders caption, caption2 and footnote at a fixed 10pt and does not
# scale them with any system text-size setting. Match only font contexts so
# domain values such as `attachment.caption` or `style: .footnote` stay legal.
TEN_POINT_STYLE = r"\.(?:caption2?|footnote)\b"
TEN_POINT_FONT_PATTERNS = (
    re.compile(r"\.font\(\s*" + TEN_POINT_STYLE),
    re.compile(r"\.font\([^\n]*[?:]\s*" + TEN_POINT_STYLE),
    re.compile(r"\.system\(\s*" + TEN_POINT_STYLE),
    re.compile(r"\bFont\s*" + TEN_POINT_STYLE),
    re.compile(r":\s*Font\??\s*=\s*" + TEN_POINT_STYLE),
    re.compile(r"forTextStyle:\s*\.(?:caption1|caption2|footnote)\b"),
)
CONTINUED_FONT_PATTERN = re.compile(r"\.font\(\s*$")
LEADING_TEN_POINT_PATTERN = re.compile(r"^\s*" + TEN_POINT_STYLE)
# The system secondary label is 50% black (about 3.9:1 on white); workbench text
# uses the stronger `.workbenchSecondary` style defined in WorkbenchTextHierarchy.
# Workbench text must come from the scalable tokens in WorkbenchTypography.swift.
# Only explicit font contexts are matched, so enum cases such as `.body` or
# `.title` used as data stay legal.
RAW_TEXT_STYLE = r"\.(?:subheadline|body|headline|title|title2|title3|largeTitle|callout)\b"
RAW_TEXT_STYLE_PATTERNS = (
    re.compile(r"\.font\(\s*" + RAW_TEXT_STYLE),
    re.compile(r"\.font\([^\n]*[?:]\s*" + RAW_TEXT_STYLE),
    re.compile(r"\.system\(\s*" + RAW_TEXT_STYLE),
    re.compile(r"\bFont\s*" + RAW_TEXT_STYLE),
    re.compile(r":\s*Font\??\s*=\s*" + RAW_TEXT_STYLE),
    re.compile(r"\.font\s*=\s*" + RAW_TEXT_STYLE),
    re.compile(r"\b\w*Font:\s*" + RAW_TEXT_STYLE),
)
TYPOGRAPHY_TOKEN_FILE = "WorkbenchTypography.swift"


def uses_raw_text_style(lines: list[str], index: int) -> bool:
    line = lines[index]
    if any(pattern.search(line) for pattern in RAW_TEXT_STYLE_PATTERNS):
        return True
    return (
        index > 0
        and CONTINUED_FONT_PATTERN.search(lines[index - 1]) is not None
        and re.match(r"^\s*" + RAW_TEXT_STYLE, line) is not None
    )


SYSTEM_SECONDARY_TEXT_PATTERN = re.compile(r"\.foregroundStyle\(\s*\.secondary\s*\)")


def uses_ten_point_style(lines: list[str], index: int) -> bool:
    line = lines[index]
    if any(pattern.search(line) for pattern in TEN_POINT_FONT_PATTERNS):
        return True
    return (
        index > 0
        and CONTINUED_FONT_PATTERN.search(lines[index - 1]) is not None
        and LEADING_TEN_POINT_PATTERN.search(line) is not None
    )


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
            if uses_ten_point_style(lines, index):
                findings.append(
                    Finding(
                        path,
                        line_number,
                        "TYP001",
                        "caption, caption2 and footnote are fixed 10pt on macOS, below the workbench's readable minimum; use workbenchMetadata (subheadline) or a larger semantic role",
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
                elif NUMERIC_SYMBOL_SIZE_PATTERN.search(line):
                    findings.append(
                        Finding(
                            path,
                            line_number,
                            "TYP005",
                            "icon sizes must use a WorkbenchIconSize token so the same kind of icon matches across views",
                        )
                    )
            if path.name != TYPOGRAPHY_TOKEN_FILE and uses_raw_text_style(lines, index):
                findings.append(
                    Finding(
                        path,
                        line_number,
                        "TYP007",
                        "raw system text styles bypass the interface text scale; use a workbench font token from WorkbenchTypography.swift",
                    )
                )
            if SYSTEM_SECONDARY_TEXT_PATTERN.search(line):
                findings.append(
                    Finding(
                        path,
                        line_number,
                        "TYP006",
                        "system .secondary text is below 4.5:1 on window backgrounds; use .workbenchSecondary",
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
