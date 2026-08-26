#!/usr/bin/env python3
"""Run the complete SwiftPM test inventory in short, auditable processes."""

from __future__ import annotations

import argparse
import ctypes
import dataclasses
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Collection
from pathlib import Path


MAC_TARGET = "PersonalSitePublisherMacTests"
CORE_TARGET = "PublishingWorkbenchCoreTests"
SETTINGS_SUITE = "SettingsSearchAndSavePresentationTests"
WEB_CONTENT_SECURITY_SUITE = "WebContentNetworkSecurityTests"
# These tests either launch a real child process with a streaming reader or
# install process-global URL loading hooks. Run each method in its own xctest
# host so one leaked continuation or global protocol registration cannot
# strand an entire multi-suite batch.
CORE_CASE_ISOLATED_SUITES = (
    "AIModelDiscoveryServiceTests",
    "CodexAppServerClientTests",
)
MAC_BATCH_MAX_SUITES = 4
MAC_BATCH_MAX_TESTS = 60
CORE_BATCH_MAX_SUITES = 12
CORE_BATCH_MAX_TESTS = 150
LEAF_BATCH_MAX_SUITES = 16
LEAF_BATCH_MAX_TESTS = 200
SWIFT_CACHE_ENVIRONMENT_KEYS = (
    "HOME",
    "XDG_CACHE_HOME",
    "CLANG_MODULE_CACHE_PATH",
    "SWIFT_MODULE_CACHE_PATH",
)
INVENTORY_PATTERN = re.compile(
    r"^([^\.\s/]+)\."
    r"([A-Za-z_][A-Za-z0-9_]*)/([A-Za-z_][A-Za-z0-9_]*)(\(\))?$"
)
XCTEST_COUNT_PATTERN = re.compile(r"Executed\s+(\d+)\s+tests?")
SWIFT_TESTING_COUNT_PATTERN = re.compile(r"Test run with\s+(\d+)\s+tests?")

ACTIVE_PROCESS: subprocess.Popen[str] | None = None
ACTIVE_PROCESS_GROUPS: set[int] = set()
ACTIVE_PROCESS_DESCENDANTS: set[int] = set()
ACTIVE_PROCESS_IDENTITIES: dict[int, tuple[str, str]] = {}
TERMINATION_GRACE_SECONDS = 2.0
PROCESS_POLL_INTERVAL_SECONDS = 0.05
PROCESS_SNAPSHOT_TIMEOUT_SECONDS = 0.25
DEFAULT_SHARD_RETRIES = 1
MAX_SHARD_RETRIES = 1


class _ProcBSDInfo(ctypes.Structure):
    """The stable identity fields from macOS sys/proc_info.h."""

    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


_LIBPROC: ctypes.CDLL | None | bool = None


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


