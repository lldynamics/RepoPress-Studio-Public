#!/usr/bin/env python3
"""Shared schema and offline-diff helpers for Swift quality gates."""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, NamedTuple


class QualityGateError(ValueError):
    """A deterministic gate configuration or local repository error."""


class ResolvedDiffBase(NamedTuple):
    """Requested and concrete commits used by changed-line quality gates."""

    requested: str
    resolved: str
    source: str
    used_all_zero_fallback: bool


ZERO_GIT_OBJECT_ID = re.compile(r"(?:0{40}|0{64})")


def _number(value: Any, field: str, *, positive: bool = False) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise QualityGateError(f"{field} must be a number")
    result = float(value)
    if not (0 <= result <= 100) or (positive and result <= 0):
        qualifier = "from 0 through 100" if not positive else "greater than 0 through 100"
        raise QualityGateError(f"{field} must be {qualifier}")
    return result


def _warning_map(value: Any, field: str, *, allow_empty: bool = False) -> dict[str, int]:
    if not isinstance(value, dict) or (not value and not allow_empty):
        qualifier = "an object" if allow_empty else "a non-empty object"
        raise QualityGateError(f"{field} must be {qualifier}")
    result: dict[str, int] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not key:
            raise QualityGateError(f"{field} keys must be non-empty strings")
        if not isinstance(item, int) or isinstance(item, bool) or item < 0:
            raise QualityGateError(f"{field}.{key} must be a non-negative integer")
        result[key] = item
    return result


