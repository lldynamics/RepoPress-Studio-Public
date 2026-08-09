#!/usr/bin/env python3
"""Enforce the platform-neutral boundary of the RepoPress C# Core target."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable, Sequence


FORBIDDEN_USING_ROOTS: tuple[str, ...] = (
    "System.Windows",
    "Microsoft.UI",
    "Windows",
    "WinUI",
    "Microsoft.Win32",
    "System.IO",
    "System.Net.Http",
)

_USING_RE = re.compile(
    r"^\s*(?:(?:global)\s+)?using\s+(?:(?:static)\s+)?"
    r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*=\s*)?"
    r"(?P<namespace>[A-Za-z_][A-Za-z0-9_.]*)\s*;"
)
_FORBIDDEN_QUALIFIED_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(r"\b(?:global::)?(?:System\s*\.\s*)?Windows\b"),
        "forbidden Windows API/namespace",
    ),
    (
        re.compile(r"\b(?:global::)?Microsoft\s*\.\s*UI\b"),
        "forbidden WinUI API/namespace",
    ),
    (
        re.compile(r"\b(?:global::)?WinUI\b"),
        "forbidden WinUI API/namespace",
    ),
    (
        re.compile(r"\b(?:global::)?Microsoft\s*\.\s*Win32\b"),
        "forbidden Windows Registry API/namespace",
    ),
    (
        re.compile(r"\b(?:global::)?System\s*\.\s*IO\b"),
        "forbidden System.IO API/namespace",
    ),
    (
        re.compile(r"\b(?:global::)?System\s*\.\s*Net\s*\.\s*Http\b"),
        "forbidden System.Net.Http API/namespace",
    ),
    (re.compile(r"\bHttpClient\b"), "forbidden HttpClient API"),
    (re.compile(r"\bRegistry\b"), "forbidden Registry API"),
    (re.compile(r"\bProcess\b"), "forbidden Process API"),
    (re.compile(r"\bProtectedData\b"), "forbidden ProtectedData API"),
    (
        re.compile(
            r"\b(?:global::)?(?:System\s*\.\s*)?Environment\s*\.\s*GetFolderPath\b"
        ),
        "forbidden Environment.GetFolderPath API",
    ),
)


def _mask_range(chars: list[str], start: int, end: int) -> None:
    for index in range(start, min(end, len(chars))):
        if chars[index] not in "\r\n":
            chars[index] = " "


def _quote_run(source: str, index: int) -> int:
    cursor = index
    while cursor < len(source) and source[cursor] == '"':
        cursor += 1
    return cursor - index


def _string_opening(source: str, index: int) -> tuple[str, int, str] | None:
    """Recognize ordinary, verbatim, interpolated, and raw C# strings."""

    if source[index] == "'":
        return "char", 1, "'"

    if source[index] == '"':
        quotes = _quote_run(source, index)
        if quotes >= 3:
            return "raw", quotes, '"' * quotes
        return "string", 1, '"'

    cursor = index
    while cursor < len(source) and source[cursor] == "$":
        cursor += 1
    if cursor > index:
        if source.startswith('@"', cursor):
            # Include both the `@` and opening quote after any `$` prefix.
            return "verbatim", cursor - index + 2, '"'
        quotes = _quote_run(source, cursor)
        if quotes >= 3:
            return "raw", cursor - index + quotes, '"' * quotes
        if quotes == 1:
            return "string", cursor - index + 1, '"'

    if source.startswith('@$', index) or source.startswith('$@', index):
        return "verbatim", 3, '"'
    if source.startswith('@"', index):
        return "verbatim", 2, '"'
    return None


