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


FIXTURE_TEST_TARGETS = (
    "PublishingMarkdownCoreTests",
    "PublishingGitCoreTests",
    "PublishingDomainContractsTests",
    "PublishingAICoreTests",
    "PublishingCoreSupportTests",
    "PublishingKnowledgeCoreTests",
    "PublishingWorkbenchCoreTests",
    "PersonalSitePublisherMacTests",
)


PACKAGE_TEMPLATE = """\
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "Fixture",
  targets: [
    .target(name: "App"),
{test_targets}{extra_target}  ]
)
"""


FIXTURE_TEST_TARGET_TEMPLATE = """\
    .testTarget(name: "{target}", dependencies: ["App"]),
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

environment_log = Path(os.environ["SWIFT_ENV_LOG"])
environment_calls = (
    json.loads(environment_log.read_text(encoding="utf-8"))
    if environment_log.exists()
    else []
)
environment_calls.append(
    {
        key: os.environ.get(key)
        for key in (
            "HOME",
            "XDG_CACHE_HOME",
            "CLANG_MODULE_CACHE_PATH",
            "SWIFT_MODULE_CACHE_PATH",
        )
    }
)
environment_log.write_text(json.dumps(environment_calls), encoding="utf-8")

inventory = [line for line in Path(os.environ["SWIFT_INVENTORY"]).read_text(encoding="utf-8").splitlines() if line]
if sys.argv[1] == "test" and "list" in sys.argv[1:]:
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

pgid_escape_at = int(os.environ.get("SWIFT_PGID_ESCAPE_AT", "0"))
if pgid_escape_at and len(calls) == pgid_escape_at:
    # Keep a static pre-detach snapshot: the fixture proves that the runner
    # must retain the descendant PID, not merely its initial process group.
    child = subprocess.Popen(
        [os.environ["FAKE_PGID_ESCAPE_XCTEST"], "60"],
    )
    Path(os.environ["HANG_CHILD_PID"]).write_text(str(child.pid), encoding="utf-8")
    Path(os.environ["HANG_CHILD_PGID"]).write_text(str(os.getpgid(child.pid)), encoding="utf-8")
    Path(os.environ["HANG_ROOT_PGID"]).write_text(str(os.getpgrp()), encoding="utf-8")
    Path(os.environ["PROCESS_SNAPSHOT_PATH"]).write_text(
        "\n".join(
            (
                f"{os.getpid()} {os.getppid()} {os.getpgrp()} {sys.executable} {__file__}",
                f"{child.pid} {os.getpid()} {os.getpgid(child.pid)} "
                f"{os.environ['FAKE_PGID_ESCAPE_XCTEST']}",
            )
        )
        + "\n",
        encoding="utf-8",
    )
    time.sleep(60)

try:
    filter_value = sys.argv[sys.argv.index("--filter") + 1]
except (ValueError, IndexError):
    raise SystemExit(91)
matched = [spec for spec in inventory if re.search(filter_value, spec)]
is_swift_testing = lambda spec: re.search(r"\([^\r\n]*\)$", spec) is not None
xctest = sum(not is_swift_testing(spec) for spec in matched)
swift_testing = sum(is_swift_testing(spec) for spec in matched)
print(f"Executed {xctest} tests, with 0 failures (0 unexpected)")
print(f"✔ Test run with {swift_testing} tests in 1 suite passed")
'''


FAKE_PGID_ESCAPE_XCTEST = r'''#!/usr/bin/env python3
import os
import time
from pathlib import Path

time.sleep(0.05)
try:
    os.setsid()
except PermissionError:
    os.setpgrp()
Path(os.environ["PGID_ESCAPE_READY"]).write_text(str(os.getpgrp()), encoding="utf-8")
time.sleep(60)
'''


FAKE_PS = r'''#!/usr/bin/env python3
import os
from pathlib import Path

snapshot = Path(os.environ["PROCESS_SNAPSHOT_PATH"])
if snapshot.exists():
    Path(os.environ["PROCESS_SNAPSHOT_OBSERVED"]).write_text("observed\n", encoding="utf-8")
    print(snapshot.read_text(encoding="utf-8"), end="")
'''


FAILING_FAKE_PS = r'''#!/usr/bin/env python3
raise SystemExit(1)
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
        "PersonalSitePublisherMacTests.SettingsSearchAndSavePresentationTests/testSetting1",
        "PersonalSitePublisherMacTests.SettingsSearchAndSavePresentationTests/testSetting2",
        "PersonalSitePublisherMacTests.SettingsSearchAndSavePresentationTests/testSetting3",
        "PersonalSitePublisherMacTests.SettingsSearchAndSavePresentationTests/testSetting4",
        "PersonalSitePublisherMacTests.SettingsSearchAndSavePresentationTests/testSetting5",
        "PersonalSitePublisherMacTests.SettingsSearchAndSavePresentationTests/testSetting6",
    ]
    rows.extend(
        (
            "PersonalSitePublisherMacTests.WebContentNetworkSecurityTests/testContentRule",
            "PersonalSitePublisherMacTests.WebContentNetworkSecurityTests/testContentSecurityPolicy",
            "PersonalSitePublisherMacTests.WebContentNetworkSecurityTests/testNetworkImages",
        )
    )
    rows.extend(
        f"PersonalSitePublisherMacTests.MacSuite{index}/testValue"
        for index in range(1, 8)
    )
    rows.extend(
        f"PersonalSitePublisherMacTests.MacLarge/testValue{index}"
        for index in range(1, 62)
    )
    rows.extend(
        f"PublishingWorkbenchCoreTests.CoreSuite{index}/testValue"
        for index in range(1, 14)
    )
    rows.extend(
        (
            "PublishingWorkbenchCoreTests.AIModelDiscoveryServiceTests/testCatalog",
            "PublishingWorkbenchCoreTests.AIModelDiscoveryServiceTests/testProxy",
        )
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
    rows.append(
        "PublishingWorkbenchCoreTests.SwiftTestingSuite/"
        "valueContract(value: Int, expected: String)"
    )
    rows.extend(
        f"PublishingMarkdownCoreTests.MarkdownLarge/testValue{index}"
        for index in range(1, 202)
    )
    rows.extend(
        (
            "PublishingMarkdownCoreTests.MarkdownSuite/testParser",
            "PublishingMarkdownCoreTests.MarkdownSuite/testRenderer",
            "PublishingGitCoreTests.GitSuite/testRunner",
            "PublishingGitCoreTests.GitSuite/testRemote",
            "PublishingDomainContractsTests.DomainSuite/testContract",
            "PublishingAICoreTests.AISuite/testProvider",
            "PublishingCoreSupportTests.SupportSuite/testReader",
            "PublishingKnowledgeCoreTests.KnowledgeSuite/testSearch",
        )
    )
    return sorted(rows)


def make_fixture(
    *,
    extra_target: bool = False,
    duplicate_inventory: bool = False,
    raise_baseline: bool = False,
    missing_suite: str | None = None,
    unknown_inventory: bool = False,
    missing_baseline_target: str | None = None,
    extra_baseline_target: str | None = None,
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
            test_targets="".join(
                FIXTURE_TEST_TARGET_TEMPLATE.format(target=target)
                for target in FIXTURE_TEST_TARGETS
            ),
            extra_target=(
                '    .testTarget(name: "FutureTests", dependencies: ["App"]),\n'
                if extra_target
                else ""
            )
        ),
        encoding="utf-8",
    )

    inventory = fixture_inventory()
    if missing_suite is not None:
        inventory = [
            row
            for row in inventory
            if f".{missing_suite}/" not in row
        ]
    if extra_target:
        inventory.append("FutureTests.FutureSuite/testFuture")
    if unknown_inventory:
        inventory.append("UnknownInventoryTests.UnknownSuite/testUnknown")
    if duplicate_inventory:
        inventory.append(inventory[0])
    inventory_path = root / "inventory-source.txt"
    inventory_path.write_text("\n".join(inventory) + "\n", encoding="utf-8")
    counts = {
        target: sum(row.startswith(f"{target}.") for row in inventory)
        for target in FIXTURE_TEST_TARGETS
    }
    if extra_target:
        counts["FutureTests"] = 1
    baseline_targets = dict(counts)
    baseline_targets["PersonalSitePublisherMacTests"] += int(raise_baseline)
    if missing_baseline_target is not None:
        baseline_targets.pop(missing_baseline_target, None)
    if extra_baseline_target is not None:
        baseline_targets[extra_baseline_target] = 1
    (script_dir / "quality_baselines.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "swiftTestMinimumCountsByTarget": baseline_targets,
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
    failing_ps = bin_dir / "failing-ps"
    failing_ps.write_text(FAILING_FAKE_PS, encoding="utf-8")
    failing_ps.chmod(0o755)
    fake_sample = bin_dir / "sample"
    fake_sample.write_text(FAKE_SAMPLE, encoding="utf-8")
    fake_sample.chmod(0o755)
    fake_xctest = bin_dir / "Fixture.xctest"
    fake_xctest.symlink_to("/bin/sleep")
    fake_pgid_escape_xctest = bin_dir / "PGIDEscapeFixture.xctest"
    fake_pgid_escape_xctest.write_text(FAKE_PGID_ESCAPE_XCTEST, encoding="utf-8")
    fake_pgid_escape_xctest.chmod(0o755)

    paths = {
        "call_log": str(root / "calls.json"),
        "sample_call_log": str(root / "sample-calls.json"),
        "env_log": str(root / "swift-env.json"),
        "inventory": str(inventory_path),
        "hang_child_pid": str(root / "hang-child.pid"),
        "hang_child_pgid": str(root / "hang-child.pgid"),
        "hang_root_pgid": str(root / "hang-root.pgid"),
        "process_snapshot": str(root / "process-snapshot.txt"),
        "process_snapshot_observed": str(root / "process-snapshot-observed.txt"),
        "slow_ps_started": str(root / "slow-ps-started.txt"),
        "fake_swift": str(fake_swift),
        "fake_ps": str(fake_ps),
        "failing_ps": str(failing_ps),
        "fake_sample": str(fake_sample),
        "fake_xctest": str(fake_xctest),
        "fake_pgid_escape_xctest": str(fake_pgid_escape_xctest),
        "pgid_escape_ready": str(root / "pgid-escape-ready"),
    }
    return temporary, root, paths


def fixture_environment(paths: dict[str, str], **extra: str) -> dict[str, str]:
    environment = os.environ.copy()
    for key in (
        "HOME",
        "SWIFT_BUILD_HOME",
        "SWIFT_TEST_HOME",
        "XDG_CACHE_HOME",
        "CLANG_MODULE_CACHE_PATH",
        "SWIFT_MODULE_CACHE_PATH",
        "SWIFT_TEST_WARNINGS_AS_ERRORS",
    ):
        environment.pop(key, None)
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
            "SWIFT_ENV_LOG": paths["env_log"],
            "SWIFT_INVENTORY": paths["inventory"],
            "PS_BIN": paths["fake_ps"],
            "FAKE_XCTEST": paths["fake_xctest"],
            "FAKE_PGID_ESCAPE_XCTEST": paths["fake_pgid_escape_xctest"],
            "HANG_CHILD_PID": paths["hang_child_pid"],
            "HANG_CHILD_PGID": paths["hang_child_pgid"],
            "HANG_ROOT_PGID": paths["hang_root_pgid"],
            "PROCESS_SNAPSHOT_PATH": paths["process_snapshot"],
            "PROCESS_SNAPSHOT_OBSERVED": paths["process_snapshot_observed"],
            "SLOW_PS_STARTED": paths["slow_ps_started"],
            "PGID_ESCAPE_READY": paths["pgid_escape_ready"],
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


def read_environment_calls(paths: dict[str, str]) -> list[dict[str, str | None]]:
    path = Path(paths["env_log"])
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
        assert calls[0] == [
            "test",
            "--disable-sandbox",
            "-Xswiftc",
            "-strict-concurrency=complete",
            "-Xswiftc",
            "-warnings-as-errors",
            "list",
        ]
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
        assert not cache
        web_content_security = [
            shard for shard in shards if shard["slug"] == "web-content-security"
        ]
        assert len(web_content_security) == 1
        assert len(web_content_security[0]["tests"]) == 3
        assert web_content_security[0]["filter"] == (
            r"^PersonalSitePublisherMacTests\.(WebContentNetworkSecurityTests)/"
        )
        mac_cases = [
            shard
            for shard in shards
            if shard["slug"].startswith("settings-")
        ]
        assert len(mac_cases) == 6
        assert all(len(shard["tests"]) == 1 for shard in mac_cases)
        assert all(
            shard["filter"] == f"^{re.escape(shard['tests'][0])}$"
            for shard in mac_cases
        )
        mac_batches = [
            shard for shard in shards if shard["slug"].startswith("mac-batch-")
        ]
        assert len(mac_batches) == 4
        assert sum(len(shard["tests"]) for shard in mac_batches) == 68
        assert all(
            len({test.split("/", 1)[0] for test in shard["tests"]}) <= 4
            for shard in mac_batches
        )
        mac_large = [
            shard
            for shard in mac_batches
            if all(".MacLarge/" in test for test in shard["tests"])
        ]
        assert [len(shard["tests"]) for shard in mac_large] == [60, 1]
        assert [shard["slug"] for shard in mac_large] == [
            "mac-batch-01",
            "mac-batch-02",
        ]
        core_cases = [
            shard for shard in shards if shard["slug"].startswith("core-case-")
        ]
        assert len(core_cases) == 4
        assert all(len(shard["tests"]) == 1 for shard in core_cases)
        assert {
            test.split("/", 1)[0].rsplit(".", 1)[-1]
            for shard in core_cases
            for test in shard["tests"]
        } == {"AIModelDiscoveryServiceTests", "CodexAppServerClientTests"}
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
        assert len(core) == 4
        core_large = [
            shard
            for shard in core
            if all(".CoreLarge/" in test for test in shard["tests"])
        ]
        assert [len(shard["tests"]) for shard in core_large] == [150, 1]
        assert [shard["slug"] for shard in core_large] == ["core-01", "core-02"]
        leaf_targets = set(FIXTURE_TEST_TARGETS) - {
            "PersonalSitePublisherMacTests",
            "PublishingWorkbenchCoreTests",
        }
        inventory = payload["inventory"]
        assert set(inventory["targets"]) == set(FIXTURE_TEST_TARGETS)
        assert set(inventory["countsByTarget"]) == set(FIXTURE_TEST_TARGETS)
        assert set(inventory["shardsByTarget"]) == set(FIXTURE_TEST_TARGETS)
        assert all(inventory["shardsByTarget"][target] for target in FIXTURE_TEST_TARGETS)
        assert all(
            inventory["shardsByTarget"][target][0].startswith("leaf-")
            for target in leaf_targets
        )
        assert {
            test.split(".", 1)[0]
            for shard in shards
            if shard["slug"].startswith("leaf-")
            for test in shard["tests"]
        } == leaf_targets
        markdown_large = [
            shard
            for shard in shards
            if all(".MarkdownLarge/" in test for test in shard["tests"])
        ]
        assert [len(shard["tests"]) for shard in markdown_large] == [200, 1]
        assert [shard["slug"] for shard in markdown_large] == [
            "leaf-01-publishingmarkdowncoretests-01",
            "leaf-01-publishingmarkdowncoretests-02",
        ]
        oversized_suite_chunks = mac_large + core_large + markdown_large
        for shard in oversized_suite_chunks:
            assert shard["filter"].startswith("^(?:")
            assert shard["filter"].endswith(")$")
            matcher = re.compile(shard["filter"])
            assert {
                test for test in fixture_inventory() if matcher.search(test)
            } == set(shard["tests"])
        for shard in shards:
            target = shard["tests"][0].split(".", 1)[0]
            maximum_tests = (
                60
                if target == "PersonalSitePublisherMacTests"
                else 150
                if target == "PublishingWorkbenchCoreTests"
                else 200
            )
            assert len(shard["tests"]) <= maximum_tests
            if shard in core:
                suites = {test.split("/", 1)[0] for test in shard["tests"]}
                assert len(suites) <= 12
            if shard["slug"].startswith("mac-batch-"):
                suites = {test.split("/", 1)[0] for test in shard["tests"]}
                assert len(suites) <= 4
            assert shard["executedXCTestCount"] == shard["expectedXCTestCount"]
            assert shard["executedSwiftTestingCount"] == shard["expectedSwiftTestingCount"]
            assert "timeoutSeconds: 120.0" in Path(shard["logPath"]).read_text(encoding="utf-8")
            assert "terminationGraceSeconds: 2.0" in Path(shard["logPath"]).read_text(encoding="utf-8")
        assert payload["swiftTestBuildArguments"] == [
            "-Xswiftc",
            "-strict-concurrency=complete",
            "-Xswiftc",
            "-warnings-as-errors",
        ]


def test_swift_cache_environment_is_local_and_explicit_values_are_preserved() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(root, paths, HOME="/inherited/user-home")
        assert result.returncode == 0, result.stderr
        environment_calls = read_environment_calls(paths)
        assert environment_calls
        expected_keys = {
            "HOME",
            "XDG_CACHE_HOME",
            "CLANG_MODULE_CACHE_PATH",
            "SWIFT_MODULE_CACHE_PATH",
        }
        assert all(set(call) == expected_keys for call in environment_calls)
        for key in expected_keys:
            values = {call[key] for call in environment_calls}
            assert len(values) == 1
            value = next(iter(values))
            assert value is not None
            assert value.startswith(str(root.resolve() / ".build" / "swift-test-shards"))
            assert Path(value).exists()

    temporary, root, paths = make_fixture()
    with temporary:
        build_home = root / "caller-build-home"
        result = run_fixture(root, paths, SWIFT_BUILD_HOME=str(build_home))
        assert result.returncode == 0, result.stderr
        environment_calls = read_environment_calls(paths)
        assert environment_calls
        assert all(call["HOME"] == str(build_home) for call in environment_calls)
        assert all(
            value is not None and value.startswith(str(build_home))
            for call in environment_calls
            for key, value in call.items()
            if key != "HOME"
        )

    temporary, root, paths = make_fixture()
    with temporary:
        explicit = {
            "SWIFT_BUILD_HOME": str(root / "lower-priority-build-home"),
            "SWIFT_TEST_HOME": str(root / "caller-home"),
            "XDG_CACHE_HOME": str(root / "caller-xdg-cache"),
            "CLANG_MODULE_CACHE_PATH": str(root / "caller-clang-cache"),
            "SWIFT_MODULE_CACHE_PATH": str(root / "caller-swift-cache"),
        }
        result = run_fixture(root, paths, **explicit)
        assert result.returncode == 0, result.stderr
        environment_calls = read_environment_calls(paths)
        assert environment_calls
        expected = {
            "HOME": explicit["SWIFT_TEST_HOME"],
            "XDG_CACHE_HOME": explicit["XDG_CACHE_HOME"],
            "CLANG_MODULE_CACHE_PATH": explicit["CLANG_MODULE_CACHE_PATH"],
            "SWIFT_MODULE_CACHE_PATH": explicit["SWIFT_MODULE_CACHE_PATH"],
        }
        assert all(call == expected for call in environment_calls)
        payload = read_result(root)
        assert payload["swiftCacheEnvironment"] == expected


def test_warnings_as_errors_can_be_explicitly_disabled() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(root, paths, SWIFT_TEST_WARNINGS_AS_ERRORS="0")
        assert result.returncode == 0, result.stderr
        calls = read_calls(paths)
        assert calls[0] == [
            "test",
            "--disable-sandbox",
            "-Xswiftc",
            "-strict-concurrency=complete",
            "list",
        ]
        payload = read_result(root)
        assert payload["swiftTestBuildArguments"] == [
            "-Xswiftc",
            "-strict-concurrency=complete",
        ]


def test_invalid_warnings_as_errors_configuration_fails_closed() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        result = run_fixture(root, paths, SWIFT_TEST_WARNINGS_AS_ERRORS="maybe")
        assert result.returncode == 2, result
        assert "SWIFT_TEST_WARNINGS_AS_ERRORS must be a boolean value" in result.stderr
        assert read_calls(paths) == []
        assert read_result(root)["status"] == "failed"


def test_manifest_inventory_and_baseline_contracts() -> None:
    temporary, root, paths = make_fixture(extra_target=True)
    with temporary:
        result = run_fixture(root, paths)
        assert result.returncode == 0, result.stderr
        payload = read_result(root)
        assert payload["inventory"]["countsByTarget"]["FutureTests"] == 1
        assert payload["inventory"]["shardsByTarget"]["FutureTests"]

    for options, expected_message, expected_calls in (
        ({"unknown_inventory": True}, "unknown Swift test target", 1),
        ({"duplicate_inventory": True}, "duplicate test specifications", 1),
        ({"raise_baseline": True}, "fell below", 1),
        (
            {"missing_baseline_target": "PublishingMarkdownCoreTests"},
            "quality baselines must define every manifest Swift test target",
            0,
        ),
        (
            {"extra_baseline_target": "GhostTests"},
            "quality baselines must define every manifest Swift test target",
            0,
        ),
    ):
        temporary, root, paths = make_fixture(**options)
        with temporary:
            result = run_fixture(root, paths)
            assert result.returncode == 2, result
            assert expected_message in result.stderr
            assert len(read_calls(paths)) == expected_calls
            assert read_result(root)["status"] == "failed"

    for missing_suite in (
        "WorkbenchImageTwoTierCacheTests",
        "WebContentNetworkSecurityTests",
        "SettingsSearchAndSavePresentationTests",
    ):
        temporary, root, paths = make_fixture(missing_suite=missing_suite)
        with temporary:
            result = run_fixture(root, paths)
            assert result.returncode == 0, result.stderr


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


def test_timeout_kills_descendant_after_it_changes_process_group() -> None:
    temporary, root, paths = make_fixture()
    with temporary:
        try:
            result = run_fixture(
                root,
                paths,
                SWIFT_PGID_ESCAPE_AT="2",
                PS_BIN=paths["failing_ps"],
                SWIFT_TEST_SHARD_RETRIES="0",
                SWIFT_TEST_SHARD_TIMEOUT_SECONDS="0.5",
                SWIFT_TEST_TERMINATION_GRACE_SECONDS="0.2",
            )
            assert result.returncode == 124, result
            wait_for_path(Path(paths["pgid_escape_ready"]))
            child_pid = int(Path(paths["hang_child_pid"]).read_text(encoding="utf-8"))
            child_pgid = int(Path(paths["hang_child_pgid"]).read_text(encoding="utf-8"))
            escaped_pgid = int(
                Path(paths["pgid_escape_ready"]).read_text(encoding="utf-8")
            )
            root_pgid = int(Path(paths["hang_root_pgid"]).read_text(encoding="utf-8"))
            assert child_pgid == root_pgid
            assert escaped_pgid != root_pgid
            time.sleep(0.1)
            assert not process_exists(child_pid), child_pid
        finally:
            if Path(paths["hang_child_pid"]).exists():
                child_pid = int(Path(paths["hang_child_pid"]).read_text(encoding="utf-8"))
                if process_exists(child_pid):
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


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
        failed = next(
            shard for shard in payload["shards"] if shard["slug"] == "web-content-security"
        )
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
    test_swift_cache_environment_is_local_and_explicit_values_are_preserved()
    test_warnings_as_errors_can_be_explicitly_disabled()
    test_invalid_warnings_as_errors_configuration_fails_closed()
    test_manifest_inventory_and_baseline_contracts()
    test_shard_retry_configuration_is_bounded()
    test_nonzero_shard_fails_fast_with_incremental_result()
    test_timeout_retries_once_then_passes_with_distinct_evidence()
    test_repeated_timeout_retries_once_then_fails_closed()
    test_timeout_samples_and_removes_child_process_group()
    test_timeout_kills_descendant_after_it_changes_process_group()
    test_leader_exit_cleans_detached_child_and_fails_missing_counts()
    test_external_sigterm_is_forwarded_to_active_shard()
    print("swift test process runner contract: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