def libproc_library() -> ctypes.CDLL | None:
    """Load macOS libproc once; return None on non-macOS or unavailable hosts."""

    global _LIBPROC
    if _LIBPROC is False:
        return None
    if isinstance(_LIBPROC, ctypes.CDLL):
        return _LIBPROC
    if sys.platform != "darwin":
        _LIBPROC = False
        return None
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_listchildpids.argtypes = [
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        library.proc_listchildpids.restype = ctypes.c_int
        library.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        library.proc_pidinfo.restype = ctypes.c_int
        library.proc_pidpath.argtypes = [
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_uint32,
        ]
        library.proc_pidpath.restype = ctypes.c_int
    except (AttributeError, OSError):
        _LIBPROC = False
        return None
    _LIBPROC = library
    return library


def native_child_process_ids(parent_pid: int) -> set[int] | None:
    """Return direct children through libproc, or None when unavailable."""

    library = libproc_library()
    if library is None:
        return None
    item_size = ctypes.sizeof(ctypes.c_int)
    capacity = item_size * 16
    for _ in range(4):
        buffer = ctypes.create_string_buffer(capacity)
        result = library.proc_listchildpids(
            parent_pid,
            ctypes.cast(buffer, ctypes.c_void_p),
            capacity,
        )
        if result < 0:
            return set()
        # `proc_listchildpids` returns a count of PIDs, while its input
        # capacity is expressed in bytes.  A one-child probe on macOS returns
        # 1 (not sizeof(pid_t)); keep the units explicit before sizing the
        # ctypes view and retrying a truncated result.
        count = result
        required_bytes = count * item_size
        # A full buffer may be a truncation as well as an exact fit; grow once
        # more so a busy runner cannot silently lose the last child slot.
        if required_bytes >= capacity:
            capacity = required_bytes + item_size * 4
            continue
        if count == 0:
            return set()
        values = (ctypes.c_int * count).from_buffer(buffer)
        return {int(value) for value in values if int(value) > 0}
    return set()


def native_descendant_process_ids(root_pid: int) -> set[int] | None:
    """Recursively discover descendants without invoking an external `ps`."""

    if libproc_library() is None:
        return None
    discovered: set[int] = set()
    pending = [root_pid]
    while pending:
        parent_pid = pending.pop()
        child_ids = native_child_process_ids(parent_pid)
        if child_ids is None:
            return None
        for child_pid in child_ids:
            if child_pid in discovered:
                continue
            discovered.add(child_pid)
            pending.append(child_pid)
    return discovered


def native_process_group_id(process_id: int) -> int | None:
    try:
        return os.getpgid(process_id)
    except (ProcessLookupError, PermissionError, OSError):
        return None


def native_process_identity(process_id: int) -> tuple[str, str] | None:
    """Return a PID-reuse-resistant start token from proc_pidinfo or /proc."""

    library = libproc_library()
    if library is not None:
        info = _ProcBSDInfo()
        result = library.proc_pidinfo(
            process_id,
            3,  # PROC_PIDTBSDINFO
            0,
            ctypes.byref(info),
            ctypes.sizeof(info),
        )
        if result >= ctypes.sizeof(info):
            return (
                "libproc-start",
                f"{int(info.pbi_start_tvsec)}:{int(info.pbi_start_tvusec)}",
            )

    stat_path = Path(f"/proc/{process_id}/stat")
    try:
        stat_fields = stat_path.read_text(encoding="utf-8").rsplit(")", 1)[1].split()
    except (OSError, IndexError):
        return None
    # After the comm field, index 19 is field 22 (process start ticks).
    if len(stat_fields) > 19:
        return "proc-start", stat_fields[19]
    return None


def native_process_path(process_id: int) -> str | None:
    library = libproc_library()
    if library is None:
        return None
    buffer = ctypes.create_string_buffer(4096)
    result = library.proc_pidpath(
        process_id,
        ctypes.cast(buffer, ctypes.c_void_p),
        len(buffer),
    )
    if result <= 0:
        return None
    return buffer.value.decode("utf-8", errors="replace")


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


def record_process_groups(
    root_pid: int,
    process_groups: set[int],
    process_ids: set[int] | None = None,
    process_identities: dict[int, tuple[str, str]] | None = None,
) -> None:
    snapshot = process_snapshot()
    descendants = descendant_processes(root_pid, snapshot)
    observed_ids = {row[0] for row in descendants}
    process_groups.add(root_pid)
    process_groups.update(row[2] for row in descendants if row[2] > 0)

    native_ids = native_descendant_process_ids(root_pid)
    if native_ids is not None:
        observed_ids.update(native_ids)
        for process_id in native_ids:
            process_group_id = native_process_group_id(process_id)
            if process_group_id is not None and process_group_id > 0:
                process_groups.add(process_group_id)

    if process_ids is not None:
        process_ids.update(observed_ids)
    if process_identities is not None:
        ps_commands = {row[0]: row[3] for row in descendants}
        for process_id in observed_ids:
            identity = native_process_identity(process_id)
            if identity is None and process_id in ps_commands:
                identity = ("ps-command", ps_commands[process_id])
            if identity is not None:
                process_identities.setdefault(process_id, identity)


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def process_exists(process_id: int) -> bool:
    try:
        os.kill(process_id, 0)
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
    process_ids: set[int] | None = None,
    process_identities: dict[int, tuple[str, str]] | None = None,
) -> None:
    groups = set(process_groups)
    descendants = set(process_ids or ())
    descendants.add(process.pid)
    identities = dict(process_identities or {})
    if refresh_groups:
        record_process_groups(process.pid, groups, descendants, identities)

    def identity_matches(process_id: int) -> bool:
        expected = identities.get(process_id)
        if expected is None:
            return process_id == process.pid
        current = native_process_identity(process_id)
        if current is None:
            return False
        return current == expected

    def signal_process_tree(signum: int) -> None:
        # A XCTest host can call setsid/setpgrp after discovery. Signal each
        # exact descendant PID as well as the observed session groups; this is
        # scoped to this runner's process tree and never uses process names.
        for process_id in sorted(descendants, reverse=True):
            if not identity_matches(process_id):
                continue
            try:
                os.kill(process_id, signum)
            except (ProcessLookupError, PermissionError):
                pass
        for process_group_id in sorted(groups, reverse=True):
            try:
                os.killpg(process_group_id, signum)
            except (ProcessLookupError, PermissionError):
                pass

    signal_process_tree(signal.SIGTERM)

    deadline = time.monotonic() + grace_seconds
    while time.monotonic() < deadline:
        if refresh_groups:
            record_process_groups(process.pid, groups, descendants, identities)
        if not any(process_exists(process_id) for process_id in descendants) and not any(
            process_group_exists(group) for group in groups
        ):
            break
        time.sleep(PROCESS_POLL_INTERVAL_SECONDS)

    signal_process_tree(signal.SIGKILL)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def forwarded_signal(signum: int, _frame: object) -> None:
    global ACTIVE_PROCESS_DESCENDANTS, ACTIVE_PROCESS_IDENTITIES
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
            process_ids=ACTIVE_PROCESS_DESCENDANTS,
            process_identities=ACTIVE_PROCESS_IDENTITIES,
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


