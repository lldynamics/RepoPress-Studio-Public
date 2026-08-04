#!/usr/bin/env python3
"""Reject unreviewed Swift force operations and @unchecked Sendable declarations."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_EXCEPTIONS = ROOT / "script" / "swift_safety_exceptions.json"
SWIFT_ROOTS = ("Sources", "Tests", "script")
DECLARATION_RE = re.compile(
    r"\b(?:class|struct|actor|enum|extension)\s+"
    r"([A-Za-z_][A-Za-z0-9_.]*)[^{};]*?@unchecked\s+Sendable",
    re.MULTILINE,
)
FORCED_OPERATION_RE = re.compile(r"\b(?:try!|as!)")


@dataclass(frozen=True)
class Finding:
    file: str
    line: int
    kind: str
    identity: str
    source: str


def fail(message: str) -> None:
    print(f"swift safety gate: {message}", file=sys.stderr)
    raise SystemExit(1)


def swift_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for relative_root in SWIFT_ROOTS:
        directory = root / relative_root
        if directory.is_dir():
            paths.extend(directory.rglob("*.swift"))
    return sorted(path for path in paths if ".build" not in path.parts)


def mask_comments_and_strings(source: str) -> str:
    """Mask comments and string text, but keep executable interpolation expressions."""
    masked = list(source)
    index = 0
    block_depth = 0
    string_delimiter: str | None = None
    raw_hashes = 0
    interpolation_stack: list[tuple[str, int, int]] = []
    while index < len(source):
        if block_depth:
            if source.startswith("/*", index):
                masked[index : index + 2] = "  "
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                masked[index : index + 2] = "  "
                block_depth -= 1
                index += 2
            else:
                if source[index] != "\n":
                    masked[index] = " "
                index += 1
            continue
        if string_delimiter is not None:
            terminator = string_delimiter + ("#" * raw_hashes)
            interpolation_opener = "\\" + ("#" * raw_hashes) + "("
            if source.startswith(terminator, index):
                for offset in range(len(terminator)):
                    masked[index + offset] = " "
                index += len(terminator)
                string_delimiter = None
                raw_hashes = 0
            elif source.startswith(interpolation_opener, index):
                for offset in range(len(interpolation_opener)):
                    masked[index + offset] = " "
                interpolation_stack.append((string_delimiter, raw_hashes, 1))
                index += len(interpolation_opener)
                string_delimiter = None
                raw_hashes = 0
            elif raw_hashes == 0 and source[index] == "\\":
                masked[index] = " "
                if index + 1 < len(source):
                    if source[index + 1] != "\n":
                        masked[index + 1] = " "
                    index += 2
                else:
                    index += 1
            else:
                if source[index] != "\n":
                    masked[index] = " "
                index += 1
            continue
        if source.startswith("//", index):
            end = source.find("\n", index)
            if end == -1:
                end = len(source)
            for offset in range(index, end):
                masked[offset] = " "
            index = end
            continue
        if source.startswith("/*", index):
            masked[index : index + 2] = "  "
            block_depth = 1
            index += 2
            continue

        if interpolation_stack:
            delimiter, hashes, depth = interpolation_stack[-1]
            if source[index] == "(":
                interpolation_stack[-1] = (delimiter, hashes, depth + 1)
                index += 1
                continue
            if source[index] == ")":
                if depth == 1:
                    masked[index] = " "
                    interpolation_stack.pop()
                    string_delimiter = delimiter
                    raw_hashes = hashes
                else:
                    interpolation_stack[-1] = (delimiter, hashes, depth - 1)
                index += 1
                continue

        raw_match = re.match(r'(#+)(""")', source[index:]) or re.match(r'(#+)(")', source[index:])
        if raw_match:
            raw_hashes = len(raw_match.group(1))
            string_delimiter = raw_match.group(2)
            opening_length = raw_hashes + len(string_delimiter)
            for offset in range(opening_length):
                masked[index + offset] = " "
            index += opening_length
            continue
        if source.startswith('"""', index):
            string_delimiter = '"""'
            masked[index : index + 3] = "   "
            index += 3
            continue
        if source[index] == '"':
            string_delimiter = '"'
            masked[index] = " "
            index += 1
            continue
        index += 1
    return "".join(masked)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def scan(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in swift_files(root):
        relative = path.relative_to(root).as_posix()
        source = path.read_text(encoding="utf-8")
        masked = mask_comments_and_strings(source)
        source_lines = source.splitlines()
        for declaration in DECLARATION_RE.finditer(masked):
            unchecked_offset = masked.find("@unchecked", declaration.start(), declaration.end())
            finding_line = line_number(source, unchecked_offset)
            line_source = source_lines[finding_line - 1].strip()
            findings.append(
                Finding(
                    relative,
                    finding_line,
                    "@unchecked Sendable",
                    declaration.group(1),
                    line_source,
                )
            )
        for operation in FORCED_OPERATION_RE.finditer(masked):
            finding_line = line_number(source, operation.start())
            line_source = source_lines[finding_line - 1].strip()
            findings.append(
                Finding(relative, finding_line, operation.group(0), line_source, line_source)
            )
    return findings


def load_exceptions(path: Path) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load exception manifest {path}: {error}")
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        fail("exception manifest must be a schemaVersion 1 object")
    for key in ("uncheckedSendable", "forcedOperations"):
        if not isinstance(payload.get(key), list):
            fail(f"exception manifest field {key} must be a list")
    return payload


def validated_exception_keys(payload: dict[str, object]) -> tuple[dict[tuple[str, str], str], dict[tuple[str, str, str], str]]:
    unchecked: dict[tuple[str, str], str] = {}
    for item in payload["uncheckedSendable"]:
        if not isinstance(item, dict):
            fail("uncheckedSendable entries must be objects")
        file = item.get("file")
        declaration = item.get("declaration")
        rationale = item.get("rationale")
        if not all(isinstance(value, str) and value.strip() for value in (file, declaration, rationale)):
            fail("each uncheckedSendable exception requires file, declaration, and rationale")
        key = (file, declaration)
        if key in unchecked:
            fail(f"duplicate @unchecked Sendable exception: {file}:{declaration}")
        unchecked[key] = rationale

    forced: dict[tuple[str, str, str], str] = {}
    for item in payload["forcedOperations"]:
        if not isinstance(item, dict):
            fail("forcedOperations entries must be objects")
        file = item.get("file")
        kind = item.get("kind")
        contains = item.get("contains")
        rationale = item.get("rationale")
        if kind not in {"try!", "as!"}:
            fail(f"invalid forced operation kind: {kind}")
        if not all(isinstance(value, str) and value.strip() for value in (file, contains, rationale)):
            fail("each forcedOperations exception requires file, kind, contains, and rationale")
        key = (file, kind, contains)
        if key in forced:
            fail(f"duplicate forced-operation exception: {file}:{kind}:{contains}")
        forced[key] = rationale
    return unchecked, forced


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--exceptions", type=Path, default=DEFAULT_EXCEPTIONS)
    args = parser.parse_args()
    root = args.root.resolve()
    findings = scan(root)
    unchecked_exceptions, forced_exceptions = validated_exception_keys(load_exceptions(args.exceptions))

    used_unchecked: set[tuple[str, str]] = set()
    used_forced: set[tuple[str, str, str]] = set()
    violations: list[Finding] = []
    for finding in findings:
        if finding.kind == "@unchecked Sendable":
            key = (finding.file, finding.identity)
            if key in unchecked_exceptions:
                used_unchecked.add(key)
            else:
                violations.append(finding)
            continue
        matching = [
            key
            for key in forced_exceptions
            if key[0] == finding.file and key[1] == finding.kind and key[2] in finding.source
        ]
        if len(matching) == 1:
            used_forced.add(matching[0])
        else:
            violations.append(finding)

    stale_unchecked = sorted(set(unchecked_exceptions) - used_unchecked)
    stale_forced = sorted(set(forced_exceptions) - used_forced)
    if violations:
        for finding in violations:
            print(
                f"{finding.file}:{finding.line}: unreviewed {finding.kind}: {finding.source}",
                file=sys.stderr,
            )
        fail(
            "new force operations or @unchecked Sendable declarations require a narrow, reviewed rationale "
            "in script/swift_safety_exceptions.json"
        )
    if stale_unchecked or stale_forced:
        for file, declaration in stale_unchecked:
            print(f"stale @unchecked Sendable exception: {file}:{declaration}", file=sys.stderr)
        for file, kind, contains in stale_forced:
            print(f"stale forced-operation exception: {file}:{kind}:{contains}", file=sys.stderr)
        fail("remove or update stale exception entries")

    unchecked_count = sum(1 for finding in findings if finding.kind == "@unchecked Sendable")
    production_unchecked_count = sum(
        1
        for finding in findings
        if finding.kind == "@unchecked Sendable" and finding.file.startswith("Sources/")
    )
    try_count = sum(1 for finding in findings if finding.kind == "try!")
    cast_count = sum(1 for finding in findings if finding.kind == "as!")
    print(
        "swift safety gate: passed "
        f"({production_unchecked_count} production and "
        f"{unchecked_count - production_unchecked_count} test audited @unchecked Sendable, "
        f"{try_count} audited try!, "
        f"{cast_count} audited as!; no unreviewed additions)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
