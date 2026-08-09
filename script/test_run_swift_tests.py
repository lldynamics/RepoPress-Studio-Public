#!/usr/bin/env python3
"""Contract tests for the isolated SwiftPM test shard runner."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "script" / "run_swift_tests.sh"
CACHE_FILTER = r"^PersonalSitePublisherMacTests\.WorkbenchImageTwoTierCacheTests"
MAC_FILTER = r"^PersonalSitePublisherMacTests\."
CORE_FILTER = r"^PublishingWorkbenchCoreTests\."
EXPECTED_CALLS = [
    ["test", "--disable-sandbox", "--filter", CACHE_FILTER],
    [
        "test",
        "--disable-sandbox",
        "--skip-build",
        "--filter",
        MAC_FILTER,
        "--skip",
        CACHE_FILTER,
    ],
    ["test", "--disable-sandbox", "--skip-build", "--filter", CORE_FILTER],
]


PACKAGE_TEMPLATE = """\
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: \"Fixture\",
  targets: [
    .target(name: \"App\"),
    .testTarget(name: \"PublishingWorkbenchCoreTests\", dependencies: [\"App\"]),
    .testTarget(name: \"PersonalSitePublisherMacTests\", dependencies: [\"App\"]),
{extra_target}  ]
)
"""


FAKE_SWIFT = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

log_path = Path(os.environ["SWIFT_CALL_LOG"])
calls = []
if log_path.exists():
    calls = json.loads(log_path.read_text(encoding="utf-8"))
calls.append(sys.argv[1:])
log_path.write_text(json.dumps(calls), encoding="utf-8")
fail_at = int(os.environ.get("SWIFT_FAIL_AT", "0"))
if fail_at and len(calls) == fail_at:
    raise SystemExit(int(os.environ.get("SWIFT_FAIL_CODE", "19")))
'''


def make_fixture(extra_target: str = "") -> tuple[tempfile.TemporaryDirectory[str], Path, Path]:
    temporary = tempfile.TemporaryDirectory(prefix="swift-test-shards.")
    root = Path(temporary.name)
    script_dir = root / "script"
    bin_dir = root / "bin"
    script_dir.mkdir()
    bin_dir.mkdir()
    shutil.copy2(RUNNER, script_dir / RUNNER.name)
    (script_dir / RUNNER.name).chmod(0o755)
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
    fake_swift = bin_dir / "swift"
    fake_swift.write_text(FAKE_SWIFT, encoding="utf-8")
    fake_swift.chmod(0o755)
    return temporary, root, root / "calls.json"


def run_fixture(root: Path, call_log: Path, **extra_environment: str) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{root / 'bin'}:{environment['PATH']}",
            "SWIFT_CALL_LOG": str(call_log),
            **extra_environment,
        }
    )
    return subprocess.run(
        [str(root / "script" / RUNNER.name)],
        cwd=root,
        env=environment,
        text=True,
        capture_output=True,
    )


def read_calls(call_log: Path) -> list[list[str]]:
    if not call_log.exists():
        return []
    return json.loads(call_log.read_text(encoding="utf-8"))


def test_exact_argv_and_order() -> None:
    temporary, root, call_log = make_fixture()
    with temporary:
        result = run_fixture(root, call_log)
        assert result.returncode == 0, result.stderr
        assert read_calls(call_log) == EXPECTED_CALLS
        assert "three isolated test processes passed" in result.stdout


def test_fail_fast() -> None:
    temporary, root, call_log = make_fixture()
    with temporary:
        result = run_fixture(root, call_log, SWIFT_FAIL_AT="2", SWIFT_FAIL_CODE="23")
        assert result.returncode == 23, result
        assert read_calls(call_log) == EXPECTED_CALLS[:2]
        assert "PublishingWorkbenchCoreTests" not in result.stdout


def test_unexpected_test_target_fails_closed() -> None:
    temporary, root, call_log = make_fixture(extra_target="FutureTests")
    with temporary:
        result = run_fixture(root, call_log)
        assert result.returncode != 0, result
        assert read_calls(call_log) == []
        assert "unexpected Swift test target set" in result.stderr


def main() -> int:
    test_exact_argv_and_order()
    test_fail_fast()
    test_unexpected_test_target_fails_closed()
    print("swift test shard runner contract test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