def capture_timeout_sample(
    root_pid: int,
    sample_path: Path,
    process_ids: set[int] | None = None,
) -> None:
    sample_path.parent.mkdir(parents=True, exist_ok=True)
    pids = parse_xctest_pids(process_snapshot(), root_pid)
    if not pids and process_ids:
        for process_id in sorted(process_ids):
            if process_id == root_pid:
                continue
            process_path = native_process_path(process_id)
            if process_path and is_xctest_command(process_path):
                pids.append(process_id)
        if not pids:
            # libproc can identify the live descendant even when its executable
            # path is hidden by a shebang or a restricted `ps`; use it rather
            # than claiming that no descendant exists.
            pids = sorted(pid for pid in process_ids if pid != root_pid)
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
    environment: dict[str, str] | None = None,
) -> ProcessResult:
    global ACTIVE_PROCESS
    global ACTIVE_PROCESS_GROUPS
    global ACTIVE_PROCESS_DESCENDANTS
    global ACTIVE_PROCESS_IDENTITIES

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
                env={**os.environ, **(environment or {})},
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
        ACTIVE_PROCESS_DESCENDANTS = set()
        ACTIVE_PROCESS_IDENTITIES = {}
        root_identity = native_process_identity(process.pid)
        if root_identity is not None:
            ACTIVE_PROCESS_IDENTITIES[process.pid] = root_identity

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
                record_process_groups(
                    process.pid,
                    ACTIVE_PROCESS_GROUPS,
                    ACTIVE_PROCESS_DESCENDANTS,
                    ACTIVE_PROCESS_IDENTITIES,
                )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    timeout_message = f"process timed out after {timeout_seconds} seconds\n"
                    with log_lock:
                        log_file.write(timeout_message)
                    print(timeout_message, end="", file=sys.stderr)
                    record_process_groups(
                        process.pid,
                        ACTIVE_PROCESS_GROUPS,
                        ACTIVE_PROCESS_DESCENDANTS,
                        ACTIVE_PROCESS_IDENTITIES,
                    )
                    capture_timeout_sample(
                        process.pid,
                        sample_path,
                        set(ACTIVE_PROCESS_DESCENDANTS),
                    )
                    break
                try:
                    return_code = process.wait(
                        timeout=min(remaining, PROCESS_POLL_INTERVAL_SECONDS)
                    )
                    # A successful leader exit can still leave an already
                    # observed detached xctest group behind.
                    record_process_groups(
                        process.pid,
                        ACTIVE_PROCESS_GROUPS,
                        ACTIVE_PROCESS_DESCENDANTS,
                        ACTIVE_PROCESS_IDENTITIES,
                    )
                    break
                except subprocess.TimeoutExpired:
                    continue
        finally:
            terminate_process_groups(
                process,
                set(ACTIVE_PROCESS_GROUPS),
                TERMINATION_GRACE_SECONDS,
                process_ids=set(ACTIVE_PROCESS_DESCENDANTS),
                process_identities=dict(ACTIVE_PROCESS_IDENTITIES),
            )
            stdout_thread.join(timeout=2)
            stderr_thread.join(timeout=2)
            ACTIVE_PROCESS = None
            ACTIVE_PROCESS_GROUPS = set()
            ACTIVE_PROCESS_DESCENDANTS = set()
            ACTIVE_PROCESS_IDENTITIES = {}

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
    return targets


