#!/usr/bin/env python3
"""Run Swift tests with coverage and enforce a progressive Sources line baseline."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BASELINES = ROOT / "script" / "quality_baselines.json"
INVENTORY_PATTERN = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)/"
    r"([A-Za-z_][A-Za-z0-9_]*)(\(\))?$"
)
MAX_SUITES_PER_COVERAGE_BATCH = 8
MAX_TESTS_PER_COVERAGE_BATCH = 160


@dataclasses.dataclass(frozen=True)
class CoverageBatch:
    target: str
    suites: tuple[str, ...]
    test_count: int
    filter_pattern: str

    @property
    def label(self) -> str:
        return (
            f"{self.target}: {len(self.suites)} suites, "
            f"{self.test_count} tests"
        )


def fail(message: str) -> None:
    print(f"swift coverage gate: {message}", file=sys.stderr)
    raise SystemExit(1)


def source_line_coverage(payload: dict[str, object], root: Path) -> tuple[int, int, float]:
    data = payload.get("data")
    if not isinstance(data, list) or not data or not isinstance(data[0], dict):
        fail("coverage JSON does not contain LLVM coverage data")
    files = data[0].get("files")
    if not isinstance(files, list):
        fail("coverage JSON does not contain a files list")
    count = 0
    covered = 0
    source_root = (root / "Sources").resolve()
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
            continue
        try:
            filename = Path(item["filename"]).resolve()
            filename.relative_to(source_root)
        except (OSError, ValueError):
            continue
        summary = item.get("summary")
        lines = summary.get("lines") if isinstance(summary, dict) else None
        if not isinstance(lines, dict):
            continue
        file_count = lines.get("count")
        file_covered = lines.get("covered")
        if isinstance(file_count, int) and isinstance(file_covered, int):
            count += file_count
            covered += file_covered
    if count == 0:
        fail("coverage JSON contains no executable lines under Sources")
    percent = round((covered / count) * 100, 2)
    return covered, count, percent


def swift_test_arguments(scratch_path: Path, swift_build_root: Path) -> list[str]:
    return [
        "--disable-sandbox",
        "--enable-code-coverage",
        "--scratch-path",
        str(scratch_path),
        "--cache-path",
        str(swift_build_root / "Library/Caches/org.swift.swiftpm"),
        "--config-path",
        str(swift_build_root / "Library/org.swift.swiftpm/configuration"),
        "--security-path",
        str(swift_build_root / "Library/org.swift.swiftpm/security"),
    ]


def coverage_list_command(
    swift: str, scratch_path: Path, swift_build_root: Path
) -> list[str]:
    return [
        swift,
        "test",
        *swift_test_arguments(scratch_path, swift_build_root),
        "--skip-build",
        "list",
    ]


def coverage_build_command(
    swift: str, scratch_path: Path, swift_build_root: Path
) -> list[str]:
    return [
        swift,
        "build",
        *swift_test_arguments(scratch_path, swift_build_root),
        "--build-tests",
    ]


def coverage_batch_command(
    swift: str,
    scratch_path: Path,
    swift_build_root: Path,
    batch: CoverageBatch,
) -> list[str]:
    return [
        swift,
        "test",
        *swift_test_arguments(scratch_path, swift_build_root),
        "--filter",
        batch.filter_pattern,
    ]


def coverage_batches_from_inventory(output: str) -> list[CoverageBatch]:
    suite_counts: dict[tuple[str, str], int] = {}
    rows = [line.strip() for line in output.splitlines() if line.strip()]
    for row in rows:
        match = INVENTORY_PATTERN.fullmatch(row)
        if match is None:
            fail(f"unsupported Swift test inventory row: {row}")
        target, suite, _method, _parentheses = match.groups()
        key = (target, suite)
        suite_counts[key] = suite_counts.get(key, 0) + 1
    if not suite_counts:
        fail("swift test list returned no supported tests")

    batches: list[CoverageBatch] = []
    for target in sorted({key[0] for key in suite_counts}):
        current_suites: list[str] = []
        current_count = 0

        def append_current_batch() -> None:
            nonlocal current_suites, current_count
            if not current_suites:
                return
            alternatives = "|".join(re.escape(suite) for suite in current_suites)
            batches.append(
                CoverageBatch(
                    target=target,
                    suites=tuple(current_suites),
                    test_count=current_count,
                    filter_pattern=rf"^{re.escape(target)}\.({alternatives})/",
                )
            )
            current_suites = []
            current_count = 0

        for suite in sorted(key[1] for key in suite_counts if key[0] == target):
            suite_count = suite_counts[(target, suite)]
            if current_suites and (
                len(current_suites) >= MAX_SUITES_PER_COVERAGE_BATCH
                or current_count + suite_count > MAX_TESTS_PER_COVERAGE_BATCH
            ):
                append_current_batch()
            current_suites.append(suite)
            current_count += suite_count
        append_current_batch()
    return batches


def run_coverage_batch(
    command: list[str],
    *,
    root: Path,
    environment: dict[str, str],
    label: str,
    timeout_seconds: float,
    retries: int = 0,
) -> None:
    for attempt in range(1, retries + 2):
        process = subprocess.Popen(
            command,
            cwd=root,
            env=environment,
            start_new_session=True,
        )
        try:
            return_code = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=2)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            if attempt <= retries:
                print(
                    f"swift coverage gate: batch timed out after "
                    f"{timeout_seconds:.0f}s; retrying ({attempt}/{retries}): {label}",
                    file=sys.stderr,
                    flush=True,
                )
                continue
            fail(f"coverage batch timed out after {timeout_seconds:.0f}s: {label}")
        if return_code != 0:
            fail(f"coverage batch failed with status {return_code}: {label}")
        return


def coverage_batch_retries(environment: dict[str, str]) -> int:
    raw_value = environment.get("SWIFT_COVERAGE_BATCH_RETRIES", "1")
    try:
        retries = int(raw_value)
    except ValueError:
        fail("SWIFT_COVERAGE_BATCH_RETRIES must be a non-negative integer")
    if retries < 0:
        fail("SWIFT_COVERAGE_BATCH_RETRIES must be a non-negative integer")
    return retries


def find_test_binary(scratch_path: Path) -> Path:
    candidates = sorted(
        path
        for path in scratch_path.rglob("*.xctest/Contents/MacOS/*")
        if path.is_file() and os.access(path, os.X_OK)
    )
    if len(candidates) != 1:
        fail(f"expected one SwiftPM test binary, found {len(candidates)}")
    return candidates[0]


def run_coverage(root: Path, scratch_path: Path) -> Path:
    swift = os.environ.get("SWIFT_BIN", "swift")
    environment = os.environ.copy()
    swift_build_root = Path(
        environment.get("SWIFT_BUILD_HOME", "/private/tmp/personal-site-publisher-coverage-root")
    )
    environment.setdefault("XDG_CACHE_HOME", str(swift_build_root / ".cache"))
    environment.setdefault("CLANG_MODULE_CACHE_PATH", str(swift_build_root / ".swift-clang-cache"))
    environment.setdefault("SWIFT_MODULE_CACHE_PATH", str(swift_build_root / ".swift-module-cache"))
    for directory in (
        swift_build_root,
        Path(environment["XDG_CACHE_HOME"]),
        Path(environment["CLANG_MODULE_CACHE_PATH"]),
        Path(environment["SWIFT_MODULE_CACHE_PATH"]),
        swift_build_root / "Library/org.swift.swiftpm/configuration",
        swift_build_root / "Library/org.swift.swiftpm/security",
        swift_build_root / "Library/Caches/org.swift.swiftpm",
    ):
        directory.mkdir(parents=True, exist_ok=True)

    profile_directory = scratch_path / "isolated-codecov-profiles"
    if profile_directory.exists():
        shutil.rmtree(profile_directory)
    profile_directory.mkdir(parents=True)
    batch_timeout = float(os.environ.get("SWIFT_COVERAGE_BATCH_TIMEOUT_SECONDS", "300"))
    batch_retries = coverage_batch_retries(environment)

    try:
        build_command = coverage_build_command(swift, scratch_path, swift_build_root)
        print("swift coverage gate: building coverage-instrumented tests", flush=True)
        subprocess.run(
            build_command,
            cwd=root,
            env=environment,
            check=True,
        )
        list_command = coverage_list_command(swift, scratch_path, swift_build_root)
        print("swift coverage gate: listing the prebuilt coverage tests", flush=True)
        inventory_result = subprocess.run(
            list_command,
            cwd=root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        )
        batches = coverage_batches_from_inventory(inventory_result.stdout)
        test_binary = find_test_binary(scratch_path)
        print(
            f"swift coverage gate: running {len(batches)} isolated suite batches",
            flush=True,
        )
        for index, batch in enumerate(batches, start=1):
            print(
                f"swift coverage gate: batch {index}/{len(batches)}: "
                f"{batch.label}",
                flush=True,
            )
            run_coverage_batch(
                coverage_batch_command(swift, scratch_path, swift_build_root, batch),
                root=root,
                environment=environment,
                label=batch.label,
                timeout_seconds=batch_timeout,
                retries=batch_retries,
            )
            codecov_directory = test_binary.parents[3] / "codecov"
            profiles = sorted(codecov_directory.glob("*.profraw"))
            if not profiles:
                fail(f"coverage batch produced no profiles: {batch.label}")
            for profile_index, profile in enumerate(profiles, start=1):
                shutil.copy2(
                    profile,
                    profile_directory
                    / f"batch-{index:03d}-{profile_index:02d}.profraw",
                )

        profiles = sorted(profile_directory.glob("*.profraw"))
        merged_profile = profile_directory / "merged.profdata"
        xcrun = environment.get("XCRUN_BIN", "xcrun")
        subprocess.run(
            [
                xcrun,
                "llvm-profdata",
                "merge",
                "-sparse",
                *map(str, profiles),
                "-o",
                str(merged_profile),
            ],
            cwd=root,
            env=environment,
            check=True,
        )
        coverage_path = scratch_path / "isolated-codecov.json"
        with coverage_path.open("w", encoding="utf-8") as coverage_file:
            subprocess.run(
                [
                    xcrun,
                    "llvm-cov",
                    "export",
                    f"-instr-profile={merged_profile}",
                    str(test_binary),
                ],
                cwd=root,
                env=environment,
                stdout=coverage_file,
                check=True,
            )
        shutil.rmtree(profile_directory)
        return coverage_path
    except FileNotFoundError:
        print(
            "swift coverage gate [environment:tool-unavailable]: required Swift/LLVM "
            "tooling was not found; no network install was attempted",
            file=sys.stderr,
        )
        raise SystemExit(69)
    except subprocess.CalledProcessError as error:
        fail(f"coverage command failed with status {error.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINES)
    parser.add_argument(
        "--coverage-json",
        type=Path,
        help="validate an existing SwiftPM coverage JSON instead of running tests",
    )
    parser.add_argument("--result-json", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        baseline_payload = json.loads(args.baseline.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load quality baseline: {error}")
    minimum = baseline_payload.get("sourceLineCoveragePercentMinimum")
    if (
        baseline_payload.get("schemaVersion") != 1
        or not isinstance(minimum, (int, float))
        or isinstance(minimum, bool)
        or not 0 <= float(minimum) <= 100
    ):
        fail("quality baseline must contain sourceLineCoveragePercentMinimum from 0 through 100")

    coverage_path = (
        args.coverage_json.resolve()
        if args.coverage_json
        else run_coverage(
            root,
            Path(
                os.environ.get(
                    "SWIFT_COVERAGE_SCRATCH_PATH",
                    str(root / ".build" / "coverage"),
                )
            ),
        )
    )
    try:
        coverage_payload = json.loads(coverage_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load coverage JSON {coverage_path}: {error}")
    covered, count, percent = source_line_coverage(coverage_payload, root)
    result = {
        "schemaVersion": 1,
        "sourceLines": {
            "covered": covered,
            "count": count,
            "percent": percent,
            "minimumPercent": float(minimum),
        },
        "coverageJSON": str(coverage_path),
    }
    if args.result_json:
        args.result_json.parent.mkdir(parents=True, exist_ok=True)
        args.result_json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if percent + 1e-9 < float(minimum):
        fail(f"Sources line coverage {percent:.2f}% is below progressive baseline {float(minimum):.2f}%")
    print(
        f"swift coverage gate: passed ({covered}/{count} Sources lines, "
        f"{percent:.2f}%; progressive minimum {float(minimum):.2f}%)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
