#!/usr/bin/env python3
"""Run the independent Release performance lane and validate its evidence.

The Swift tests intentionally skip their baseline-only cases during the normal
test inventory.  This driver supplies every required environment variable,
runs the two baselines in Release configuration, rejects a skipped or missing
test, and writes one self-contained JSON artifact with raw samples and host
provenance.  Structural/complexity checks are blocking; wall-clock values are
reported for trend review because hosted runners are noisy.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
BASELINES_PATH = ROOT / "script" / "quality_baselines.json"
DEFAULT_OUTPUT_DIRECTORY = ROOT / ".build" / "release-performance"
MARKDOWN_REPORT_NAME = "markdown-syntax.json"
RELATION_REPORT_NAME = "site-maintenance-relations.json"
COMBINED_REPORT_NAME = "performance.json"
BENCHMARK_REPORT_METADATA_KEYS = (
    "commit",
    "toolchain",
    "architecture",
    "operatingSystem",
    "machine",
)
SKIP_COUNT_PATTERN = re.compile(r"\b([1-9][0-9]*)\s+(?:tests?|cases?)\s+skipped\b", re.IGNORECASE)
SKIP_CASE_PATTERN = re.compile(r"\bTest Case .*\bskipped\b", re.IGNORECASE)
SKIP_SUMMARY_PATTERN = re.compile(
    r"\b(?:tests?|test cases?)\s+skipped\b|\bskipped\s+(?:tests?|test cases?)\b",
    re.IGNORECASE,
)


class BenchmarkFailure(RuntimeError):
    """A release performance lane contract failure."""


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".partial",
        delete=False,
    ) as handle:
        temporary = Path(handle.name)
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def run_capture(command: list[str]) -> str:
    try:
        return subprocess.check_output(
            command,
            cwd=ROOT,
            text=True,
            stderr=subprocess.STDOUT,
            timeout=30,
        ).strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def run_capture_nul(command: list[str]) -> str:
    """Capture a NUL-delimited filesystem list without trimming path bytes."""
    try:
        result = subprocess.run(
            command,
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        return os.fsdecode(result.stdout)
    except (OSError, subprocess.CalledProcessError):
        return ""


def source_tree_fingerprint(paths: str, status: str, root: Path = ROOT) -> str:
    """Hash every tracked/untracked source path without following symlinks."""
    digest = hashlib.sha256()
    for relative_path in sorted(path for path in paths.split("\0") if path):
        path = root / relative_path
        encoded_path = os.fsencode(relative_path)
        digest.update(b"path\0")
        digest.update(encoded_path)
        digest.update(b"\0")
        try:
            stat = path.lstat()
            if path.is_symlink():
                digest.update(b"symlink\0")
                digest.update(os.fsencode(os.readlink(path)))
                digest.update(b"\0")
            elif path.is_file():
                digest.update(b"file\0")
                digest.update(str(stat.st_size).encode())
                digest.update(b"\0")
                with path.open("rb") as handle:
                    while chunk := handle.read(1024 * 1024):
                        digest.update(chunk)
            else:
                digest.update(b"other\0")
                digest.update(str(stat.st_mode).encode())
                digest.update(b"\0")
        except OSError:
            digest.update(b"missing\0")
    digest.update(b"status\0")
    digest.update(status.encode("utf-8", errors="surrogateescape"))
    return digest.hexdigest()


def first_line(value: str) -> str:
    return next((line.strip() for line in value.splitlines() if line.strip()), "")


def host_machine() -> str:
    model = run_capture(["sysctl", "-n", "hw.model"]) if platform.system() == "Darwin" else ""
    return model or os.environ.get("RUNNER_NAME", "") or platform.node() or "unknown"


def metadata() -> dict[str, str]:
    swift = shutil.which(os.environ.get("SWIFT_BIN", "swift")) or os.environ.get(
        "SWIFT_BIN", "swift"
    )
    swift_version = first_line(run_capture([swift, "--version"])) or "unknown"
    os_version = platform.mac_ver()[0] if platform.system() == "Darwin" else ""
    if not os_version:
        os_version = platform.release()
    status = run_capture(["git", "status", "--porcelain=v1", "--untracked-files=all"])
    # Include tracked and non-ignored untracked contents. Path-only hashing would
    # let an edited untracked source silently reuse an unrelated artifact.
    paths = run_capture_nul(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    )
    return {
        "commit": run_capture(["git", "rev-parse", "HEAD"]) or "unknown",
        "toolchain": swift_version,
        "architecture": platform.machine() or "unknown",
        "operatingSystem": f"{platform.system()} {os_version}".strip(),
        "machine": host_machine(),
        "dirtyWorktree": "true" if status else "false",
        "sourceTreeFingerprint": source_tree_fingerprint(paths, status),
    }


def load_baseline() -> dict[str, Any]:
    try:
        payload = json.loads(BASELINES_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkFailure(f"cannot read performance quality baseline: {error}") from error
    baseline = payload.get("releasePerformance")
    if not isinstance(baseline, dict):
        raise BenchmarkFailure("quality_baselines.json must define releasePerformance")
    if baseline.get("configuration") != "release":
        raise BenchmarkFailure("releasePerformance baseline configuration must be release")
    minimum_samples = baseline.get("minimumSampleCount")
    if not isinstance(minimum_samples, int) or isinstance(minimum_samples, bool) or minimum_samples < 3:
        raise BenchmarkFailure("releasePerformance minimumSampleCount must be an integer >= 3")
    relation = baseline.get("siteMaintenanceRelation")
    if not isinstance(relation, dict):
        raise BenchmarkFailure("releasePerformance must define siteMaintenanceRelation")
    sizes = relation.get("sizes")
    if (
        not isinstance(sizes, list)
        or not sizes
        or not all(isinstance(size, int) and not isinstance(size, bool) and size > 0 for size in sizes)
    ):
        raise BenchmarkFailure("releasePerformance relation sizes must be positive integers")
    group_size = relation.get("labelGroupSize")
    if not isinstance(group_size, int) or isinstance(group_size, bool) or group_size < 2:
        raise BenchmarkFailure("releasePerformance labelGroupSize must be an integer >= 2")
    wall_time = baseline.get("wallTime")
    if not isinstance(wall_time, dict) or wall_time.get("blocking") is not False:
        raise BenchmarkFailure("releasePerformance wallTime must explicitly be non-blocking")
    return baseline


def positive_integer(value: str, name: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise BenchmarkFailure(f"{name} must be a positive integer: {value}") from error
    if parsed <= 0:
        raise BenchmarkFailure(f"{name} must be a positive integer: {value}")
    return parsed


def run_benchmark(
    name: str,
    command: list[str],
    environment: dict[str, str],
    log_path: Path,
) -> str:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(f"command: {json.dumps(command, ensure_ascii=False)}\n", encoding="utf-8")
    try:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except OSError as error:
        raise BenchmarkFailure(f"{name} could not start: {error}") from error

    output: list[str] = []
    assert process.stdout is not None
    with log_path.open("a", encoding="utf-8") as log_file:
        for line in process.stdout:
            output.append(line)
            log_file.write(line)
            print(line, end="", flush=True)
    return_code = process.wait()
    captured = "".join(output)
    if return_code != 0:
        raise BenchmarkFailure(f"{name} failed with exit code {return_code}; see {log_path}")
    if (
        SKIP_COUNT_PATTERN.search(captured)
        or SKIP_CASE_PATTERN.search(captured)
        or SKIP_SUMMARY_PATTERN.search(captured)
    ):
        raise BenchmarkFailure(f"{name} reported a skipped test; see {log_path}")
    return captured


def non_empty_string(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.strip() or value.strip().lower() == "unknown":
        raise BenchmarkFailure(f"{path} must be a non-empty, known string")
    return value


def finite_number(value: Any, path: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        raise BenchmarkFailure(f"{path} must be a finite number")
    if float(value) < 0:
        raise BenchmarkFailure(f"{path} must not be negative")
    return float(value)


def validate_statistics(value: dict[str, Any], path: str, expected_samples: int) -> None:
    raw = value.get("rawSamplesMilliseconds")
    sample_count = value.get("sampleCount")
    if not isinstance(sample_count, int) or isinstance(sample_count, bool) or sample_count <= 0:
        raise BenchmarkFailure(f"{path}.sampleCount must be a positive integer")
    if not isinstance(raw, list) or len(raw) != sample_count or not raw:
        raise BenchmarkFailure(
            f"{path}.rawSamplesMilliseconds must contain its declared {sample_count} samples"
        )
    if sample_count < expected_samples:
        raise BenchmarkFailure(
            f"{path}.sampleCount {sample_count} is below the report iteration count {expected_samples}"
        )
    samples = [finite_number(sample, f"{path}.rawSamplesMilliseconds[{index}]") for index, sample in enumerate(raw)]
    for field in ("minimumMilliseconds", "medianMilliseconds", "p95Milliseconds", "maximumMilliseconds"):
        finite_number(value.get(field), f"{path}.{field}")
    if value["minimumMilliseconds"] != min(samples) or value["maximumMilliseconds"] != max(samples):
        raise BenchmarkFailure(f"{path} minimum/maximum do not match raw samples")
    sorted_samples = sorted(samples)
    expected_median = sorted_samples[len(sorted_samples) // 2]
    p95_index = min(len(sorted_samples) - 1, max(0, math.ceil(len(sorted_samples) * 0.95) - 1))
    if value["medianMilliseconds"] != expected_median or value["p95Milliseconds"] != sorted_samples[p95_index]:
        raise BenchmarkFailure(f"{path} median/p95 do not match raw samples")


def validate_all_statistics(value: Any, path: str, expected_samples: int) -> int:
    count = 0
    if isinstance(value, dict):
        if "medianMilliseconds" in value or "p95Milliseconds" in value:
            if not isinstance(value, dict):
                raise BenchmarkFailure(f"{path} statistics must be an object")
            validate_statistics(value, path, expected_samples)
            count += 1
        for key, child in value.items():
            count += validate_all_statistics(child, f"{path}.{key}", expected_samples)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            count += validate_all_statistics(child, f"{path}[{index}]", expected_samples)
    return count


def validate_report(
    report: dict[str, Any],
    *,
    name: str,
    metadata_values: dict[str, str],
    expected_samples: int,
) -> None:
    if not isinstance(report.get("schemaVersion"), int) or report["schemaVersion"] < 2:
        raise BenchmarkFailure(f"{name} report has no supported schemaVersion")
    if report.get("configuration") != "release":
        raise BenchmarkFailure(f"{name} report did not run in Release configuration")
    if report.get("sampleCount") != expected_samples or report.get("iterations") != expected_samples:
        raise BenchmarkFailure(f"{name} report sample count does not match {expected_samples}")
    # The individual Swift benchmark schemas predate lane-only dirty-tree
    # provenance. The combined report carries those additional fields.
    for key in BENCHMARK_REPORT_METADATA_KEYS:
        expected = metadata_values[key]
        actual = non_empty_string(report.get(key), f"{name}.{key}")
        if actual != expected:
            raise BenchmarkFailure(f"{name}.{key} disagrees with lane metadata")
    statistic_count = validate_all_statistics(report, name, expected_samples)
    if statistic_count == 0:
        raise BenchmarkFailure(f"{name} report contains no raw benchmark statistics")


def validate_relation_complexity(
    report: dict[str, Any],
    *,
    expected_sizes: list[int],
    expected_group_size: int,
) -> dict[str, Any]:
    if report.get("labelGroupSize") != expected_group_size:
        raise BenchmarkFailure("relation benchmark label density differs from baseline")
    scenarios = report.get("scenarios")
    if not isinstance(scenarios, list) or [item.get("articleCount") for item in scenarios] != expected_sizes:
        raise BenchmarkFailure("relation benchmark sizes differ from baseline")
    checks: list[dict[str, Any]] = []
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            raise BenchmarkFailure(f"relation scenario {index} is not an object")
        article_count = scenario.get("articleCount")
        candidates = scenario.get("candidateEvaluationCount")
        suggestions = scenario.get("suggestionCount")
        full_pairs = scenario.get("fullPairCount")
        if not isinstance(article_count, int) or isinstance(article_count, bool) or article_count <= 0:
            raise BenchmarkFailure(f"relation scenario {index} has an invalid article count")
        expected_candidates = article_count * (expected_group_size - 1)
        expected_pairs = article_count * max(0, article_count - 1)
        if candidates != expected_candidates:
            raise BenchmarkFailure(
                f"relation candidate work changed for {article_count}: "
                f"expected {expected_candidates}, found {candidates}"
            )
        if suggestions != expected_candidates or full_pairs != expected_pairs:
            raise BenchmarkFailure(f"relation deterministic metrics mismatch for {article_count}")
        checks.append(
            {
                "articleCount": article_count,
                "candidateEvaluationCount": candidates,
                "expectedCandidateEvaluationCount": expected_candidates,
                "fullPairCount": full_pairs,
                "status": "passed",
            }
        )
    return {
        "policy": "fixed-label-density-linear",
        "status": "passed",
        "scenarios": checks,
    }


def read_json(path: Path, name: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BenchmarkFailure(f"{name} report is missing or invalid: {error}") from error
    if not isinstance(payload, dict):
        raise BenchmarkFailure(f"{name} report root must be an object")
    return payload


def run_lane(args: argparse.Namespace) -> int:
    baseline = load_baseline()
    expected_samples = args.iterations
    minimum_samples = int(baseline["minimumSampleCount"])
    if expected_samples < minimum_samples:
        raise BenchmarkFailure(
            f"iterations must be at least the quality baseline minimum ({minimum_samples})"
        )
    if args.configuration != "release":
        raise BenchmarkFailure("the independent performance lane only accepts --configuration release")
    output_directory = args.output_directory.resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    metadata_values = metadata()
    atomic_write_json(
        output_directory / COMBINED_REPORT_NAME,
        {
            "schemaVersion": 1,
            "status": "running",
            "configuration": "release",
            **metadata_values,
            "sampleCount": expected_samples,
        },
    )
    swift_home = Path(
        os.environ.get("SWIFT_BUILD_HOME", "/private/tmp/personal-site-publisher-performance-swift-home")
    ).expanduser()
    environment = os.environ.copy()
    environment.update(
        {
            "XDG_CACHE_HOME": str(swift_home / ".cache"),
            "CLANG_MODULE_CACHE_PATH": str(swift_home / ".swift-clang-cache"),
            "SWIFT_MODULE_CACHE_PATH": str(swift_home / ".swift-module-cache"),
            "PERFORMANCE_BENCHMARK_REQUIRED": "1",
            "PERFORMANCE_BENCHMARK_CONFIGURATION": "release",
            "PERFORMANCE_BENCHMARK_ENFORCE_WALL_TIME": "0",
            "PERFORMANCE_BENCHMARK_ITERATIONS": str(expected_samples),
            "PERFORMANCE_BENCHMARK_COMMIT": metadata_values["commit"],
            "PERFORMANCE_BENCHMARK_TOOLCHAIN": metadata_values["toolchain"],
            "PERFORMANCE_BENCHMARK_ARCHITECTURE": metadata_values["architecture"],
            "PERFORMANCE_BENCHMARK_OPERATING_SYSTEM": metadata_values["operatingSystem"],
            "PERFORMANCE_BENCHMARK_MACHINE": metadata_values["machine"],
            "RUN_MARKDOWN_SYNTAX_BENCHMARK": "1",
            "MARKDOWN_SYNTAX_BENCHMARK_ITERATIONS": str(expected_samples),
            "MARKDOWN_SYNTAX_BENCHMARK_CONFIGURATION": "release",
            "MARKDOWN_SYNTAX_BENCHMARK_OUTPUT": str(output_directory / MARKDOWN_REPORT_NAME),
            "RUN_SITE_MAINTENANCE_RELATION_BENCHMARK": "1",
            "SITE_MAINTENANCE_RELATION_BENCHMARK_ITERATIONS": str(expected_samples),
            "SITE_MAINTENANCE_RELATION_BENCHMARK_CONFIGURATION": "release",
            "SITE_MAINTENANCE_RELATION_BENCHMARK_SIZES": ",".join(
                str(size) for size in args.relation_sizes
            ),
            "SITE_MAINTENANCE_RELATION_BENCHMARK_LABEL_GROUP_SIZE": str(args.relation_group_size),
            "SITE_MAINTENANCE_RELATION_BENCHMARK_OUTPUT": str(
                output_directory / RELATION_REPORT_NAME
            ),
        }
    )
    for path in (
        swift_home,
        swift_home / ".cache",
        swift_home / ".swift-clang-cache",
        swift_home / ".swift-module-cache",
    ):
        path.mkdir(parents=True, exist_ok=True)

    swift = shutil.which(environment.get("SWIFT_BIN", "swift")) or environment.get("SWIFT_BIN", "swift")
    run_benchmark(
        "markdown syntax benchmark",
        [
            "bash",
            "script/benchmark_markdown_syntax_highlighting.sh",
            "--configuration",
            "release",
            "--iterations",
            str(expected_samples),
            "--output",
            str(output_directory / MARKDOWN_REPORT_NAME),
        ],
        environment,
        output_directory / "markdown-syntax.log",
    )
    run_benchmark(
        "site maintenance relation benchmark",
        [
            swift,
            "test",
            "--configuration",
            "release",
            "--disable-sandbox",
            "--filter",
            "SiteMaintenanceRelationBenchmarkTests/testGeneratedRelationScanScaleBaseline",
        ],
        environment,
        output_directory / "site-maintenance-relations.log",
    )

    markdown_report = read_json(output_directory / MARKDOWN_REPORT_NAME, "markdown syntax")
    relation_report = read_json(output_directory / RELATION_REPORT_NAME, "site maintenance relation")
    validate_report(
        markdown_report,
        name="markdown syntax",
        metadata_values=metadata_values,
        expected_samples=expected_samples,
    )
    validate_report(
        relation_report,
        name="site maintenance relation",
        metadata_values=metadata_values,
        expected_samples=expected_samples,
    )
    complexity = validate_relation_complexity(
        relation_report,
        expected_sizes=args.relation_sizes,
        expected_group_size=args.relation_group_size,
    )
    wall_time = {
        "policy": str(baseline["wallTime"].get("policy", "trend-only")),
        "blocking": False,
        "status": "trend-only",
        "note": "Hosted runner wall-clock variance is retained as raw samples and is not a merge blocker.",
    }
    combined = {
        "schemaVersion": 1,
        "status": "passed",
        "configuration": "release",
        **metadata_values,
        "sampleCount": expected_samples,
        "baseline": baseline,
        "deterministicChecks": {"siteMaintenanceRelation": complexity},
        "wallTime": wall_time,
        "benchmarks": {
            "markdownSyntaxHighlighting": markdown_report,
            "siteMaintenanceRelation": relation_report,
        },
    }
    atomic_write_json(output_directory / COMBINED_REPORT_NAME, combined)
    print(f"release performance report: {output_directory / COMBINED_REPORT_NAME}")
    print("release performance lane: passed (deterministic checks blocking; wall-time trend-only)")
    return 0


def parser() -> argparse.ArgumentParser:
    baseline = json.loads(BASELINES_PATH.read_text(encoding="utf-8"))
    release_baseline = baseline.get("releasePerformance", {})
    default_iterations = int(release_baseline.get("minimumSampleCount", 7))
    relation = release_baseline.get("siteMaintenanceRelation", {})
    default_sizes = relation.get("sizes", [512, 2048, 4096])
    default_group_size = int(relation.get("labelGroupSize", 8))
    argument_parser = argparse.ArgumentParser(description=__doc__)
    argument_parser.add_argument("--configuration", default="release")
    argument_parser.add_argument("--iterations", type=int, default=default_iterations)
    argument_parser.add_argument(
        "--output-directory",
        type=Path,
        default=DEFAULT_OUTPUT_DIRECTORY,
    )
    argument_parser.add_argument(
        "--relation-sizes",
        type=lambda value: positive_integer(value, "relation size"),
        nargs="+",
        default=default_sizes,
    )
    argument_parser.add_argument("--relation-group-size", type=int, default=default_group_size)
    return argument_parser


def main(argv: list[str] | None = None) -> int:
    argument_parser = parser()
    args = argument_parser.parse_args(argv)
    try:
        args.iterations = positive_integer(str(args.iterations), "iterations")
        args.relation_group_size = positive_integer(str(args.relation_group_size), "relation group size")
        if args.relation_group_size < 2:
            raise BenchmarkFailure("relation group size must be at least 2")
        return run_lane(args)
    except BenchmarkFailure as error:
        output_directory = getattr(args, "output_directory", DEFAULT_OUTPUT_DIRECTORY).resolve()
        output_directory.mkdir(parents=True, exist_ok=True)
        metadata_values = metadata()
        failure = {
            "schemaVersion": 1,
            "status": "failed",
            "configuration": getattr(args, "configuration", "release"),
            **metadata_values,
            "sampleCount": getattr(args, "iterations", 0),
            "error": str(error),
        }
        atomic_write_json(output_directory / COMBINED_REPORT_NAME, failure)
        print(f"release performance lane: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