def parse_inventory(output: str, allowed_targets: Collection[str]) -> list[TestSpec]:
    rows = [line.strip() for line in output.splitlines() if line.strip()]
    if not rows:
        fail("swift test list returned an empty inventory")
    if len(rows) != len(set(rows)):
        fail("swift test list returned duplicate test specifications")
    allowed_target_set = set(allowed_targets)
    if not allowed_target_set:
        fail("Package.swift declares no test targets in the supported form")

    tests: list[TestSpec] = []
    for row in rows:
        match = INVENTORY_PATTERN.fullmatch(row)
        if match is None:
            fail(f"unsupported or unknown Swift test inventory row: {row}")
        target, suite, method, parentheses = match.groups()
        if target not in allowed_target_set:
            fail(
                "unknown Swift test target in inventory: "
                f"{target} (not declared in Package.swift)"
            )
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


def load_minimum_counts(
    path: Path, expected_targets: Collection[str]
) -> dict[str, int]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read Swift test count baselines: {error}")
    minimums = payload.get("swiftTestMinimumCountsByTarget")
    expected_target_set = set(expected_targets)
    if not isinstance(minimums, dict) or set(minimums) != expected_target_set:
        found_targets = sorted(minimums) if isinstance(minimums, dict) else []
        fail(
            "quality baselines must define every manifest Swift test target and no "
            f"others: expected {sorted(expected_target_set)}, found {found_targets}"
        )
    if not all(isinstance(value, int) and not isinstance(value, bool) and value > 0 for value in minimums.values()):
        fail("Swift test target minimum counts must be positive integers")
    return {str(target): int(count) for target, count in minimums.items()}


def validate_minimum_counts(
    tests: list[TestSpec],
    minimums: dict[str, int],
    expected_targets: Collection[str],
) -> dict[str, int]:
    counts = {target: 0 for target in expected_targets}
    for test in tests:
        if test.target not in counts:
            fail(
                "Swift test inventory contains target not present in manifest: "
                f"{test.target}"
            )
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


def swift_test_build_arguments(environment: dict[str, str]) -> list[str]:
    """Return flags for the one real SwiftPM build/inventory invocation.

    SwiftPM shards all use ``--skip-build`` after inventory discovery, so this
    is the single place where compiler diagnostics can be made strict. Keep a
    narrow opt-out for callers that need to investigate an older toolchain's
    warnings; complete concurrency checking is always required so the test
    artifact reuses the strict-build compiler settings.
    """

    arguments = ["-Xswiftc", "-strict-concurrency=complete"]
    raw_value = environment.get("SWIFT_TEST_WARNINGS_AS_ERRORS", "1").strip().lower()
    if raw_value in {"1", "true", "yes", "on"}:
        arguments.extend(("-Xswiftc", "-warnings-as-errors"))
        return arguments
    if raw_value in {"0", "false", "no", "off"}:
        return arguments
    fail(
        "SWIFT_TEST_WARNINGS_AS_ERRORS must be a boolean value (1/0, true/false, "
        "yes/no, or on/off)"
    )


