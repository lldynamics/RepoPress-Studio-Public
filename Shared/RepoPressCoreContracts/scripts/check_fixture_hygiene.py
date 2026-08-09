#!/usr/bin/env python3
"""Reject credentials, machine-local paths, test hosts, and symlinks in contracts."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable, Sequence


_LOCAL_PATH_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"(?i)(?:file://)?/(?:Users|Volumes|private|tmp|var/folders)(?:/|$)"), "local absolute path"),
    (re.compile(r"(?i)(?:^|[\s\"'])(?:[A-Za-z]:[\\/]|\\\\)[^\s\"']+"), "Windows local path"),
)

_SECRET_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----"), "private key material"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"), "GitHub token"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), "GitHub token"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"), "Slack token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(r"\b(?:sk|rk|pk)-[A-Za-z0-9_-]{20,}\b"), "API token"),
    (re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{24,}\b"), "bearer token"),
    (
        re.compile(
            r"(?i)\b(?:api[_-]?key|access[_-]?token|secret[_-]?key|private[_-]?key)"
            r"\s*[:=]\s*[\"']?[A-Za-z0-9._~+/=-]{20,}"
        ),
        "credential assignment",
    ),
)

_URL_PATTERN = re.compile(
    r"(?i)\b(?:https?|ssh|git)://(?P<authority>[^\s/]+)"
)
_OBVIOUS_TEST_HOST = re.compile(
    r"(?i)^(?:localhost|127\.0\.0\.1|0\.0\.0\.0|::1|test|testing|mock|fake|dummy)(?:\.|$)"
)


class _DuplicateKey(ValueError):
    pass


def _pairs_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKey(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _parse_constant(value: str) -> None:
    raise ValueError(value)


def _scalar_strings(value: Any, path: str = "") -> Iterable[tuple[str, str]]:
    """Yield string values, retaining the JSON key path for stable diagnostics.

    Key names themselves are deliberately not scanned.  A normal expected field
    named ``token`` or ``privateKey`` is not a credential; only a high-confidence
    secret-looking scalar value should fail this gate.
    """

    if isinstance(value, str):
        yield path or "$", value
    elif isinstance(value, dict):
        for key in sorted(value):
            child = f"{path}.{key}" if path else key
            yield from _scalar_strings(value[key], child)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _scalar_strings(item, f"{path}[{index}]")


def _relative(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def _host_from_authority(authority: str) -> str:
    without_user = authority.rsplit("@", 1)[-1]
    if without_user.startswith("["):
        closing = without_user.find("]")
        return without_user[1:closing] if closing >= 0 else without_user
    return without_user.split(":", 1)[0]


def _is_obvious_non_example_test_host(host: str) -> bool:
    host = host.rstrip(".").lower()
    if host == "example.test" or host.endswith(".example.test"):
        return False
    if host in {"localhost", "127.0.0.1", "0.0.0.0", "::1"}:
        return True
    if host.endswith((".local", ".localhost", ".invalid", ".test")):
        return True
    return bool(_OBVIOUS_TEST_HOST.match(host))


def _scan_string(value: str) -> list[str]:
    findings: list[str] = []
    for pattern, label in _LOCAL_PATH_PATTERNS:
        if pattern.search(value):
            findings.append(label)
    for pattern, label in _SECRET_PATTERNS:
        if pattern.search(value):
            findings.append(label)
    for match in _URL_PATTERN.finditer(value):
        host = _host_from_authority(match.group("authority"))
        if _is_obvious_non_example_test_host(host):
            findings.append(f"non-example.test test host ({host})")
    return findings


def _iter_contract_files(contracts_root: Path) -> Iterable[Path]:
    if not contracts_root.exists():
        return ()
    return sorted(
        (path for path in contracts_root.rglob("*") if path.is_file()),
        key=lambda path: path.as_posix(),
    )


def check(root: Path) -> list[str]:
    """Return sorted hygiene diagnostics for ``root``."""

    root = root.resolve()
    contracts_root = root / "contracts"
    findings: list[str] = []
    if not contracts_root.is_dir():
        return ["contracts: directory is missing"]

    for path in sorted(contracts_root.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            findings.append(f"{_relative(path, root)}: symlinks are not allowed")

    for path in _iter_contract_files(contracts_root):
        relative = _relative(path, root)
        if path.suffix.lower() != ".json":
            continue
        text = ""
        try:
            text = path.read_text(encoding="utf-8")
            parsed = json.loads(
                text,
                object_pairs_hook=_pairs_without_duplicates,
                parse_constant=_parse_constant,
            )
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
            # validate_contracts.py owns parse/encoding diagnostics.  The hygiene
            # gate still scans raw text below, so a malformed fixture cannot hide
            # a credential or machine-local path.
            parsed = None

        values = _scalar_strings(parsed) if parsed is not None else [("$", text)]
        for value_path, value in values:
            for label in sorted(set(_scan_string(value))):
                findings.append(f"{relative}:{value_path}: {label}")

    return sorted(set(findings))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the parent of scripts/)",
    )
    args = parser.parse_args(argv)
    findings = check(args.root)
    if findings:
        print("fixture hygiene check failed:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1
    print("fixture hygiene check passed")
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised by the workflow command
    raise SystemExit(main())