def _mask_comments_and_strings(source: str) -> str:
    """Mask comments and C# literals while retaining line boundaries."""

    chars = list(source)
    index = 0
    state = "normal"
    closing = ""
    while index < len(source):
        if state == "normal":
            if source.startswith("//", index):
                _mask_range(chars, index, index + 2)
                index += 2
                state = "line-comment"
                continue
            if source.startswith("/*", index):
                _mask_range(chars, index, index + 2)
                index += 2
                state = "block-comment"
                continue
            opening = _string_opening(source, index)
            if opening is not None:
                state, opening_length, closing = opening
                _mask_range(chars, index, index + opening_length)
                index += opening_length
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
            if source.startswith("*/", index):
                _mask_range(chars, index, index + 2)
                index += 2
                state = "normal"
            else:
                if source[index] not in "\r\n":
                    chars[index] = " "
                index += 1
            continue

        if state == "raw":
            if source.startswith(closing, index):
                _mask_range(chars, index, index + len(closing))
                index += len(closing)
                state = "normal"
            else:
                if source[index] not in "\r\n":
                    chars[index] = " "
                index += 1
            continue

        if state == "verbatim":
            if source.startswith('""', index):
                _mask_range(chars, index, index + 2)
                index += 2
            elif source[index] == '"':
                _mask_range(chars, index, index + 1)
                index += 1
                state = "normal"
            else:
                if source[index] not in "\r\n":
                    chars[index] = " "
                index += 1
            continue

        # Ordinary strings and character literals.
        if source.startswith(closing, index):
            _mask_range(chars, index, index + len(closing))
            index += len(closing)
            state = "normal"
        elif source[index] == "\\":
            _mask_range(chars, index, index + 2)
            index += 2
        else:
            if source[index] not in "\r\n":
                chars[index] = " "
            index += 1

    return "".join(chars)


def _forbidden_using(namespace: str) -> str | None:
    if namespace == "System.Diagnostics.Process" or namespace.startswith(
        "System.Diagnostics.Process."
    ):
        return "forbidden Process using"
    if namespace == "System.Security.Cryptography.ProtectedData" or namespace.startswith(
        "System.Security.Cryptography.ProtectedData."
    ):
        return "forbidden ProtectedData using"
    if namespace == "System.Environment" or namespace.startswith(
        "System.Environment."
    ):
        return "forbidden Environment using"
    for root in FORBIDDEN_USING_ROOTS:
        if namespace == root or namespace.startswith(root + "."):
            if root == "System.IO":
                return "forbidden System.IO using"
            if root == "System.Net.Http":
                return "forbidden System.Net.Http using"
            if root in {"System.Windows", "Windows", "Microsoft.Win32"}:
                return "forbidden Windows API using"
            return f"forbidden {root} using"
    return None


def _diagnose_source(relative_path: str, source: str) -> list[str]:
    masked = _mask_comments_and_strings(source)
    diagnostics: list[tuple[int, int, str]] = []
    using_ranges: list[tuple[int, int]] = []

    offset = 0
    for line_number, line in enumerate(masked.splitlines(keepends=True), start=1):
        line_without_newline = line.rstrip("\r\n")
        match = _USING_RE.match(line_without_newline)
        if match:
            using_ranges.append((offset, offset + len(line_without_newline)))
            message = _forbidden_using(match.group("namespace"))
            if message:
                diagnostics.append((line_number, match.start("namespace") + 1, message))
        offset += len(line)

    def in_using_range(position: int) -> bool:
        return any(start <= position < end for start, end in using_ranges)

    for pattern, label in _FORBIDDEN_QUALIFIED_PATTERNS:
        for match in pattern.finditer(masked):
            # A forbidden using already has a more precise diagnostic; avoid
            # reporting the same namespace a second time on its import line.
            if in_using_range(match.start()):
                continue
            line_number = masked.count("\n", 0, match.start()) + 1
            previous_newline = masked.rfind("\n", 0, match.start())
            column = match.start() - previous_newline
            diagnostics.append((line_number, column, label))

    return [
        f"{relative_path}:{line}:{column}: {message}"
        for line, column, message in sorted(diagnostics, key=lambda item: item[:2] + (item[2],))
    ]


def _csharp_sources(source_root: Path) -> Iterable[Path]:
    if not source_root.is_dir():
        return ()
    return sorted(
        (path for path in source_root.rglob("*.cs") if path.is_file()),
        key=lambda path: path.as_posix(),
    )


def check(root: Path) -> list[str]:
    """Return stable C# Core boundary diagnostics for a repository root."""

    root = root.resolve()
    source_root = root / "dotnet" / "src" / "RepoPress.Core"
    if not source_root.is_dir():
        return ["dotnet/src/RepoPress.Core: source directory is missing"]

    diagnostics: list[str] = []
    for path in _csharp_sources(source_root):
        relative = path.relative_to(root).as_posix()
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            # Keep the diagnostic stable across operating systems and Python
            # versions; the path is enough to identify the offending source.
            diagnostics.append(f"{relative}: cannot read C# source")
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
        print(".NET Core boundary check failed:", file=sys.stderr)
        for diagnostic in diagnostics:
            print(f"- {diagnostic}", file=sys.stderr)
        return 1
    print(".NET Core boundary check passed")
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised by CI command
    raise SystemExit(main())
