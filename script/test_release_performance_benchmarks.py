#!/usr/bin/env python3
"""Targeted contract tests for run_release_performance_benchmarks.py."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from unittest.mock import patch
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
        "dirtyWorktree": "false",
        "sourceTreeFingerprint": "a" * 64,
    }


def test_report_validation() -> None:
    provenance = metadata()
    report = {
        "schemaVersion": 6,
        "configuration": "release",
        **{
            key: provenance[key]
            for key in MODULE.BENCHMARK_REPORT_METADATA_KEYS
        },
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


def test_source_tree_fingerprint_includes_untracked_contents() -> None:
    with tempfile.TemporaryDirectory(prefix="release-performance-fingerprint-") as directory:
        root = Path(directory)
        (root / "tracked.swift").write_text("let tracked = 1\n", encoding="utf-8")
        untracked = root / "new.swift"
        untracked.write_text("let value = 1\n", encoding="utf-8")
        paths = "tracked.swift\0new.swift\0"
        initial = MODULE.source_tree_fingerprint(paths, "?? new.swift", root)
        untracked.write_text("let value = 2\n", encoding="utf-8")
        changed = MODULE.source_tree_fingerprint(paths, "?? new.swift", root)
        assert initial != changed, "untracked content must affect the evidence fingerprint"


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


def test_runner_reuses_build_and_stops_after_first_failure() -> None:
    calls: list[tuple[str, list[str]]] = []
    with tempfile.TemporaryDirectory(prefix="release-performance-cache-") as cache_directory, patch.object(MODULE, "metadata", metadata), patch.object(
        MODULE,
        "load_baseline",
        return_value={
            "minimumSampleCount": 3,
            "siteMaintenanceRelation": {"sizes": [512], "labelGroupSize": 8},
            "wallTime": {"blocking": False, "policy": "trend-only"},
        },
    ), patch.object(MODULE, "run_benchmark") as run_benchmark, patch.dict(
        os.environ, {"SWIFT_BIN": "custom-swift", "SWIFT_BUILD_HOME": cache_directory}, clear=False
    ):
        def spy(name, command, environment, log_path):
            calls.append((name, command))
            report = {
                "schemaVersion": 6,
                "configuration": "release",
                **{key: metadata()[key] for key in MODULE.BENCHMARK_REPORT_METADATA_KEYS},
                "sampleCount": 3,
                "iterations": 3,
                "scenarios": [{"parse": statistics(sample_count=3)}],
            }
            if name == "site maintenance relation benchmark":
                report["labelGroupSize"] = 8
                report["scenarios"] = [{
                    "articleCount": 512,
                    "candidateEvaluationCount": 512 * 7,
                    "suggestionCount": 512 * 7,
                    "fullPairCount": 512 * 511,
                    "timings": statistics(sample_count=3),
                }]
                output_key = "SITE_MAINTENANCE_RELATION_BENCHMARK_OUTPUT"
            else:
                output_key = "MARKDOWN_SYNTAX_BENCHMARK_OUTPUT"
            Path(environment[output_key]).write_text(json.dumps(report), encoding="utf-8")
            return ""

        run_benchmark.side_effect = spy
        with tempfile.TemporaryDirectory(prefix="release-performance-reuse-") as directory:
            args = MODULE.parser().parse_args(
                ["--iterations", "3", "--relation-sizes", "512", "--output-directory", directory]
            )
            assert MODULE.run_lane(args) == 0
        assert [name for name, _ in calls] == [
            "markdown syntax benchmark",
            "site maintenance relation benchmark",
        ], calls
        relation_command = calls[1][1]
        assert relation_command == [
            "custom-swift",
            "test",
            "--configuration",
            "release",
            "--disable-sandbox",
            "--skip-build",
            "--filter",
            "SiteMaintenanceRelationBenchmarkTests/testGeneratedRelationScanScaleBaseline",
        ], relation_command

        calls.clear()
        def fail_first(name, command, environment, log_path):
            calls.append((name, command))
            raise MODULE.BenchmarkFailure("synthetic first benchmark failure")

        run_benchmark.side_effect = fail_first
        with tempfile.TemporaryDirectory(prefix="release-performance-short-circuit-") as directory:
            args = MODULE.parser().parse_args(
                ["--iterations", "3", "--relation-sizes", "512", "--output-directory", directory]
            )
            expect_failure(lambda: MODULE.run_lane(args), "first benchmark failure must stop lane")
        assert [name for name, _ in calls] == ["markdown syntax benchmark"], calls


def test_markdown_shell_uses_custom_swift_and_reuses_build() -> None:
    with tempfile.TemporaryDirectory(prefix="release-performance-swift-") as directory:
        root = Path(directory)
        log = root / "swift.log"
        fake_swift = root / "swift"
        fake_swift.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$FAKE_SWIFT_LOG\"\n"
            "if [ \"$1\" = --version ]; then echo 'fake swift 1.0'; exit 0; fi\n"
            "if [ \"${FAIL_FIRST:-0}\" = 1 ] && [ \"$1\" = test ] && ! printf '%s\\n' \"$*\" | grep -q -- --skip-build; then exit 7; fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        fake_swift.chmod(0o755)
        output = root / "syntax.json"
        environment = os.environ.copy()
        environment.update({
            "SWIFT_BIN": str(fake_swift),
            "SWIFT_BUILD_HOME": str(root / "swift-home"),
            "FAKE_SWIFT_LOG": str(log),
            "MARKDOWN_VIEWPORT_BENCHMARK_OUTPUT": str(root / "viewport.json"),
        })
        environment.pop("PERFORMANCE_BENCHMARK_TOOLCHAIN", None)

        def run_case(fail_first: bool) -> list[str]:
            log.unlink(missing_ok=True)
            case_environment = environment | {"FAIL_FIRST": "1" if fail_first else "0"}
            result = subprocess.run(
                [
                    "bash",
                    str(ROOT / "script/benchmark_markdown_syntax_highlighting.sh"),
                    "--iterations",
                    "3",
                    "--configuration",
                    "release",
                    "--output",
                    str(output),
                ],
                cwd=ROOT,
                env=case_environment,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            assert result.returncode == (7 if fail_first else 0), result.stdout
            return log.read_text(encoding="utf-8").splitlines()

        commands = run_case(False)
        assert commands[0] == "--version", commands
        tests = [command for command in commands if command.startswith("test ")]
        assert len(tests) == 2, commands
        assert "--skip-build" not in tests[0], tests
        assert "--skip-build" in tests[1], tests
        failed_commands = run_case(True)
        assert [command for command in failed_commands if command.startswith("test ")] == [tests[0]]


def main() -> int:
    test_report_validation()
    test_source_tree_fingerprint_includes_untracked_contents()
    test_complexity_validation()
    test_skip_is_not_silent()
    test_runner_reuses_build_and_stops_after_first_failure()
    test_markdown_shell_uses_custom_swift_and_reuses_build()
    print("release performance runner contract tests: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
