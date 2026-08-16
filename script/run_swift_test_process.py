#!/usr/bin/env python3
"""Run the complete SwiftPM test inventory in short, auditable processes."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


ALLOWED_TARGETS = (
    "PersonalSitePublisherMacTests",
    "PublishingWorkbenchCoreTests",
)
MAC_TARGET = "PersonalSitePublisherMacTests"
CORE_TARGET = "PublishingWorkbenchCoreTests"
CACHE_SUITE = "WorkbenchImageTwoTierCacheTests"
SETTINGS_SUITE = "SettingsSearchAndSavePresentationTests"
# These tests launch a real child process and keep a streaming reader alive.
# Run each method in its own xctest host so older XCTest runtimes cannot strand
# an entire multi-suite batch.
CORE_CASE_ISOLATED_SUITES = ("CodexAppServerClientTests",)
INVENTORY_PATTERN = re.compile(
    r"^(PersonalSitePublisherMacTests|PublishingWorkbenchCoreTests)\."
    r"([A-Za-z_][A-Za-z0-9_]*)/([A-Za-z_][A-Za-z0-9_]*)(\(\))?$"
)
XCTEST_COUNT_PATTERN = re.compile(r"Executed\s+(\d+)\s+tests?")
SWIFT_TESTING_COUNT_PATTERN = re.compile(r"Test run with\s+(\d+)\s+tests?")

ACTIVE_PROCESS: subprocess.Popen[str] | None = None
ACTIVE_PROCESS_GROUPS: set[int] = set()
TERMINATION_GRACE_SECONDS = 2.0
PROCESS_POLL_INTERVAL_SECONDS = 0.05
PROCESS_SNAPSHOT_TIMEOUT_SECONDS = 0.25
DEFAULT_SHARD_RETRIES = 1
MAX_SHARD_RETRIES = 1


@dataclasses.dataclass(frozen=True)
class TestSpec:
    raw: str
    target: str
    suite: str
    method: str
    is_swift_testing: bool


@dataclasses.dataclass(frozen=True)
class Shard:
    label: str
    slug: str
    filter_pattern: str
    tests: tuple[TestSpec, ...]

    @property
    def expected_xctest_count(self) -> int:
        return sum(not test.is_swift_testing for test in self.tests)

    @property
    def expected_swift_testing_count(self) -> int:
        return sum(test.is_swift_testing for test in self.tests)


@dataclasses.dataclass(frozen=True)
class ProcessResult:
    return_code: int
    timed_out: bool
    duration_seconds: float
    stdout: str


def fail(message: str) -> None:
    raise ValueError(message)


def configured_shard_retries(environment: dict[str, str]) -> int:
    raw_value = environment.get(
        "SWIFT_TEST_SHARD_RETRIES", str(DEFAULT_SHARD_RETRIES)
    )
    try:
        retries = int(raw_value)
    except ValueError:
        fail("SWIFT_TEST_SHARD_RETRIES must be a non-negative integer")
    if not 0 <= retries <= MAX_SHARD_RETRIES:
        fail(
            "SWIFT_TEST_SHARD_RETRIES must be between 0 and "
            f"{MAX_SHARD_RETRIES}"
        )
    return retries


def atomic_write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def process_snapshot() -> list[tuple[int, int, int, str]]:
    ps_binary = os.environ.get("PS_BIN", "/bin/ps")
    try:
        result = subprocess.run(
            [ps_binary, "-axo", "pid=,ppid=,pgid=,args="],
            check=False,
            text=True,
            capture_output=True,
            # Keep process discovery within the outer release gate's
            # five-second termination budget even if `ps` itself stalls.
            timeout=PROCESS_SNAPSHOT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    rows: list[tuple[int, int, int, str]] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        try:
            rows.append((int(fields[0]), int(fields[1]), int(fields[2]), fields[3]))
        except ValueError:
            continue
    return rows


def descendant_processes(
    root_pid: int, snapshot: list[tuple[int, int, int, str]]
) -> list[tuple[int, int, int, str]]:
    descendants: list[tuple[int, int, int, str]] = []
    parent_ids = {root_pid}
    while parent_ids:
        generation = [row for row in snapshot if row[1] in parent_ids]
        if not generation:
            break
        descendants.extend(generation)
        parent_ids = {row[0] for row in generation}
    return descendants


def tracked_process_groups(root_pid: int) -> set[int]:
    snapshot = process_snapshot()
    groups = {root_pid}
    groups.update(row[2] for row in descendant_processes(root_pid, snapshot))
    return {group for group in groups if group > 0}


def record_process_groups(root_pid: int, process_groups: set[int]) -> None:
    process_groups.update(tracked_process_groups(root_pid))


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_process_groups(
    process: subprocess.Popen[str],
    process_groups: set[int],
    grace_seconds: float,
    *,
    refresh_groups: bool = True,
) -> None:
    groups = set(process_groups)
    if refresh_groups:
        groups.update(tracked_process_groups(process.pid))
    for process_group_id in sorted(groups, reverse=True):
        try:
            os.killpg(process_group_id, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if not any(process_group_exists(group) for group in groups):
            break
        time.sleep(0.05)

    for process_group_id in sorted(groups, reverse=True):
        if not process_group_exists(process_group_id):
            continue
        try:
            os.killpg(process_group_id, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def forwarded_signal(signum: int, _frame: object) -> None:
    process = ACTIVE_PROCESS
    if process is not None:
        # The outer release gate allows five seconds before SIGKILL.  Avoid a
        # fresh `ps` call here: it can itself block for ten seconds.  The main
        # loop continuously records detached descendant groups, so the signal
        # path can stay within the two-second cleanup budget.
        terminate_process_groups(
            process,
            ACTIVE_PROCESS_GROUPS,
            TERMINATION_GRACE_SECONDS,
            refresh_groups=False,
        )
    raise SystemExit(128 + signum)


def is_xctest_command(command: str) -> bool:
    executable = command.strip().split(None, 1)[0] if command.strip() else ""
    basename = Path(executable).name
    return (
        basename == "xctest"
        or ".xctest/" in executable
        or basename.endswith(".xctest")
    )


def parse_xctest_pids(
    snapshot: list[tuple[int, int, int, str]], root_pid: int
) -> list[int]:
    matches: list[int] = []
    for pid, _parent_pid, _process_group_id, command in descendant_processes(root_pid, snapshot):
        if is_xctest_command(command):
            matches.append(pid)
    return sorted(set(matches))


def capture_timeout_sample(root_pid: int, sample_path: Path) -> None:
    sample_path.parent.mkdir(parents=True, exist_ok=True)
    pids = parse_xctest_pids(process_snapshot(), root_pid)
    if not pids:
        sample_path.write_text(
            f"No descendant .xctest process found for Swift process {root_pid}.\n",
            encoding="utf-8",
        )
        return

    sample_binary = os.environ.get("SAMPLE_BIN", "/usr/bin/sample")
    command = [sample_binary, str(pids[0]), "5", "1", "-file", str(sample_path)]
    try:
        result = subprocess.run(command, check=False, text=True, capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as error:
        sample_path.write_text(f"sample failed to execute: {error}\n", encoding="utf-8")
        return
    if result.returncode != 0:
        sample_path.write_text(
            "sample failed with exit code "
            f"{result.returncode}:\n{result.stdout}{result.stderr}",
            encoding="utf-8",
        )


def run_child(
    command: list[str],
    *,
    cwd: Path,
    log_path: Path,
    timeout_seconds: float,
    sample_path: Path,
    echo_stdout: bool,
) -> ProcessResult:
    global ACTIVE_PROCESS, ACTIVE_PROCESS_GROUPS

    log_path.parent.mkdir(parents=True, exist_ok=True)
    if sample_path.exists():
        sample_path.unlink()
    started_at = time.monotonic()
    captured_stdout: list[str] = []
    log_lock = threading.Lock()

    with log_path.open("w", encoding="utf-8", buffering=1) as log_file:
        log_file.write(f"command: {json.dumps(command, ensure_ascii=False)}\n")
        log_file.write(f"timeoutSeconds: {timeout_seconds}\n")
        log_file.write(f"terminationGraceSeconds: {TERMINATION_GRACE_SECONDS}\n")
        try:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                env=os.environ.copy(),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                start_new_session=True,
            )
        except OSError as error:
            message = f"unable to launch command: {error}\n"
            log_file.write(message)
            print(message, end="", file=sys.stderr)
            return ProcessResult(127, False, time.monotonic() - started_at, "")

        ACTIVE_PROCESS = process
        ACTIVE_PROCESS_GROUPS = {process.pid}

        def pump(stream: object, destination: object, capture: bool, echo: bool) -> None:
            if stream is None:
                return
            for line in iter(stream.readline, ""):
                if capture:
                    captured_stdout.append(line)
                with log_lock:
                    log_file.write(line)
                if echo:
                    destination.write(line)
                    destination.flush()
            stream.close()

        stdout_thread = threading.Thread(
            target=pump,
            args=(process.stdout, sys.stdout, True, echo_stdout),
            daemon=True,
        )
        stderr_thread = threading.Thread(
            target=pump,
            args=(process.stderr, sys.stderr, False, True),
            daemon=True,
        )
        stdout_thread.start()
        stderr_thread.start()

        timed_out = False
        return_code = 124
        deadline = time.monotonic() + timeout_seconds
        try:
            while True:
                # The xctest host can detach into a new session.  Record every
                # observed descendant group before waiting so a later leader
                # exit cannot hide it from cleanup.
                record_process_groups(process.pid, ACTIVE_PROCESS_GROUPS)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    timeout_message = f"process timed out after {timeout_seconds} seconds\n"
                    with log_lock:
                        log_file.write(timeout_message)
                    print(timeout_message, end="", file=sys.stderr)
                    record_process_groups(process.pid, ACTIVE_PROCESS_GROUPS)
                    capture_timeout_sample(process.pid, sample_path)
                    break
                try:
                    return_code = process.wait(
                        timeout=min(remaining, PROCESS_POLL_INTERVAL_SECONDS)
                    )
                    # A successful leader exit can still leave an already
                    # observed detached xctest group behind.
                    record_process_groups(process.pid, ACTIVE_PROCESS_GROUPS)
                    break
                except subprocess.TimeoutExpired:
                    continue
        finally:
            terminate_process_groups(
                process, set(ACTIVE_PROCESS_GROUPS), TERMINATION_GRACE_SECONDS
            )
            stdout_thread.join(timeout=2)
            stderr_thread.join(timeout=2)
            ACTIVE_PROCESS = None
            ACTIVE_PROCESS_GROUPS = set()

    return ProcessResult(
        return_code=return_code,
        timed_out=timed_out,
        duration_seconds=time.monotonic() - started_at,
        stdout="".join(captured_stdout),
    )


def manifest_test_targets(package_path: Path) -> list[str]:
    try:
        source = package_path.read_text(encoding="utf-8")
    except OSError as error:
        fail(f"cannot read Package.swift: {error}")
    targets = re.findall(r"\.testTarget\s*\(\s*name\s*:\s*\"([^\"]+)\"", source)
    if not targets:
        fail("Package.swift declares no test targets in the supported form")
    if len(targets) != len(set(targets)):
        fail("Package.swift contains duplicate test target declarations")
    if set(targets) != set(ALLOWED_TARGETS):
        fail(
            "unexpected Swift test target set: expected "
            f"{list(ALLOWED_TARGETS)}, found {targets}"
        )
    return targets


def parse_inventory(output: str) -> list[TestSpec]:
    rows = [line.strip() for line in output.splitlines() if line.strip()]
    if not rows:
        fail("swift test list returned an empty inventory")
    if len(rows) != len(set(rows)):
        fail("swift test list returned duplicate test specifications")

    tests: list[TestSpec] = []
    for row in rows:
        match = INVENTORY_PATTERN.fullmatch(row)
        if match is None:
            fail(f"unsupported or unknown Swift test inventory row: {row}")
        target, suite, method, parentheses = match.groups()
        tests.append(
            TestSpec(
                raw=row,
                target=target,
                suite=suite,
                method=method,
                is_swift_testing=parentheses is not None,
            )
        )
    return sorted(tests, key=lambda test: test.raw)


def load_minimum_counts(path: Path) -> dict[str, int]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read Swift test count baselines: {error}")
    minimums = payload.get("swiftTestMinimumCountsByTarget")
    if not isinstance(minimums, dict) or set(minimums) != set(ALLOWED_TARGETS):
        fail("quality baselines must define every allowed Swift test target and no others")
    if not all(isinstance(value, int) and not isinstance(value, bool) and value > 0 for value in minimums.values()):
        fail("Swift test target minimum counts must be positive integers")
    return {str(target): int(count) for target, count in minimums.items()}


def validate_minimum_counts(tests: list[TestSpec], minimums: dict[str, int]) -> dict[str, int]:
    counts = {target: 0 for target in ALLOWED_TARGETS}
    for test in tests:
        counts[test.target] += 1
    for target, minimum in minimums.items():
        if counts[target] < minimum:
            fail(f"Swift test inventory for {target} fell below {minimum}: found {counts[target]}")
    return counts


def make_suite_filter(target: str, suites: list[str]) -> str:
    alternatives = "|".join(re.escape(suite) for suite in suites)
    return rf"^{re.escape(target)}\.({alternatives})/"


def batch_suites(
    tests: list[TestSpec],
    *,
    target: str,
    excluded_suites: set[str],
    maximum_suites: int,
    maximum_tests: int,
) -> list[tuple[list[str], list[TestSpec]]]:
    by_suite: dict[str, list[TestSpec]] = {}
    for test in tests:
        if test.target == target and test.suite not in excluded_suites:
            by_suite.setdefault(test.suite, []).append(test)

    batches: list[tuple[list[str], list[TestSpec]]] = []
    current_suites: list[str] = []
    current_tests: list[TestSpec] = []
    for suite in sorted(by_suite):
        suite_tests = sorted(by_suite[suite], key=lambda test: test.raw)
        would_exceed = current_suites and (
            len(current_suites) >= maximum_suites
            or len(current_tests) + len(suite_tests) > maximum_tests
        )
        if would_exceed:
            batches.append((current_suites, current_tests))
            current_suites = []
            current_tests = []
        current_suites.append(suite)
        current_tests.extend(suite_tests)
    if current_suites:
        batches.append((current_suites, current_tests))
    return batches


def build_shards(tests: list[TestSpec]) -> list[Shard]:
    cache_tests = tuple(
        test for test in tests if test.target == MAC_TARGET and test.suite == CACHE_SUITE
    )
    settings_tests = tuple(
        test for test in tests if test.target == MAC_TARGET and test.suite == SETTINGS_SUITE
    )
    if not cache_tests:
        fail(f"required isolated suite is missing: {MAC_TARGET}.{CACHE_SUITE}")
    if not settings_tests:
        fail(f"required isolated suite is missing: {MAC_TARGET}.{SETTINGS_SUITE}")

    shards: list[Shard] = [
        Shard(
            label=f"{MAC_TARGET}.{CACHE_SUITE}",
            slug="cache",
            filter_pattern=make_suite_filter(MAC_TARGET, [CACHE_SUITE]),
            tests=cache_tests,
        )
    ]
    for index, test in enumerate(sorted(settings_tests, key=lambda item: item.raw), start=1):
        shards.append(
            Shard(
                label=test.raw,
                slug=f"settings-{index:02d}",
                filter_pattern=f"^{re.escape(test.raw)}$",
                tests=(test,),
            )
        )

    mac_case_tests = tuple(
        sorted(
            (
                test
                for test in tests
                if test.target == MAC_TARGET
                and test.suite not in {CACHE_SUITE, SETTINGS_SUITE}
            ),
            key=lambda item: item.raw,
        )
    )
    for index, test in enumerate(mac_case_tests, start=1):
        shards.append(
            Shard(
                label=test.raw,
                slug=f"mac-{index:02d}",
                filter_pattern=f"^{re.escape(test.raw)}$",
                tests=(test,),
            )
        )

    core_case_tests = tuple(
        sorted(
            (
                test
                for test in tests
                if test.target == CORE_TARGET
                and test.suite in CORE_CASE_ISOLATED_SUITES
            ),
            key=lambda item: item.raw,
        )
    )
    for index, test in enumerate(core_case_tests, start=1):
        shards.append(
            Shard(
                label=test.raw,
                slug=f"core-case-{index:02d}",
                filter_pattern=f"^{re.escape(test.raw)}$",
                tests=(test,),
            )
        )

    core_batches = batch_suites(
        tests,
        target=CORE_TARGET,
        excluded_suites=set(CORE_CASE_ISOLATED_SUITES),
        maximum_suites=12,
        maximum_tests=150,
    )
    for index, (suites, batch_tests) in enumerate(core_batches, start=1):
        shards.append(
            Shard(
                label=f"{CORE_TARGET} batch {index}",
                slug=f"core-{index:02d}",
                filter_pattern=make_suite_filter(CORE_TARGET, suites),
                tests=tuple(batch_tests),
            )
        )

    assignments: dict[str, int] = {test.raw: 0 for test in tests}
    for shard in shards:
        matcher = re.compile(shard.filter_pattern)
        for test in tests:
            if matcher.search(test.raw):
                assignments[test.raw] += 1
        if not shard.tests:
            fail(f"generated an empty Swift test shard: {shard.label}")
    invalid = [raw for raw, count in assignments.items() if count != 1]
    if invalid:
        fail(f"Swift test partition has missing or duplicate assignments: {invalid[:5]}")
    return shards


def parse_executed_counts(log_text: str, shard: Shard) -> tuple[int | None, int | None]:
    xctest_matches = [int(value) for value in XCTEST_COUNT_PATTERN.findall(log_text)]
    swift_matches = [int(value) for value in SWIFT_TESTING_COUNT_PATTERN.findall(log_text)]
    xctest_count = max(xctest_matches) if xctest_matches else None
    swift_count = swift_matches[-1] if swift_matches else None
    if shard.expected_xctest_count == 0 and xctest_count is None:
        xctest_count = 0
    if shard.expected_swift_testing_count == 0 and swift_count is None:
        swift_count = 0
    return xctest_count, swift_count


def shard_payload(shard: Shard, output_directory: Path) -> dict[str, object]:
    return {
        "label": shard.label,
        "slug": shard.slug,
        "filter": shard.filter_pattern,
        "status": "pending",
        "expectedXCTestCount": shard.expected_xctest_count,
        "expectedSwiftTestingCount": shard.expected_swift_testing_count,
        "tests": [test.raw for test in shard.tests],
        "logPath": str(output_directory / f"shard-{shard.slug}.log"),
        "samplePath": str(output_directory / f"shard-{shard.slug}.sample.txt"),
        "attempts": [],
    }


def run_all(root: Path) -> int:
    output_directory = root / ".build" / "swift-test-shards"
    output_directory.mkdir(parents=True, exist_ok=True)
    result_path = output_directory / "result.json"
    inventory_path = output_directory / "inventory.txt"
    swift_binary = os.environ.get("SWIFT_BIN", "swift")
    list_timeout = float(os.environ.get("SWIFT_TEST_LIST_TIMEOUT_SECONDS", "360"))
    shard_timeout = float(os.environ.get("SWIFT_TEST_SHARD_TIMEOUT_SECONDS", "120"))

    result: dict[str, object] = {
        "schemaVersion": 1,
        "status": "running",
        "inventory": {},
        "shards": [],
    }
    atomic_write_json(result_path, result)

    try:
        shard_retries = configured_shard_retries(os.environ)
        result["shardRetries"] = shard_retries
        manifest_test_targets(root / "Package.swift")
        minimums = load_minimum_counts(root / "script" / "quality_baselines.json")
    except ValueError as error:
        result.update({"status": "failed", "error": str(error)})
        atomic_write_json(result_path, result)
        print(f"swift test shards: {error}", file=sys.stderr)
        return 2

    list_command = [swift_binary, "test", "--disable-sandbox", "list"]
    print("swift test shards: building and reading the complete test inventory")
    list_process = run_child(
        list_command,
        cwd=root,
        log_path=output_directory / "build-list.log",
        timeout_seconds=list_timeout,
        sample_path=output_directory / "build-list.sample.txt",
        echo_stdout=False,
    )
    result["inventoryCommand"] = list_command
    result["inventoryDurationSeconds"] = round(list_process.duration_seconds, 3)
    if list_process.return_code != 0:
        result.update(
            {
                "status": "timed_out" if list_process.timed_out else "failed",
                "returnCode": list_process.return_code,
                "error": "swift test list did not complete successfully",
            }
        )
        atomic_write_json(result_path, result)
        return list_process.return_code

    try:
        tests = parse_inventory(list_process.stdout)
        counts_by_target = validate_minimum_counts(tests, minimums)
        shards = build_shards(tests)
    except ValueError as error:
        result.update({"status": "failed", "returnCode": 2, "error": str(error)})
        atomic_write_json(result_path, result)
        print(f"swift test shards: {error}", file=sys.stderr)
        return 2

    inventory_path.write_text("\n".join(test.raw for test in tests) + "\n", encoding="utf-8")
    result["inventory"] = {
        "path": str(inventory_path),
        "totalCount": len(tests),
        "countsByTarget": counts_by_target,
        "xctestCount": sum(not test.is_swift_testing for test in tests),
        "swiftTestingCount": sum(test.is_swift_testing for test in tests),
        "minimumCountsByTarget": minimums,
    }
    result["shards"] = [shard_payload(shard, output_directory) for shard in shards]
    atomic_write_json(result_path, result)
    print(
        f"swift test shards: inventory {len(tests)} tests, "
        f"{len(shards)} isolated processes"
    )

    shard_results = result["shards"]
    assert isinstance(shard_results, list)
    for index, shard in enumerate(shards):
        entry = shard_results[index]
        assert isinstance(entry, dict)
        command = [
            swift_binary,
            "test",
            "--disable-sandbox",
            "--skip-build",
            "--filter",
            shard.filter_pattern,
        ]
        entry.update({"status": "running", "command": command})
        attempts = entry["attempts"]
        assert isinstance(attempts, list)
        atomic_write_json(result_path, result)
        print(
            f"swift test shards: running {index + 1}/{len(shards)} "
            f"{shard.label} ({len(shard.tests)} tests)",
            flush=True,
        )
        process_result: ProcessResult | None = None
        for attempt_number in range(1, shard_retries + 2):
            if attempt_number == 1:
                log_path = Path(str(entry["logPath"]))
                sample_path = Path(str(entry["samplePath"]))
            else:
                attempt_stem = output_directory / (
                    f"shard-{shard.slug}.attempt-{attempt_number}"
                )
                log_path = Path(f"{attempt_stem}.log")
                sample_path = Path(f"{attempt_stem}.sample.txt")
            attempt = {
                "attempt": attempt_number,
                "retry": attempt_number > 1,
                "status": "running",
                "logPath": str(log_path),
                "samplePath": str(sample_path),
            }
            attempts.append(attempt)
            entry.update(
                {
                    "attempts": attempts,
                    "logPath": str(log_path),
                    "samplePath": str(sample_path),
                }
            )
            atomic_write_json(result_path, result)
            process_result = run_child(
                command,
                cwd=root,
                log_path=log_path,
                timeout_seconds=shard_timeout,
                sample_path=sample_path,
                echo_stdout=True,
            )
            attempt["durationSeconds"] = round(process_result.duration_seconds, 3)
            attempt["returnCode"] = process_result.return_code
            attempt["timedOut"] = process_result.timed_out
            attempt["status"] = (
                "timed_out"
                if process_result.timed_out
                else "passed"
                if process_result.return_code == 0
                else "failed"
            )
            entry["durationSeconds"] = attempt["durationSeconds"]
            entry["returnCode"] = process_result.return_code
            entry["timedOut"] = process_result.timed_out
            entry["retryCount"] = attempt_number - 1
            atomic_write_json(result_path, result)
            if not process_result.timed_out or attempt_number > shard_retries:
                break
            entry["status"] = "retrying"
            atomic_write_json(result_path, result)
            print(
                f"swift test shards: timeout on {shard.label}; "
                f"retrying ({attempt_number}/{shard_retries})",
                file=sys.stderr,
                flush=True,
            )

        assert process_result is not None
        if process_result.return_code != 0:
            entry["status"] = "timed_out" if process_result.timed_out else "failed"
            result.update(
                {
                    "status": entry["status"],
                    "returnCode": process_result.return_code,
                    "failedShard": shard.label,
                }
            )
            atomic_write_json(result_path, result)
            return process_result.return_code

        log_text = log_path.read_text(encoding="utf-8")
        executed_xctest, executed_swift = parse_executed_counts(log_text, shard)
        entry["executedXCTestCount"] = executed_xctest
        entry["executedSwiftTestingCount"] = executed_swift
        if (
            executed_xctest != shard.expected_xctest_count
            or executed_swift != shard.expected_swift_testing_count
        ):
            entry.update(
                {
                    "status": "failed",
                    "error": "completed test counts did not match the inventory partition",
                }
            )
            result.update({"status": "failed", "returnCode": 2, "failedShard": shard.label})
            atomic_write_json(result_path, result)
            print(
                "swift test shards: executed counts did not match inventory for "
                f"{shard.label}",
                file=sys.stderr,
            )
            return 2
        entry["status"] = "passed"
        atomic_write_json(result_path, result)

    result.update({"status": "passed", "returnCode": 0})
    atomic_write_json(result_path, result)
    print(f"swift test shards: all {len(shards)} isolated processes passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()

    global TERMINATION_GRACE_SECONDS
    TERMINATION_GRACE_SECONDS = float(
        os.environ.get("SWIFT_TEST_TERMINATION_GRACE_SECONDS", "2")
    )
    signal.signal(signal.SIGTERM, forwarded_signal)
    signal.signal(signal.SIGINT, forwarded_signal)
    return run_all(arguments.root.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
