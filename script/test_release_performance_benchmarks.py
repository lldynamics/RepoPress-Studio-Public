#!/usr/bin/env python3
"""Targeted contract tests for run_release_performance_benchmarks.py."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "script" / "run_release_performance_benchmarks.py"
SPEC = importlib.util.spec_from_file_location("release_performance", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("unable to import release performance runner")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def expect_failure(action, message: str) -> None:
    try:
        action()
    except MODULE.BenchmarkFailure:
        return
    raise AssertionError(message)


def statistics(sample_count: int = 7) -> dict[str, object]:
    samples = [float(index) for index in range(1, sample_count + 1)]
    sorted_samples = sorted(samples)
    p95_index = min(
        len(sorted_samples) - 1,
        max(0, (len(sorted_samples) * 95 + 99) // 100 - 1),
    )
    return {
        "sampleCount": sample_count,
        "rawSamplesMilliseconds": samples,
        "minimumMilliseconds": 1.0,
        "medianMilliseconds": sorted_samples[len(sorted_samples) // 2],
        "p95Milliseconds": sorted_samples[p95_index],
        "maximumMilliseconds": float(sample_count),
    }


def metadata() -> dict[str, str]:
    return {
        "commit": "0123456789abcdef",
        "toolchain": "Apple Swift version 6.2",
        "architecture": "arm64",
        "operatingSystem": "Darwin 25.0",
        "machine": "Mac15,7",
    }


def test_report_validation() -> None:
    provenance = metadata()
    report = {
        "schemaVersion": 6,
        "configuration": "release",
        **provenance,
        "sampleCount": 7,
        "iterations": 7,
        "scenarios": [{"parse": statistics()}],
    }
    MODULE.validate_report(
        report,
        name="synthetic markdown",
        metadata_values=provenance,
        expected_samples=7,
    )
    pooled_report = {
        **report,
        "scenarios": [{"perChunk": statistics(sample_count=21)}],
    }
    MODULE.validate_report(
        pooled_report,
        name="synthetic pooled markdown",
        metadata_values=provenance,
        expected_samples=7,
    )
    missing_raw = {**report, "scenarios": [{"parse": {key: value for key, value in statistics().items() if key != "rawSamplesMilliseconds"}}]}
    expect_failure(
        lambda: MODULE.validate_report(
            missing_raw,
            name="synthetic markdown",
            metadata_values=provenance,
            expected_samples=7,
        ),
        "missing raw samples must fail",
    )


def test_complexity_validation() -> None:
    scenarios = []
    for article_count in (512, 2048, 4096):
        scenarios.append(
            {
                "articleCount": article_count,
                "candidateEvaluationCount": article_count * 7,
                "suggestionCount": article_count * 7,
                "fullPairCount": article_count * (article_count - 1),
            }
        )
    report = {"labelGroupSize": 8, "scenarios": scenarios}
    MODULE.validate_relation_complexity(
        report,
        expected_sizes=[512, 2048, 4096],
        expected_group_size=8,
    )
    bad = {**report, "scenarios": [{**scenarios[0], "candidateEvaluationCount": 1}, *scenarios[1:]]}
    expect_failure(
        lambda: MODULE.validate_relation_complexity(
            bad,
            expected_sizes=[512, 2048, 4096],
            expected_group_size=8,
        ),
        "complexity budget regression must fail",
    )


def test_skip_is_not_silent() -> None:
    with tempfile.TemporaryDirectory(prefix="release-performance-contract-") as directory:
        log_path = Path(directory) / "skip.log"
        expect_failure(
            lambda: MODULE.run_benchmark(
                "synthetic benchmark",
                [sys.executable, "-c", "print('Test Case synthetic skipped')"],
                {},
                log_path,
            ),
            "a skipped benchmark must fail the lane",
        )


def main() -> int:
    test_report_validation()
    test_complexity_validation()
    test_skip_is_not_silent()
    print("release performance runner contract tests: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
