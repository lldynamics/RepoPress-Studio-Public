#!/usr/bin/env python3
"""Contract tests for the isolated SwiftPM test process runner."""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "script" / "run_swift_tests.sh"
HELPER = ROOT / "script" / "run_swift_test_process.py"


PACKAGE_TEMPLATE = """\
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "Fixture",
  targets: [
    .target(name: "App"),
    .testTarget(name: "PublishingWorkbenchCoreTests", dependencies: ["App"]),
    .testTarget(name: "PersonalSitePublisherMacTests", dependencies: ["App"]),
{extra_target}  ]
)
"""


FAKE_SWIFT = r'''#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

call_log = Path(os.environ["SWIFT_CALL_LOG"])
calls = json.loads(call_log.read_text(encoding="utf-8")) if call_log.exists() else []
calls.append(sys.argv[1:])
call_log.write_text(json.dumps(calls), encoding="utf-8")

inventory = [line for line in Path(os.environ["SWIFT_INVENTORY"]).read_text(encoding="utf-8").splitlines() if line]
if sys.argv[1:] == ["test", "--disable-sandbox", "list"]:
    print("\n".join(inventory))
    raise SystemExit(0)

fail_at = int(os.environ.get("SWIFT_FAIL_AT", "0"))
if fail_at and len(calls) == fail_at:
    raise SystemExit(int(os.environ.get("SWIFT_FAIL_CODE", "19")))

hang_at = int(os.environ.get("SWIFT_HANG_AT", "0"))
hang_always = os.environ.get("SWIFT_HANG_ALWAYS", "0") == "1"
if hang_at and (len(calls) == hang_at or (hang_always and len(calls) >= hang_at)):
    child = subprocess.Popen(
        [os.environ["FAKE_XCTEST"], "60"],
        start_new_session=True,
    )
    Path(os.environ["HANG_CHILD_PID"]).write_text(str(child.pid), encoding="utf-8")
    Path(os.environ["HANG_CHILD_PGID"]).write_text(str(os.getpgid(child.pid)), encoding="utf-8")
    Path(os.environ["HANG_ROOT_PGID"]).write_text(str(os.getpgrp()), encoding="utf-8")
    Path(os.environ["PROCESS_SNAPSHOT_PATH"]).write_text(
        "\n".join(
            (
                f"{os.getpid()} {os.getppid()} {os.getpgrp()} {sys.executable} {__file__}",
                f"{child.pid} {os.getpid()} {os.getpgid(child.pid)} "
                f"{os.environ['FAKE_XCTEST']}/Contents/MacOS/Fixture",
            )
        )
        + "\n",
        encoding="utf-8",
    )
    time.sleep(60)

detached_exit_at = int(os.environ.get("SWIFT_DETACHED_EXIT_AT", "0"))
if detached_exit_at and len(calls) == detached_exit_at:
    child = subprocess.Popen(
        [os.environ["FAKE_XCTEST"], "60"],
        start_new_session=True,
    )
    Path(os.environ["HANG_CHILD_PID"]).write_text(str(child.pid), encoding="utf-8")
    Path(os.environ["HANG_CHILD_PGID"]).write_text(str(os.getpgid(child.pid)), encoding="utf-8")
    Path(os.environ["HANG_ROOT_PGID"]).write_text(str(os.getpgrp()), encoding="utf-8")
    Path(os.environ["PROCESS_SNAPSHOT_PATH"]).write_text(
        "\n".join(
            (
                f"{os.getpid()} {os.getppid()} {os.getpgrp()} {sys.executable} {__file__}",
                f"{child.pid} {os.getpid()} {os.getpgid(child.pid)} "
                f"{os.environ['FAKE_XCTEST']}/Contents/MacOS/Fixture",
            )
        )
        + "\n",
        encoding="utf-8",
    )
    raise SystemExit(0)

try:
    filter_value = sys.argv[sys.argv.index("--filter") + 1]
except (ValueError, IndexError):
    raise SystemExit(91)
matched = [spec for spec in inventory if re.search(filter_value, spec)]
xctest = sum(not spec.endswith("()") for spec in matched)
swift_testing = sum(spec.endswith("()") for spec in matched)
print(f"Executed {xctest} tests, with 0 failures (0 unexpected)")
print(f"✔ Test run with {swift_testing} tests in 1 suite passed")
'''


FAKE_PS = r'''#!/usr/bin/env python3
import os
from pathlib import Path

snapshot = Path(os.environ["PROCESS_SNAPSHOT_PATH"])
if snapshot.exists():
    Path(os.environ["PROCESS_SNAPSHOT_OBSERVED"]).write_text("observed\n", encoding="utf-8")
    print(snapshot.read_text(encoding="utf-8"), end="")
'''


