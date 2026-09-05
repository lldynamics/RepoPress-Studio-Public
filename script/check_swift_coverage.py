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
import time
from decimal import Decimal
from pathlib import Path

from quality_gate_common import (
    QualityGateError,
    changed_lines,
    load_quality_baseline,
    resolve_diff_base,
    target_directories,
    validate_target_mapping,
)


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BASELINES = ROOT / "script" / "quality_baselines.json"
INVENTORY_PATTERN = re.compile(
    r"^([^\.\s/]+)\."
    r"([A-Za-z0-9_:]+)/"
    r"([A-Za-z0-9_:]+)(\([^\r\n]*\))?$"
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


def coverage_files(payload: dict[str, object], root: Path) -> list[dict[str, object]]:
    data = payload.get("data")
    if not isinstance(data, list) or not data or not isinstance(data[0], dict):
        fail("coverage JSON does not contain LLVM coverage data")
    files = data[0].get("files")
    if not isinstance(files, list):
        fail("coverage JSON does not contain a files list")
    source_root = (root / "Sources").resolve()
    result: list[dict[str, object]] = []
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
            continue
        try:
            raw_filename = Path(item["filename"])
            filename = (raw_filename if raw_filename.is_absolute() else root / raw_filename).resolve()
            filename.relative_to(source_root)
        except (OSError, ValueError):
            continue
        copy = dict(item)
        copy["_resolvedFilename"] = filename
        result.append(copy)
    if not result:
        fail("coverage JSON contains no executable lines under Sources")
    return result


def summary_line_counts(item: dict[str, object]) -> tuple[int, int]:
    summary = item.get("summary")
    lines = summary.get("lines") if isinstance(summary, dict) else None
    count = lines.get("count") if isinstance(lines, dict) else None
    covered = lines.get("covered") if isinstance(lines, dict) else None
    if not isinstance(count, int) or isinstance(count, bool) or not isinstance(covered, int) or isinstance(covered, bool):
        fail("coverage JSON file lacks integer summary.lines count and covered values")
    return covered, count


def executable_line_evidence(item: dict[str, object]) -> dict[int, bool]:
    """Expand executable LLVM segment intervals into covered/uncovered source lines."""
    segments = item.get("segments")
    if not isinstance(segments, list):
        fail("coverage JSON file lacks LLVM segments required for changed-line coverage")
    parsed_segments: list[tuple[int, int, int, bool, bool, bool]] = []
    previous_position: tuple[int, int] | None = None
    for segment in segments:
        if not isinstance(segment, list) or len(segment) < 6:
            fail("coverage JSON contains an invalid LLVM segment")
        line, column, executions, has_count, is_region_entry, is_gap = segment[:6]
        if (
            not isinstance(line, int)
            or isinstance(line, bool)
            or line < 1
            or not isinstance(column, int)
            or isinstance(column, bool)
            or column < 1
            or not isinstance(executions, int)
            or isinstance(executions, bool)
            or executions < 0
            or not isinstance(has_count, bool)
            or not isinstance(is_region_entry, bool)
            or not isinstance(is_gap, bool)
        ):
            fail("coverage JSON contains an invalid LLVM segment value")
        position = (line, column)
        if previous_position is not None and position <= previous_position:
            fail("coverage JSON LLVM segments must be in strictly increasing source order")
        parsed_segments.append((line, column, executions, has_count, is_region_entry, is_gap))
        previous_position = position

    evidence: dict[int, bool] = {}
    for index, (line, _column, executions, has_count, _region_entry, is_gap) in enumerate(parsed_segments):
        if has_count and not is_gap:
            if index + 1 == len(parsed_segments):
                fail("coverage JSON active LLVM segment has no terminating boundary")
            next_line, next_column, *_rest = parsed_segments[index + 1]
            # A next boundary at column 1 begins a new line; otherwise its line
            # still contains code governed by the current segment interval.
            final_line = next_line - 1 if next_column == 1 else next_line
            for executable_line in range(line, final_line + 1):
                evidence[executable_line] = evidence.get(executable_line, False) or executions > 0
    return evidence


def percent(covered: int, count: int) -> float:
    return round((covered / count) * 100, 2) if count else 100.0


def meets_minimum(covered: int, count: int, minimum_percent: float) -> bool:
    """Compare the exact ratio; rounded percentages are presentation-only."""
    if count == 0:
        return True
    return (
        Decimal(covered) * Decimal(100)
        >= Decimal(count) * Decimal(str(minimum_percent))
    )


def source_coverage_by_target(
    payload: dict[str, object], root: Path
) -> tuple[dict[str, dict[str, object]], dict[Path, dict[int, bool]]]:
    by_target: dict[str, dict[str, object]] = {}
    evidence_by_path: dict[Path, dict[int, bool]] = {}
    source_root = (root / "Sources").resolve()
    for item in coverage_files(payload, root):
        filename = item["_resolvedFilename"]
        assert isinstance(filename, Path)
        relative = filename.relative_to(source_root)
        target = relative.parts[0]
        covered, count = summary_line_counts(item)
        bucket = by_target.setdefault(target, {"covered": 0, "count": 0})
        bucket["covered"] = int(bucket["covered"]) + covered
        bucket["count"] = int(bucket["count"]) + count
        evidence_by_path[filename] = executable_line_evidence(item)
    for bucket in by_target.values():
        bucket["percent"] = percent(int(bucket["covered"]), int(bucket["count"]))
    return by_target, evidence_by_path


def compiled_source_paths_from_build_description(
    description_path: Path, root: Path
) -> set[Path]:
    """Return package Sources that SwiftPM proved were inputs to this build."""
    try:
        payload = json.loads(description_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load SwiftPM build description {description_path}: {error}")
    commands = payload.get("swiftCommands")
    if not isinstance(commands, dict):
        fail(f"SwiftPM build description has no swiftCommands map: {description_path}")

    source_root = (root / "Sources").resolve()
    compiled: set[Path] = set()
    for command in commands.values():
        if not isinstance(command, dict):
            fail(f"SwiftPM build description contains an invalid Swift command: {description_path}")
        sources = command.get("sources")
        if not isinstance(sources, list) or not all(isinstance(item, str) for item in sources):
            fail(f"SwiftPM build description contains invalid Swift sources: {description_path}")
        for raw_source in sources:
            source = Path(raw_source)
            resolved = (source if source.is_absolute() else root / source).resolve()
            try:
                resolved.relative_to(source_root)
            except ValueError:
                continue
            if resolved.suffix == ".swift":
                compiled.add(resolved)
    if not compiled:
        fail(f"SwiftPM build description contains no package Sources inputs: {description_path}")
    return compiled


def changed_source_line_coverage(
    root: Path,
    changed: dict[str, set[int]],
    evidence_by_path: dict[Path, dict[int, bool]],
    compiled_source_paths: set[Path] | None = None,
) -> tuple[int, int, list[dict[str, object]], list[str], list[str]]:
    covered = 0
    count = 0
    files: list[dict[str, object]] = []
    unmatched_files: list[str] = []
    no_executable_line_files: list[str] = []
    for relative, lines in sorted(changed.items()):
        parts = Path(relative).parts
        if (
            len(parts) < 3
            or parts[0] != "Sources"
            or not relative.endswith(".swift")
            or not lines
        ):
            continue
        source_path = (root / relative).resolve()
        evidence = evidence_by_path.get(source_path)
        if evidence is None:
            # LLVM omits declaration/import-only files from its coverage map.
            # Treat them as non-executable only when this exact SwiftPM build
            # independently proves that the file was a compiler input.
            if compiled_source_paths is not None and source_path in compiled_source_paths:
                no_executable_line_files.append(relative)
            else:
                unmatched_files.append(relative)
            continue
        executable = sorted(line for line in lines if line in evidence)
        file_covered = sum(1 for line in executable if evidence[line])
        covered += file_covered
        count += len(executable)
        if executable:
            files.append({"path": relative, "covered": file_covered, "count": len(executable), "lines": executable})
        else:
            no_executable_line_files.append(relative)
    return covered, count, files, unmatched_files, no_executable_line_files


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
        "--skip-build",
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
            xctest_pids = descendant_xctest_pids(process.pid)
            terminate_coverage_batch(process, xctest_pids)
            assert_pids_reaped(xctest_pids)
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


def descendant_xctest_pids(root_pid: int) -> set[int]:
    """Return the real xctest descendants before their wrapper is reaped."""
    try:
        rows = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,command="], text=True, stderr=subprocess.DEVNULL
        ).splitlines()
    except (OSError, subprocess.CalledProcessError):
        fail("cannot inspect xctest descendants after a timed-out coverage batch")
    return xctest_pids_from_process_rows(root_pid, rows)


def xctest_pids_from_process_rows(root_pid: int, rows: list[str]) -> set[int]:
    children: dict[int, set[int]] = {}
    commands: dict[int, str] = {}
    for row in rows:
        fields = row.strip().split(None, 2)
        if len(fields) != 3:
            continue
        try:
            pid, parent = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        children.setdefault(parent, set()).add(pid)
        commands[pid] = fields[2]
    descendants: set[int] = set()
    pending = list(children.get(root_pid, set()))
    while pending:
        pid = pending.pop()
        descendants.add(pid)
        pending.extend(children.get(pid, set()))
    return {pid for pid in descendants if ".xctest/Contents/MacOS/" in commands.get(pid, "")}


def terminate_coverage_batch(process: subprocess.Popen[object], xctest_pids: set[int]) -> None:
    """TERM then bounded KILL the wrapper group and its captured xctest children."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    # A misbehaving runner may move the test process to another group. The
    # snapshot made before wrapper cleanup keeps retry fail-closed in that case.
    for pid in xctest_pids:
        if pid_exists(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def pid_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def assert_pids_reaped(pids: set[int], timeout_seconds: float = 2) -> None:
    deadline = time.monotonic() + timeout_seconds
    while any(pid_exists(pid) for pid in pids) and time.monotonic() < deadline:
        time.sleep(0.02)
    remaining = sorted(pid for pid in pids if pid_exists(pid))
    if remaining:
        fail("coverage batch left xctest descendants after timeout: " + ", ".join(map(str, remaining)))


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


def run_coverage(root: Path, scratch_path: Path) -> tuple[Path, Path]:
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
        build_description = test_binary.parents[3] / "description.json"
        if not build_description.is_file():
            fail(f"SwiftPM build description is missing: {build_description}")
        shutil.rmtree(profile_directory)
        return coverage_path, build_description
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
    parser.add_argument(
        "--swift-build-description",
        type=Path,
        help="SwiftPM description.json paired with --coverage-json; proves declaration-only files were compiled",
    )
    parser.add_argument(
        "--diff-base",
        help="offline git commit/ref used for changed-line checks (defaults to QUALITY_DIFF_BASE, GITHUB_BASE_REF, then HEAD)",
    )
    parser.add_argument("--result-json", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        baseline_payload = load_quality_baseline(args.baseline)
        source_targets = target_directories(root, "Sources")
        target_minimums = baseline_payload["sourceLineCoveragePercentMinimumByTarget"]
        assert isinstance(target_minimums, dict)
        validate_target_mapping(
            target_minimums, source_targets, "sourceLineCoveragePercentMinimumByTarget"
        )
        diff_base = resolve_diff_base(root, args.diff_base)
        changed = changed_lines(root, diff_base.resolved)
    except QualityGateError as error:
        fail(str(error))
    minimum = float(baseline_payload["sourceLineCoveragePercentMinimum"])
    changed_minimum = float(baseline_payload["changedExecutableSourceLineCoveragePercentMinimum"])

    if args.coverage_json:
        coverage_path = args.coverage_json.resolve()
        build_description_path = (
            args.swift_build_description.resolve()
            if args.swift_build_description
            else None
        )
    else:
        if args.swift_build_description:
            fail("--swift-build-description is only valid with --coverage-json")
        coverage_path, build_description_path = run_coverage(
            root,
            Path(
                os.environ.get(
                    "SWIFT_COVERAGE_SCRATCH_PATH",
                    str(root / ".build" / "coverage"),
                )
            ),
        )
    compiled_source_paths = (
        compiled_source_paths_from_build_description(build_description_path, root)
        if build_description_path is not None
        else None
    )
    try:
        coverage_payload = json.loads(coverage_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load coverage JSON {coverage_path}: {error}")
    by_target, evidence_by_path = source_coverage_by_target(coverage_payload, root)
    if compiled_source_paths is not None:
        coverage_sources_missing_from_build = sorted(
            path.relative_to(root).as_posix()
            for path in evidence_by_path
            if path not in compiled_source_paths
        )
        if coverage_sources_missing_from_build:
            fail(
                "SwiftPM build description does not match coverage Sources: "
                + ", ".join(coverage_sources_missing_from_build)
            )
    overall_covered = sum(int(bucket["covered"]) for bucket in by_target.values())
    overall_count = sum(int(bucket["count"]) for bucket in by_target.values())
    if overall_count == 0:
        fail("coverage JSON contains no executable lines under Sources")
    overall_percent = percent(overall_covered, overall_count)
    overall_meets_minimum = meets_minimum(overall_covered, overall_count, minimum)
    target_result: dict[str, dict[str, object]] = {}
    failed_targets: list[str] = []
    for target in sorted(source_targets):
        bucket = by_target.get(target, {"covered": 0, "count": 0, "percent": 0.0})
        target_covered = int(bucket["covered"])
        target_count = int(bucket["count"])
        target_percent = float(bucket["percent"])
        target_minimum = float(target_minimums[target])
        target_meets_minimum = target_count > 0 and meets_minimum(
            target_covered, target_count, target_minimum
        )
        target_result[target] = {
            "covered": target_covered,
            "count": target_count,
            "percent": target_percent,
            "minimumPercent": target_minimum,
            "meetsMinimum": target_meets_minimum,
        }
        if not target_meets_minimum:
            failed_targets.append(target)
    (
        changed_covered,
        changed_count,
        changed_files,
        unmatched_changed_files,
        no_executable_changed_line_files,
    ) = changed_source_line_coverage(
        root,
        changed,
        evidence_by_path,
        compiled_source_paths,
    )
    changed_percent = percent(changed_covered, changed_count)
    changed_meets_minimum = not unmatched_changed_files and meets_minimum(
        changed_covered, changed_count, changed_minimum
    )
    result = {
        "schemaVersion": 2,
        "sourceLines": {
            "covered": overall_covered,
            "count": overall_count,
            "percent": overall_percent,
            "minimumPercent": minimum,
            "meetsMinimum": overall_meets_minimum,
        },
        "targets": target_result,
        "changedExecutableSourceLines": {
            "covered": changed_covered,
            "count": changed_count,
            "percent": changed_percent,
            "minimumPercent": changed_minimum,
            "meetsMinimum": changed_meets_minimum,
            "files": changed_files,
            "unmatchedChangedSourceFiles": unmatched_changed_files,
            "noExecutableChangedLineFiles": no_executable_changed_line_files,
        },
        "diffBase": diff_base.resolved,
        "requestedDiffBase": diff_base.requested,
        "usedAllZeroDiffBaseFallback": diff_base.used_all_zero_fallback,
        "coverageJSON": str(coverage_path),
        "swiftBuildDescription": (
            str(build_description_path) if build_description_path is not None else None
        ),
    }
    if args.result_json:
        args.result_json.parent.mkdir(parents=True, exist_ok=True)
        args.result_json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if not overall_meets_minimum:
        fail(f"Sources line coverage {overall_percent:.2f}% is below progressive baseline {minimum:.2f}%")
    if failed_targets:
        fail(f"Sources target coverage is below its progressive baseline (or has no executable lines): {', '.join(failed_targets)}")
    if unmatched_changed_files:
        fail(
            "coverage JSON contains no file entry for changed Sources Swift files: "
            + ", ".join(unmatched_changed_files)
        )
    if not changed_meets_minimum:
        fail(
            f"changed executable Sources line coverage {changed_percent:.2f}% is below required {changed_minimum:.2f}% "
            f"({changed_covered}/{changed_count} lines)"
        )
    print(
        f"swift coverage gate: passed ({overall_covered}/{overall_count} Sources lines, "
        f"{overall_percent:.2f}%; overall minimum {minimum:.2f}%; "
        f"changed executable lines {changed_covered}/{changed_count}, {changed_percent:.2f}% "
        f"minimum {changed_minimum:.2f}%)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