def load_quality_baseline(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise QualityGateError(f"cannot load quality baseline: {error}") from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 2:
        raise QualityGateError("quality baseline schemaVersion must be exactly 2")

    legacy_format_maximum = payload.get("swiftFormatWarningMaximum")
    if legacy_format_maximum is not None and (
        not isinstance(legacy_format_maximum, int)
        or isinstance(legacy_format_maximum, bool)
        or legacy_format_maximum < 0
    ):
        raise QualityGateError("swiftFormatWarningMaximum must be a non-negative integer when present")

    _number(payload.get("sourceLineCoveragePercentMinimum"), "sourceLineCoveragePercentMinimum")
    target_minimums = payload.get("sourceLineCoveragePercentMinimumByTarget")
    if not isinstance(target_minimums, dict) or not target_minimums:
        raise QualityGateError("sourceLineCoveragePercentMinimumByTarget must be a non-empty object")
    for target, minimum in target_minimums.items():
        if not isinstance(target, str) or not target:
            raise QualityGateError("sourceLineCoveragePercentMinimumByTarget keys must be non-empty strings")
        _number(minimum, f"sourceLineCoveragePercentMinimumByTarget.{target}", positive=True)
    _number(
        payload.get("changedExecutableSourceLineCoveragePercentMinimum"),
        "changedExecutableSourceLineCoveragePercentMinimum",
    )

    format_maximums = payload.get("swiftFormatWarningMaximums")
    if not isinstance(format_maximums, dict):
        raise QualityGateError("swiftFormatWarningMaximums must be an object")
    _warning_map(format_maximums.get("sourcesByTarget"), "swiftFormatWarningMaximums.sourcesByTarget")
    _warning_map(
        format_maximums.get("testsByTarget"),
        "swiftFormatWarningMaximums.testsByTarget",
        allow_empty=True,
    )
    for field in ("packageSwift", "changedLines"):
        value = format_maximums.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise QualityGateError(f"swiftFormatWarningMaximums.{field} must be a non-negative integer")
    return payload


def validate_target_mapping(
    mapping: dict[str, Any], expected_targets: set[str], field: str
) -> None:
    actual_targets = set(mapping)
    if actual_targets != expected_targets:
        missing = sorted(expected_targets - actual_targets)
        extra = sorted(actual_targets - expected_targets)
        detail = []
        if missing:
            detail.append(f"missing {', '.join(missing)}")
        if extra:
            detail.append(f"unknown {', '.join(extra)}")
        raise QualityGateError(f"{field} must map exactly the repository targets ({'; '.join(detail)})")


def target_directories(root: Path, parent: str) -> set[str]:
    directory = root / parent
    if not directory.is_dir():
        return set()
    return {
        child.name
        for child in directory.iterdir()
        if child.is_dir() and any(path.is_file() for path in child.rglob("*.swift"))
    }


def parse_unified_zero_diff(output: str) -> dict[str, set[int]]:
    """Return added new-side lines from a `git diff --unified=0` stream."""
    result: dict[str, set[int]] = {}
    current_path: str | None = None
    header = None
    import re

    header = re.compile(r"^\+\+\+ b/(.+)$")
    hunk = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
    for raw_line in output.splitlines():
        path_match = header.match(raw_line)
        if path_match:
            current_path = path_match.group(1)
            continue
        hunk_match = hunk.match(raw_line)
        if not hunk_match or current_path is None:
            continue
        start = int(hunk_match.group(1))
        count = int(hunk_match.group(2) or "1")
        if count:
            result.setdefault(current_path, set()).update(range(start, start + count))
    return result


def _git(root: Path, arguments: list[str]) -> str:
    try:
        completed = subprocess.run(
            ["git", *arguments], cwd=root, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False,
        )
    except OSError as error:
        raise QualityGateError(f"git is unavailable for changed-line quality checks: {error}") from error
    if completed.returncode:
        message = completed.stderr.strip() or "unknown git error"
        raise QualityGateError(message)
    return completed.stdout


def resolve_diff_base(root: Path, diff_base: str | None = None) -> ResolvedDiffBase:
    """Resolve a local comparison commit, normalizing tag-creation zero SHAs."""
    if diff_base:
        requested = diff_base
        if os.environ.get("QUALITY_DIFF_BASE") == diff_base:
            source = "QUALITY_DIFF_BASE"
        elif os.environ.get("GITHUB_BASE_REF") == diff_base:
            source = "GITHUB_BASE_REF"
        else:
            source = "explicit diff base"
    elif os.environ.get("QUALITY_DIFF_BASE"):
        requested = os.environ["QUALITY_DIFF_BASE"]
        source = "QUALITY_DIFF_BASE"
    elif os.environ.get("GITHUB_BASE_REF"):
        requested = os.environ["GITHUB_BASE_REF"]
        source = "GITHUB_BASE_REF"
    else:
        requested = "HEAD"
        source = "HEAD"

    used_all_zero_fallback = ZERO_GIT_OBJECT_ID.fullmatch(requested) is not None
    candidate = "HEAD^" if used_all_zero_fallback else requested
    try:
        resolved = _git(
            root,
            ["rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}"],
        ).strip()
    except QualityGateError as error:
        fallback = " (all-zero SHA fallback HEAD^ was unavailable)" if used_all_zero_fallback else ""
        raise QualityGateError(
            f"invalid {source} for changed-line quality checks: {requested}{fallback} ({error})"
        ) from error
    return ResolvedDiffBase(requested, resolved, source, used_all_zero_fallback)


def changed_lines(root: Path, diff_base: str | None = None) -> dict[str, set[int]]:
    """Collect local changed lines, including untracked Swift files, without network access."""
    resolved = resolve_diff_base(root, diff_base)
    diff = _git(
        root,
        ["diff", "--no-ext-diff", "--unified=0", "--find-renames=0", resolved.resolved, "--"],
    )
    result = parse_unified_zero_diff(diff)
    for relative in _git(root, ["ls-files", "--others", "--exclude-standard"]).splitlines():
        if not (relative.endswith(".swift") or relative == "Package.swift"):
            continue
        path = root / relative
        try:
            line_count = len(path.read_text(encoding="utf-8").splitlines())
        except OSError as error:
            raise QualityGateError(f"cannot read untracked changed file {relative}: {error}") from error
        if line_count:
            result.setdefault(relative, set()).update(range(1, line_count + 1))
    return result
