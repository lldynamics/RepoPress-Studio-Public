#!/usr/bin/env python3
"""Reject quality-baseline changes that silently relax enforced thresholds."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from quality_gate_common import QualityGateError, load_quality_baseline, resolve_diff_base


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BASELINE = Path("script/quality_baselines.json")


def fail(message: str) -> None:
    raise QualityGateError(message)


def git(root: Path, *arguments: str) -> str:
    try:
        completed = subprocess.run(
            ["git", *arguments],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        fail(f"[repository:git-unavailable] git is unavailable: {error}")
    if completed.returncode:
        detail = completed.stderr.strip() or "unknown git error"
        fail(f"[repository:invalid-diff-base] {detail}")
    return completed.stdout


def load_json_bytes(raw: str, description: str) -> dict[str, Any]:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        fail(f"[configuration:invalid-baseline] cannot parse {description}: {error}")
    if not isinstance(payload, dict):
        fail(f"[configuration:invalid-baseline] {description} must be a JSON object")
    return payload


def positive_test_minimums(payload: dict[str, Any], description: str) -> dict[str, int]:
    mapping = payload.get("swiftTestMinimumCountsByTarget")
    if not isinstance(mapping, dict) or not mapping:
        fail(f"[configuration:invalid-baseline] {description}.swiftTestMinimumCountsByTarget must be a non-empty object")
    result: dict[str, int] = {}
    for target, value in mapping.items():
        if not isinstance(target, str) or not target:
            fail(f"[configuration:invalid-baseline] {description} test target names must be non-empty strings")
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            fail(f"[configuration:invalid-baseline] {description}.{target} must be a positive integer")
        result[target] = value
    return result


def format_buckets(payload: dict[str, Any], description: str) -> dict[str, int]:
    maximums = payload.get("swiftFormatWarningMaximums")
    if not isinstance(maximums, dict):
        fail(f"[configuration:invalid-baseline] {description}.swiftFormatWarningMaximums must be an object")
    result: dict[str, int] = {}
    for group in ("sourcesByTarget", "testsByTarget"):
        mapping = maximums.get(group)
        if not isinstance(mapping, dict):
            fail(f"[configuration:invalid-baseline] {description}.swiftFormatWarningMaximums.{group} must be an object")
        for target, value in mapping.items():
            if not isinstance(target, str) or not target:
                fail(f"[configuration:invalid-baseline] {description} format target names must be non-empty strings")
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                fail(f"[configuration:invalid-baseline] {description} format maximum {group}.{target} must be non-negative")
            result[f"{group}.{target}"] = value
    for name in ("packageSwift", "changedLines"):
        value = maximums.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            fail(f"[configuration:invalid-baseline] {description} format maximum {name} must be non-negative")
        result[name] = value
    return result


def v1_baseline(payload: dict[str, Any]) -> tuple[float, int, dict[str, int]]:
    if payload.get("schemaVersion") != 1:
        fail("[configuration:invalid-base-schema] base quality baseline must use schemaVersion 1 or 2")
    coverage = payload.get("sourceLineCoveragePercentMinimum")
    warning_maximum = payload.get("swiftFormatWarningMaximum")
    if not isinstance(coverage, (int, float)) or isinstance(coverage, bool) or not 0 <= float(coverage) <= 100:
        fail("[configuration:invalid-baseline] base sourceLineCoveragePercentMinimum must be 0 through 100")
    if not isinstance(warning_maximum, int) or isinstance(warning_maximum, bool) or warning_maximum < 0:
        fail("[configuration:invalid-baseline] base swiftFormatWarningMaximum must be a non-negative integer")
    return float(coverage), warning_maximum, positive_test_minimums(payload, "base quality baseline")


def compare_no_decrease(label: str, current: float | int, base: float | int) -> None:
    if current < base:
        fail(f"[policy:threshold-relaxed] {label} decreased from {base} to {current}")


def compare_no_increase(label: str, current: int, base: int) -> None:
    if current > base:
        fail(f"[policy:threshold-relaxed] {label} increased from {base} to {current}")


def compare_target_minimums(current: dict[str, Any], base: dict[str, Any]) -> None:
    for target, base_value in base.items():
        if target not in current:
            fail(f"[policy:threshold-relaxed] source coverage target baseline was removed: {target}")
        compare_no_decrease(
            f"source coverage target {target}", float(current[target]), float(base_value)
        )
    for target, current_value in current.items():
        if target not in base and float(current_value) <= 0:
            fail(f"[configuration:invalid-baseline] new source coverage target {target} must have a positive baseline")


def compare_test_minimums(current: dict[str, int], base: dict[str, int]) -> None:
    for target, base_value in base.items():
        if target not in current:
            fail(f"[policy:threshold-relaxed] Swift test target baseline was removed: {target}")
        compare_no_decrease(f"Swift test target {target}", current[target], base_value)


def compare_format(current: dict[str, int], base: dict[str, int]) -> None:
    for bucket, base_value in base.items():
        if bucket not in current:
            fail(f"[policy:threshold-relaxed] Swift format bucket was removed: {bucket}")
        compare_no_increase(f"Swift format maximum {bucket}", current[bucket], base_value)
    compare_no_increase(
        "Swift format total maximum",
        sum(current.values()),
        sum(base.values()),
    )
    if current["changedLines"] != 0:
        fail("[policy:threshold-relaxed] Swift format changedLines maximum must remain 0")


def enforce(root: Path, baseline_path: Path, requested_base: str | None) -> str:
    current = load_quality_baseline(baseline_path)
    current_tests = positive_test_minimums(current, "current quality baseline")
    current_format = format_buckets(current, "current quality baseline")
    current_target_coverage = current["sourceLineCoveragePercentMinimumByTarget"]
    assert isinstance(current_target_coverage, dict)
    if float(current["changedExecutableSourceLineCoveragePercentMinimum"]) != 100:
        fail("[policy:threshold-relaxed] changed executable source coverage minimum must remain 100")
    if current_format["changedLines"] != 0:
        fail("[policy:threshold-relaxed] Swift format changedLines maximum must remain 0")

    try:
        diff_base = resolve_diff_base(root, requested_base)
    except QualityGateError as error:
        raise QualityGateError(f"[repository:invalid-diff-base] {error}") from error
    resolved_base = diff_base.resolved
    try:
        relative = baseline_path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        fail("[configuration:invalid-baseline] baseline path must be inside the repository root")
    try:
        base_text = git(root, "show", f"{resolved_base}:{relative}")
    except QualityGateError as error:
        raise QualityGateError(
            f"[repository:base-baseline-missing] cannot load {relative} from {resolved_base}: {error}"
        ) from error
    base = load_json_bytes(base_text, f"base {relative}")

    if base.get("schemaVersion") == 1:
        base_coverage, base_format_total, base_tests = v1_baseline(base)
        compare_no_decrease(
            "source coverage global minimum",
            float(current["sourceLineCoveragePercentMinimum"]),
            base_coverage,
        )
        compare_test_minimums(current_tests, base_tests)
        current_format_total = sum(current_format.values())
        compare_no_increase("Swift format total migration maximum", current_format_total, base_format_total)
        fallback = " via all-zero SHA fallback to HEAD^" if diff_base.used_all_zero_fallback else ""
        return f"schema v1→v2 migration against {resolved_base} accepted{fallback}"

    if base.get("schemaVersion") != 2:
        fail("[configuration:invalid-base-schema] base quality baseline must use schemaVersion 1 or 2")
    base = load_quality_baseline_from_payload(base)
    base_tests = positive_test_minimums(base, "base quality baseline")
    base_format = format_buckets(base, "base quality baseline")
    base_target_coverage = base["sourceLineCoveragePercentMinimumByTarget"]
    assert isinstance(base_target_coverage, dict)
    compare_no_decrease(
        "source coverage global minimum",
        float(current["sourceLineCoveragePercentMinimum"]),
        float(base["sourceLineCoveragePercentMinimum"]),
    )
    compare_target_minimums(current_target_coverage, base_target_coverage)
    compare_test_minimums(current_tests, base_tests)
    compare_format(current_format, base_format)
    if float(base["changedExecutableSourceLineCoveragePercentMinimum"]) != 100:
        fail("[configuration:invalid-base-schema] base changed executable source coverage minimum must be 100")
    fallback = " via all-zero SHA fallback to HEAD^" if diff_base.used_all_zero_fallback else ""
    return f"schema v2 baseline monotonic against {resolved_base} accepted{fallback}"


def load_quality_baseline_from_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Validate an already-loaded base payload using the shared v2 loader."""
    # The shared loader intentionally takes a path so production gates report
    # filesystem failures consistently. A tiny temporary-free adapter keeps
    # policy validation pure and avoids writing into a checked-out repository.
    required = (
        "sourceLineCoveragePercentMinimum",
        "sourceLineCoveragePercentMinimumByTarget",
        "changedExecutableSourceLineCoveragePercentMinimum",
        "swiftFormatWarningMaximums",
    )
    if payload.get("schemaVersion") != 2 or any(key not in payload for key in required):
        fail("[configuration:invalid-baseline] base schema v2 quality baseline is incomplete")
    # Reuse the exact numeric/map validation by serializing nowhere: its checks
    # are deliberately mirrored here for the historical Git object.
    global_minimum = payload["sourceLineCoveragePercentMinimum"]
    if not isinstance(global_minimum, (int, float)) or isinstance(global_minimum, bool) or not 0 <= float(global_minimum) <= 100:
        fail("[configuration:invalid-baseline] base sourceLineCoveragePercentMinimum must be 0 through 100")
    targets = payload["sourceLineCoveragePercentMinimumByTarget"]
    if not isinstance(targets, dict) or not targets:
        fail("[configuration:invalid-baseline] base sourceLineCoveragePercentMinimumByTarget must be non-empty")
    for target, value in targets.items():
        if not isinstance(target, str) or not target or not isinstance(value, (int, float)) or isinstance(value, bool) or not 0 < float(value) <= 100:
            fail("[configuration:invalid-baseline] base source coverage target baselines must be positive percentages")
    changed = payload["changedExecutableSourceLineCoveragePercentMinimum"]
    if not isinstance(changed, (int, float)) or isinstance(changed, bool) or not 0 <= float(changed) <= 100:
        fail("[configuration:invalid-baseline] base changed executable source coverage minimum must be 0 through 100")
    format_buckets(payload, "base quality baseline")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--diff-base", help="Git base, then QUALITY_DIFF_BASE, GITHUB_BASE_REF, or HEAD")
    args = parser.parse_args()
    root = args.root.resolve()
    baseline = args.baseline if args.baseline.is_absolute() else root / args.baseline
    try:
        result = enforce(root, baseline, args.diff_base)
    except QualityGateError as error:
        print(f"quality baseline policy: {error}", file=sys.stderr)
        return 1
    print(f"quality baseline policy: {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
