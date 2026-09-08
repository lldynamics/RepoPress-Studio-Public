#!/usr/bin/env python3
"""Reject tests that construct workbench persistence with application defaults."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from check_swift_safety import mask_comments_and_strings


ROOT = Path(__file__).resolve().parent.parent
BARE_CONSTRUCTOR = re.compile(r"\bWorkbench(?:Store|Persistence)\s*\(\s*\)")


def strip_swift_comments_and_strings(source: str) -> str:
    """Use the shared Swift lexer; interpolation expressions remain executable."""
    return mask_comments_and_strings(source)


def violations(root: Path) -> list[str]:
    result: list[str] = []
    for path in sorted((root / "Tests").rglob("*.swift")):
        sanitized = strip_swift_comments_and_strings(path.read_text(encoding="utf-8"))
        for match in BARE_CONSTRUCTOR.finditer(sanitized):
            line = sanitized.count("\n", 0, match.start()) + 1
            result.append(f"{path.relative_to(root)}:{line}: bare {match.group().strip()} is not allowed")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    found = violations(args.root.resolve())
    if found:
        print("Test isolation violations:", file=sys.stderr)
        print("\n".join(found), file=sys.stderr)
        return 1
    print("Test isolation check passed: no bare WorkbenchStore()/WorkbenchPersistence() calls.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