def swift_child_environment(root: Path, output_directory: Path) -> dict[str, str]:
    """Build an isolated environment for SwiftPM and every shard child.

    SwiftPM otherwise probes ``~/Library`` even when all package artifacts are
    already in the project.  Default paths stay below the project output
    directory.  XDG and compiler cache values supplied by the caller are
    preserved; HOME uses the explicit SWIFT_TEST_HOME/SWIFT_BUILD_HOME hooks
    because an inherited shell HOME is not a reliable writable cache root.
    """

    environment = os.environ.copy()
    build_home = Path(
        environment.get("SWIFT_TEST_HOME")
        or environment.get("SWIFT_BUILD_HOME")
        or output_directory / "home"
    )
    # HOME is intentionally not inherited from the invoking shell: on the
    # managed macOS runner that path can point at an inaccessible user Library.
    # Callers that need a stable explicit home can use SWIFT_TEST_HOME; the
    # established SWIFT_BUILD_HOME remains the default integration hook.
    environment["HOME"] = str(build_home)
    defaults = {
        "XDG_CACHE_HOME": build_home / ".cache",
        "CLANG_MODULE_CACHE_PATH": build_home / ".swift-clang-cache",
        "SWIFT_MODULE_CACHE_PATH": build_home / ".swift-module-cache",
    }
    for key, default_path in defaults.items():
        if environment.get(key):
            continue
        environment[key] = str(default_path)
    build_home.mkdir(parents=True, exist_ok=True)
    for key in defaults:
        if environment[key] == str(defaults[key]):
            defaults[key].mkdir(parents=True, exist_ok=True)
    return environment


def target_slug(target: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9]+", "-", target).strip("-").lower()
    return slug or "target"