SLOW_FAKE_PS = r'''#!/usr/bin/env python3
import os
import time
from pathlib import Path

Path(os.environ["SLOW_PS_STARTED"]).write_text("started\n", encoding="utf-8")
time.sleep(10)
'''


FAKE_SAMPLE = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

log_path = Path(os.environ["SAMPLE_CALL_LOG"])
calls = json.loads(log_path.read_text(encoding="utf-8")) if log_path.exists() else []
calls.append(sys.argv[1:])
log_path.write_text(json.dumps(calls), encoding="utf-8")
if "-file" in sys.argv:
    Path(sys.argv[sys.argv.index("-file") + 1]).write_text("synthetic sample\n", encoding="utf-8")
'''


def fixture_inventory() -> list[str]:
    rows = [
        "PersonalSitePublisherMacTests.WorkbenchImageTwoTierCacheTests/testCacheA",
        "PersonalSitePublisherMacTests.WorkbenchImageTwoTierCacheTests/testCacheB",
    ]
    rows.extend(
        f"PersonalSitePublisherMacTests.SettingsSearchAndSavePresentationTests/testSetting{index}"
        for index in range(1, 7)
    )
    rows.extend(
        f"PersonalSitePublisherMacTests.MacSuite{index}/testValue"
        for index in range(1, 8)
    )
    rows.extend(
        f"PersonalSitePublisherMacTests.MacLarge/testValue{index}"
        for index in range(1, 42)
    )
    rows.extend(
        f"PublishingWorkbenchCoreTests.CoreSuite{index}/testValue"
        for index in range(1, 14)
    )
    rows.extend(
        (
            "PublishingWorkbenchCoreTests.CodexAppServerClientTests/testAccountStatus",
            "PublishingWorkbenchCoreTests.CodexAppServerClientTests/testProcessTransport",
        )
    )
    rows.extend(
        f"PublishingWorkbenchCoreTests.CoreLarge/testValue{index}"
        for index in range(1, 152)
    )
    rows.append("PublishingWorkbenchCoreTests.SwiftTestingSuite/valueContract()")
    return sorted(rows)


def make_fixture(
    *,
    extra_target: bool = False,
    duplicate_inventory: bool = False,
    raise_baseline: bool = False,
) -> tuple[tempfile.TemporaryDirectory[str], Path, dict[str, str]]:
    temporary = tempfile.TemporaryDirectory(prefix="swift-test-processes.")
    root = Path(temporary.name)
    script_dir = root / "script"
    bin_dir = root / "bin"
    script_dir.mkdir()
    bin_dir.mkdir()
    shutil.copy2(RUNNER, script_dir / RUNNER.name)
    shutil.copy2(HELPER, script_dir / HELPER.name)
    (script_dir / RUNNER.name).chmod(0o755)
    (script_dir / HELPER.name).chmod(0o755)
    (root / "Package.swift").write_text(
        PACKAGE_TEMPLATE.format(
            extra_target=(
                '    .testTarget(name: "FutureTests", dependencies: ["App"]),\n'
                if extra_target
                else ""
            )
        ),
        encoding="utf-8",
    )

    inventory = fixture_inventory()
    if duplicate_inventory:
        inventory.append(inventory[0])
    inventory_path = root / "inventory-source.txt"
    inventory_path.write_text("\n".join(inventory) + "\n", encoding="utf-8")
    mac_count = sum(row.startswith("PersonalSitePublisherMacTests.") for row in fixture_inventory())
    core_count = sum(row.startswith("PublishingWorkbenchCoreTests.") for row in fixture_inventory())
    (script_dir / "quality_baselines.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "swiftTestMinimumCountsByTarget": {
                    "PersonalSitePublisherMacTests": mac_count + (1 if raise_baseline else 0),
                    "PublishingWorkbenchCoreTests": core_count,
                },
            }
        ),
        encoding="utf-8",
    )

    fake_swift = bin_dir / "swift"
    fake_swift.write_text(FAKE_SWIFT, encoding="utf-8")
    fake_swift.chmod(0o755)
    fake_ps = bin_dir / "ps"
    fake_ps.write_text(FAKE_PS, encoding="utf-8")
    fake_ps.chmod(0o755)
    fake_sample = bin_dir / "sample"
    fake_sample.write_text(FAKE_SAMPLE, encoding="utf-8")
    fake_sample.chmod(0o755)
    fake_xctest = bin_dir / "Fixture.xctest"
    fake_xctest.symlink_to("/bin/sleep")

    paths = {
        "call_log": str(root / "calls.json"),
        "sample_call_log": str(root / "sample-calls.json"),
        "inventory": str(inventory_path),
        "hang_child_pid": str(root / "hang-child.pid"),
        "hang_child_pgid": str(root / "hang-child.pgid"),
        "hang_root_pgid": str(root / "hang-root.pgid"),
        "process_snapshot": str(root / "process-snapshot.txt"),
        "process_snapshot_observed": str(root / "process-snapshot-observed.txt"),
        "slow_ps_started": str(root / "slow-ps-started.txt"),
        "fake_swift": str(fake_swift),
        "fake_ps": str(fake_ps),
        "fake_sample": str(fake_sample),
        "fake_xctest": str(fake_xctest),
    }
    return temporary, root, paths


def fixture_environment(paths: dict[str, str], **extra: str) -> dict[str, str]:
    environment = os.environ.copy()
    environment.pop("SWIFT_TEST_SHARD_TIMEOUT_SECONDS", None)
    environment.pop("SWIFT_TEST_SHARD_RETRIES", None)
    environment.pop("SWIFT_TEST_TERMINATION_GRACE_SECONDS", None)
    environment.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "SWIFT_BIN": paths["fake_swift"],
            "SAMPLE_BIN": paths["fake_sample"],
            "SWIFT_CALL_LOG": paths["call_log"],
            "SAMPLE_CALL_LOG": paths["sample_call_log"],
            "SWIFT_INVENTORY": paths["inventory"],
            "PS_BIN": paths["fake_ps"],
            "FAKE_XCTEST": paths["fake_xctest"],
            "HANG_CHILD_PID": paths["hang_child_pid"],
            "HANG_CHILD_PGID": paths["hang_child_pgid"],
            "HANG_ROOT_PGID": paths["hang_root_pgid"],
            "PROCESS_SNAPSHOT_PATH": paths["process_snapshot"],
            "PROCESS_SNAPSHOT_OBSERVED": paths["process_snapshot_observed"],
            "SLOW_PS_STARTED": paths["slow_ps_started"],
            "SWIFT_TEST_LIST_TIMEOUT_SECONDS": "5",
            **extra,
        }
    )
    return environment


def run_fixture(root: Path, paths: dict[str, str], **extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(root / "script" / RUNNER.name)],
        cwd=root,
        env=fixture_environment(paths, **extra),
        text=True,
        capture_output=True,
        timeout=20,
    )


def read_calls(paths: dict[str, str]) -> list[list[str]]:
    path = Path(paths["call_log"])
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else []


def read_result(root: Path) -> dict[str, object]:
    return json.loads(
        (root / ".build" / "swift-test-shards" / "result.json").read_text(encoding="utf-8")
    )


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def wait_for_path(path: Path, timeout: float = 4.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for {path}")


def test_successful_partition_and_exact_argv() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(root, paths)
        assert result.returncode == 0, result.stderr
        calls = read_calls(paths)
        assert calls[0] == ["test", "--disable-sandbox", "list"]
        assert all(
            call[:4] == ["test", "--disable-sandbox", "--skip-build", "--filter"]
            and "--skip" not in call
            for call in calls[1:]
        )
        payload = read_result(root)
        assert payload["status"] == "passed", payload
        shards = payload["shards"]
        assert len(calls) == len(shards) + 1
        assigned = [test for shard in shards for test in shard["tests"]]
        assert sorted(assigned) == fixture_inventory()
        assert len(assigned) == len(set(assigned))
        settings = [shard for shard in shards if shard["slug"].startswith("settings-")]
        assert len(settings) == 6
        assert all(len(shard["tests"]) == 1 for shard in settings)
        cache = [shard for shard in shards if shard["slug"] == "cache"]
        assert len(cache) == 1
        assert len(cache[0]["tests"]) == 2
        assert cache[0]["filter"] == r"^PersonalSitePublisherMacTests\.(WorkbenchImageTwoTierCacheTests)/"
        mac_cases = [
            shard
            for shard in shards
            if shard["slug"].startswith(("settings-", "mac-"))
        ]
        assert len(mac_cases) == 54
        assert all(len(shard["tests"]) == 1 for shard in mac_cases)
        assert all(
            shard["filter"] == f"^{re.escape(shard['tests'][0])}$"
            for shard in mac_cases
        )
        core_cases = [
            shard for shard in shards if shard["slug"].startswith("core-case-")
        ]
        assert len(core_cases) == 2
        assert all(len(shard["tests"]) == 1 for shard in core_cases)
        assert all(
            shard["filter"] == f"^{re.escape(shard['tests'][0])}$"
            for shard in core_cases
        )
        core = [
            shard
            for shard in shards
            if shard["slug"].startswith("core-")
            and not shard["slug"].startswith("core-case-")
        ]
        assert len(core) == 3
        assert all(not shard["filter"].endswith("$") for shard in core)
        for shard in shards:
            if shard in core:
                suites = {test.split("/", 1)[0] for test in shard["tests"]}
                assert len(suites) <= 12
                assert len(shard["tests"]) <= 150 or len(suites) == 1
            assert shard["executedXCTestCount"] == shard["expectedXCTestCount"]
            assert shard["executedSwiftTestingCount"] == shard["expectedSwiftTestingCount"]
            assert "timeoutSeconds: 120.0" in Path(shard["logPath"]).read_text(encoding="utf-8")
            assert "terminationGraceSeconds: 2.0" in Path(shard["logPath"]).read_text(encoding="utf-8")


def test_manifest_inventory_and_baseline_fail_closed() -> None:
    for options, expected_message, expected_calls in (
        ({"extra_target": True}, "unexpected Swift test target set", 0),
        ({"duplicate_inventory": True}, "duplicate test specifications", 1),
        ({"raise_baseline": True}, "fell below", 1),
    ):
        temporary, root, paths = make_fixture(**options)
        with temporary:
            result = run_fixture(root, paths)
            assert result.returncode == 2, result
            assert expected_message in result.stderr
            assert len(read_calls(paths)) == expected_calls
            assert read_result(root)["status"] == "failed"


def test_shard_retry_configuration_is_bounded() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(root, paths, SWIFT_TEST_SHARD_RETRIES="2")
        assert result.returncode == 2, result
        assert "SWIFT_TEST_SHARD_RETRIES must be between 0 and 1" in result.stderr
        assert read_calls(paths) == []
        payload = read_result(root)
        assert payload["status"] == "failed"


def test_nonzero_shard_fails_fast_with_incremental_result() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(root, paths, SWIFT_FAIL_AT="4", SWIFT_FAIL_CODE="23")
        assert result.returncode == 23, result
        assert len(read_calls(paths)) == 4
        payload = read_result(root)
        assert payload["status"] == "failed"
        assert payload["returnCode"] == 23
        failed = next(shard for shard in payload["shards"] if shard["status"] == "failed")
        assert len(failed["attempts"]) == 1


def test_timeout_retries_once_then_passes_with_distinct_evidence() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(
            root,
            paths,
            SWIFT_HANG_AT="2",
            SWIFT_TEST_SHARD_TIMEOUT_SECONDS="0.5",
            SWIFT_TEST_TERMINATION_GRACE_SECONDS="0.2",
        )
        assert result.returncode == 0, result.stderr
        payload = read_result(root)
        assert payload["status"] == "passed"
        retried = next(
            shard for shard in payload["shards"] if shard["retryCount"] == 1
        )
        attempts = retried["attempts"]
        assert len(attempts) == 2, attempts
        assert attempts[0]["status"] == "timed_out", attempts
        assert attempts[0]["timedOut"] is True, attempts
        assert attempts[0]["retry"] is False, attempts
        assert attempts[1]["status"] == "passed", attempts
        assert attempts[1]["retry"] is True, attempts
        assert attempts[0]["logPath"] != attempts[1]["logPath"], attempts
        assert attempts[0]["samplePath"] != attempts[1]["samplePath"], attempts
        assert all(Path(attempt["logPath"]).exists() for attempt in attempts)
        assert Path(attempts[0]["samplePath"]).exists()
        assert retried["logPath"] == attempts[-1]["logPath"]
        assert retried["samplePath"] == attempts[-1]["samplePath"]


def test_repeated_timeout_retries_once_then_fails_closed() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(
            root,
            paths,
            SWIFT_HANG_AT="2",
            SWIFT_HANG_ALWAYS="1",
            SWIFT_TEST_SHARD_TIMEOUT_SECONDS="0.5",
            SWIFT_TEST_TERMINATION_GRACE_SECONDS="0.2",
        )
        assert result.returncode == 124, result
        payload = read_result(root)
        assert payload["status"] == "timed_out"
        timed_out = next(shard for shard in payload["shards"] if shard["status"] == "timed_out")
        attempts = timed_out["attempts"]
        assert len(attempts) == 2, attempts
        assert all(attempt["status"] == "timed_out" for attempt in attempts), attempts
        assert all(attempt["timedOut"] is True for attempt in attempts), attempts
        assert attempts[0]["logPath"] != attempts[1]["logPath"], attempts
        assert attempts[0]["samplePath"] != attempts[1]["samplePath"], attempts
        assert all(Path(attempt["logPath"]).exists() for attempt in attempts)


def test_timeout_samples_and_removes_child_process_group() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(
            root,
            paths,
            SWIFT_HANG_AT="2",
            SWIFT_TEST_SHARD_RETRIES="0",
            SWIFT_TEST_SHARD_TIMEOUT_SECONDS="0.5",
            SWIFT_TEST_TERMINATION_GRACE_SECONDS="0.2",
        )
        assert result.returncode == 124, result
        wait_for_path(Path(paths["hang_child_pid"]))
        child_pid = int(Path(paths["hang_child_pid"]).read_text(encoding="utf-8"))
        child_pgid = int(Path(paths["hang_child_pgid"]).read_text(encoding="utf-8"))
        root_pgid = int(Path(paths["hang_root_pgid"]).read_text(encoding="utf-8"))
        assert child_pgid != root_pgid
        time.sleep(0.1)
        assert not process_exists(child_pid), child_pid
        payload = read_result(root)
        assert payload["status"] == "timed_out"
        timed_out = next(shard for shard in payload["shards"] if shard["status"] == "timed_out")
        assert len(timed_out["attempts"]) == 1
        assert Path(timed_out["samplePath"]).exists()
        sample_calls = json.loads(Path(paths["sample_call_log"]).read_text(encoding="utf-8"))
        assert sample_calls and sample_calls[0][0] == str(child_pid)


def test_leader_exit_cleans_detached_child_and_fails_missing_counts() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(root, paths, SWIFT_DETACHED_EXIT_AT="2")
        assert result.returncode == 2, result
        wait_for_path(Path(paths["hang_child_pid"]))
        child_pid = int(Path(paths["hang_child_pid"]).read_text(encoding="utf-8"))
        child_pgid = int(Path(paths["hang_child_pgid"]).read_text(encoding="utf-8"))
        root_pgid = int(Path(paths["hang_root_pgid"]).read_text(encoding="utf-8"))
        assert child_pgid != root_pgid
        time.sleep(0.1)
        assert not process_exists(child_pid), child_pid
        payload = read_result(root)
        assert payload["status"] == "failed"
        failed = next(shard for shard in payload["shards"] if shard["slug"] == "cache")
        assert failed["status"] == "failed"
        assert "completed test counts" in failed["error"]


def test_external_sigterm_is_forwarded_to_active_shard() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        process = subprocess.Popen(
            [str(root / "script" / RUNNER.name)],
            cwd=root,
            env=fixture_environment(
                paths,
                SWIFT_HANG_AT="2",
                SWIFT_TEST_SHARD_TIMEOUT_SECONDS="60",
            ),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        wait_for_path(Path(paths["hang_child_pid"]))
        child_pid = int(Path(paths["hang_child_pid"]).read_text(encoding="utf-8"))
        # First prove the detached child group was recorded.  Then replace ps
        # with a deliberately blocked implementation so the signal handler
        # must rely only on its recorded groups and still beat the outer
        # release gate's five-second SIGKILL deadline.
        wait_for_path(Path(paths["process_snapshot_observed"]))
        slow_ps = Path(paths["fake_ps"]).with_suffix(".replacement")
        slow_ps.write_text(SLOW_FAKE_PS, encoding="utf-8")
        slow_ps.chmod(0o755)
        os.replace(slow_ps, paths["fake_ps"])
        wait_for_path(Path(paths["slow_ps_started"]))
        process.send_signal(signal.SIGTERM)
        started_at = time.monotonic()
        assert process.wait(timeout=5) == 128 + signal.SIGTERM
        assert time.monotonic() - started_at < 4.5
        time.sleep(0.1)
        assert not process_exists(child_pid), child_pid


def main() -> int:
    test_successful_partition_and_exact_argv()
    test_manifest_inventory_and_baseline_fail_closed()
    test_shard_retry_configuration_is_bounded()
    test_nonzero_shard_fails_fast_with_incremental_result()
    test_timeout_retries_once_then_passes_with_distinct_evidence()
    test_repeated_timeout_retries_once_then_fails_closed()
    test_timeout_samples_and_removes_child_process_group()
    test_leader_exit_cleans_detached_child_and_fails_missing_counts()
    test_external_sigterm_is_forwarded_to_active_shard()
    print("swift test process runner contract: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
