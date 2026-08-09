#!/usr/bin/env python3
"""Enforce the platform-neutral import and side-effect boundary of RepoPressCore.

The shared Swift target is intentionally Foundation-only.  This gate is a small
repository check, not a Swift parser or a runtime dependency: comments and string
literals are masked before looking for imports and side-effect APIs so examples
and documentation in source files do not produce false positives.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable, Sequence


FORBIDDEN_IMPORTS: tuple[str, ...] = (
    "AppKit",
    "UIKit",
    "SwiftUI",
    "Security",
    "Combine",
    "SQLite3",
    "PDFKit",
    "Vision",
    "NaturalLanguage",
    "CryptoKit",
)

_IMPORT_RE = re.compile(
    r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*)(?:\([^)]*\))?\s+)*"
    r"import\s+(?:(?:struct|class|enum|protocol|func|var|let)\s+)?"
    r"(?P<module>[A-Za-z_][A-Za-z0-9_.]*)"
)
_FORBIDDEN_IMPORT_SET = frozenset(FORBIDDEN_IMPORTS)
_PROCESS_RE = re.compile(r"\bProcess\b")
_FILE_MANAGER_DEFAULT_RE = re.compile(r"\bFileManager\s*\.\s*default\b")
_URL_SESSION_SHARED_RE = re.compile(r"\bURLSession\s*\.\s*shared\b")


def _mask_range(chars: list[str], start: int, end: int) -> None:
    """Mask source characters while retaining line boundaries for diagnostics."""

    for index in range(start, min(end, len(chars))):
        if chars[index] not in "\r\n":
            chars[index] = " "


def _raw_string_start(source: str, index: int) -> tuple[int, bool] | None:
    """Return ``(hash_count, triple_quote)`` for a Swift raw string opener."""

    if source[index] != "#":
        return None
    cursor = index
    while cursor < len(source) and source[cursor] == "#":
        cursor += 1
    if cursor >= len(source) or source[cursor] != '"':
        return None
    triple = source.startswith('"""', cursor)
    return cursor - index, triple


def _mask_comments_and_strings(source: str) -> str:
    """Replace comments and string literals with spaces, preserving newlines.

    Swift supports nested block comments and raw/multiline strings.  The scanner
    handles those forms sufficiently for this boundary gate while deliberately
    treating string interpolation as string content: an API name in an example
    string must not become a false boundary violation.
    """

    chars = list(source)
    length = len(source)
    index = 0
    state = "normal"
    block_depth = 0
    string_end = '"'

    while index < length:
        if state == "normal":
            if source.startswith("//", index):
                _mask_range(chars, index, index + 2)
                index += 2
                state = "line-comment"
                continue
            if source.startswith("/*", index):
                _mask_range(chars, index, index + 2)
                index += 2
                block_depth = 1
                state = "block-comment"
                continue

            raw_start = _raw_string_start(source, index)
            if raw_start is not None:
                hash_count, triple = raw_start
                quote_index = index + hash_count
                delimiter = '"""' if triple else '"'
                string_end = delimiter + ("#" * hash_count)
                _mask_range(chars, index, quote_index + len(delimiter))
                index = quote_index + len(delimiter)
                state = "raw-string"
                continue

            if source.startswith('"""', index):
                string_end = '"""'
                _mask_range(chars, index, index + 3)
                index += 3
                state = "string"
                continue
            if source[index] == '"':
                string_end = '"'
                _mask_range(chars, index, index + 1)
                index += 1
                state = "string"
                continue

            index += 1
            continue

        if state == "line-comment":
            if source[index] in "\r\n":
                state = "normal"
            else:
                chars[index] = " "
            index += 1
            continue

        if state == "block-comment":
            if source.startswith("/*", index):
                _mask_range(chars, index, index + 2)
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                _mask_range(chars, index, index + 2)
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "normal"
            else:
                if source[index] not in "\r\n":
                    chars[index] = " "
                index += 1
            continue

        if state == "raw-string":
            if source.startswith(string_end, index):
                _mask_range(chars, index, index + len(string_end))
                index += len(string_end)
                state = "normal"
            else:
                if source[index] not in "\r\n":
                    chars[index] = " "
                index += 1
            continue

        # Regular and multiline strings.  For a multiline string, the same
        # state also handles embedded newlines because they remain unmasked.
        if source.startswith(string_end, index):
            _mask_range(chars, index, index + len(string_end))
            index += len(string_end)
            state = "normal"
        elif source[index] == "\\" and string_end == '"':
            _mask_range(chars, index, index + 2)
            index += 2
        else:
            if source[index] not in "\r\n":
                chars[index] = " "
            index += 1

    return "".join(chars)


def _diagnose_source(relative_path: str, source: str) -> list[str]:
    masked = _mask_comments_and_strings(source)
    diagnostics: list[tuple[int, int, str]] = []
    for line_number, line in enumerate(masked.splitlines(), start=1):
        import_match = _IMPORT_RE.match(line)
        if import_match:
            module = import_match.group("module").split(".", 1)[0]
            if module in _FORBIDDEN_IMPORT_SET:
                diagnostics.append(
                    (
                        line_number,
                        import_match.start("module") + 1,
                        f"forbidden import {module}",
                    )
                )

    for pattern, label in (
        (_PROCESS_RE, "forbidden Process API"),
        (_FILE_MANAGER_DEFAULT_RE, "forbidden FileManager.default API"),
        (_URL_SESSION_SHARED_RE, "forbidden URLSession.shared API"),
    ):
        for match in pattern.finditer(masked):
            line_number = masked.count("\n", 0, match.start()) + 1
            previous_newline = masked.rfind("\n", 0, match.start())
            column = match.start() - previous_newline
            diagnostics.append((line_number, column, label))

    return [
        f"{relative_path}:{line}:{column}: {message}"
        for line, column, message in sorted(diagnostics, key=lambda item: item[:2] + (item[2],))
    ]


def _swift_sources(source_root: Path) -> Iterable[Path]:
    if not source_root.is_dir():
        return ()
    return sorted(
        (path for path in source_root.rglob("*.swift") if path.is_file()),
        key=lambda path: path.as_posix(),
    )


def check(root: Path) -> list[str]:
    """Return stable boundary diagnostics for a repository root."""

    root = root.resolve()
    source_root = root / "swift" / "Sources" / "RepoPressCore"
    if not source_root.is_dir():
        return ["swift/Sources/RepoPressCore: source directory is missing"]

    diagnostics: list[str] = []
    for path in _swift_sources(source_root):
        relative = path.relative_to(root).as_posix()
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            diagnostics.append(f"{relative}: cannot read Swift source ({exc})")
            continue
        diagnostics.extend(_diagnose_source(relative, source))
    return sorted(set(diagnostics))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the parent of scripts/)",
    )
    args = parser.parse_args(argv)
    diagnostics = check(args.root)
    if diagnostics:
        print("Swift Core boundary check failed:", file=sys.stderr)
        for diagnostic in diagnostics:
            print(f"- {diagnostic}", file=sys.stderr)
        return 1
    print("Swift Core boundary check passed")
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised by CI command
    raise SystemExit(main())