def build_shards(
    tests: list[TestSpec], target_order: Collection[str] | None = None
) -> list[Shard]:
    targets = list(dict.fromkeys(target_order or sorted({test.target for test in tests})))
    if not targets:
        fail("Swift test inventory declared no targets")
    target_set = set(targets)
    unknown_targets = sorted({test.target for test in tests} - target_set)
    if unknown_targets:
        fail(
            "Swift test inventory contains target not present in manifest: "
            f"{unknown_targets}"
        )

    settings_tests = tuple(
        test for test in tests if test.target == MAC_TARGET and test.suite == SETTINGS_SUITE
    )
    web_content_security_tests = tuple(
        test
        for test in tests
        if test.target == MAC_TARGET and test.suite == WEB_CONTENT_SECURITY_SUITE
    )
    shards: list[Shard] = []
    # These two App test suites have process-global state and retain their
    # historical isolated-process behavior when present.  They are optional:
    # a deleted or renamed suite must not make the entire inventory invalid.
    if web_content_security_tests:
        shards.append(
            Shard(
                label=f"{MAC_TARGET}.{WEB_CONTENT_SECURITY_SUITE}",
                slug="web-content-security",
                filter_pattern=make_suite_filter(
                    MAC_TARGET, [WEB_CONTENT_SECURITY_SUITE]
                ),
                tests=web_content_security_tests,
            )
        )
    for index, test in enumerate(sorted(settings_tests, key=lambda item: item.raw), start=1):
        shards.append(
            Shard(
                label=test.raw,
                slug=f"settings-{index:02d}",
                filter_pattern=f"^{re.escape(test.raw)}$",
                tests=(test,),
            )
        )

    mac_batches = batch_suites(
        tests,
        target=MAC_TARGET,
        excluded_suites={SETTINGS_SUITE, WEB_CONTENT_SECURITY_SUITE},
        maximum_suites=MAC_BATCH_MAX_SUITES,
        maximum_tests=MAC_BATCH_MAX_TESTS,
    )
    for index, (suites, batch_tests) in enumerate(mac_batches, start=1):
        shards.append(
            Shard(
                label=f"{MAC_TARGET} batch {index}",
                slug=f"mac-batch-{index:02d}",
                filter_pattern=make_suite_filter(MAC_TARGET, suites),
                tests=tuple(batch_tests),
            )
        )

    if CORE_TARGET in target_set:
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
            maximum_suites=CORE_BATCH_MAX_SUITES,
            maximum_tests=CORE_BATCH_MAX_TESTS,
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

    # Leaf targets are deliberately generic.  Their test ownership and suite
    # names can evolve independently of the App/Workbench special cases while
    # still receiving bounded, auditable processes.
    for target_index, target in enumerate(targets, start=1):
        if target in {MAC_TARGET, CORE_TARGET}:
            continue
        leaf_batches = batch_suites(
            tests,
            target=target,
            excluded_suites=set(),
            maximum_suites=LEAF_BATCH_MAX_SUITES,
            maximum_tests=LEAF_BATCH_MAX_TESTS,
        )
        for index, (suites, batch_tests) in enumerate(leaf_batches, start=1):
            shards.append(
                Shard(
                    label=f"{target} batch {index}",
                    slug=(
                        f"leaf-{target_index:02d}-{target_slug(target)}-"
                        f"{index:02d}"
                    ),
                    filter_pattern=make_suite_filter(target, suites),
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
    child_environment = swift_child_environment(root, output_directory)
    build_arguments: list[str] = []

    result: dict[str, object] = {
        "schemaVersion": 1,
        "status": "running",
        "inventory": {},
        "shards": [],
        "swiftTestBuildArguments": build_arguments,
        "swiftCacheEnvironment": {
            key: child_environment[key] for key in SWIFT_CACHE_ENVIRONMENT_KEYS
        },
    }
    atomic_write_json(result_path, result)

    try:
        build_arguments = swift_test_build_arguments(child_environment)
        result["swiftTestBuildArguments"] = build_arguments
        atomic_write_json(result_path, result)
        shard_retries = configured_shard_retries(os.environ)
        result["shardRetries"] = shard_retries
        manifest_targets = manifest_test_targets(root / "Package.swift")
        minimums = load_minimum_counts(
            root / "script" / "quality_baselines.json", manifest_targets
        )
    except ValueError as error:
        result.update({"status": "failed", "error": str(error)})
        atomic_write_json(result_path, result)
        print(f"swift test shards: {error}", file=sys.stderr)
        return 2

    list_command = [
        swift_binary,
        "test",
        "--disable-sandbox",
        *build_arguments,
        "list",
    ]
    print("swift test shards: building and reading the complete test inventory")
    list_process = run_child(
        list_command,
        cwd=root,
        log_path=output_directory / "build-list.log",
        timeout_seconds=list_timeout,
        sample_path=output_directory / "build-list.sample.txt",
        echo_stdout=False,
        environment=child_environment,
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
        tests = parse_inventory(list_process.stdout, manifest_targets)
        counts_by_target = validate_minimum_counts(
            tests, minimums, manifest_targets
        )
        shards = build_shards(tests, manifest_targets)
    except ValueError as error:
        result.update({"status": "failed", "returnCode": 2, "error": str(error)})
        atomic_write_json(result_path, result)
        print(f"swift test shards: {error}", file=sys.stderr)
        return 2

    inventory_path.write_text("\n".join(test.raw for test in tests) + "\n", encoding="utf-8")
    result["inventory"] = {
        "path": str(inventory_path),
        "totalCount": len(tests),
        "targets": manifest_targets,
        "countsByTarget": counts_by_target,
        "xctestCount": sum(not test.is_swift_testing for test in tests),
        "swiftTestingCount": sum(test.is_swift_testing for test in tests),
        "minimumCountsByTarget": minimums,
        "shardsByTarget": {
            target: [
                shard.slug
                for shard in shards
                if any(test.target == target for test in shard.tests)
            ]
            for target in manifest_targets
        },
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
                environment=child_environment,
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
