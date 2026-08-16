#!/usr/bin/env python3
"""Regression tests for check_swift_coverage.py report validation."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "script" / "check_swift_coverage.py"


def load_gate_module() -> object:
    spec = importlib.util.spec_from_file_location("check_swift_coverage", GATE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    gate = load_gate_module()
    inventory = "\n".join(
        [
            "ModuleTests.FirstSuite/testOne",
            "ModuleTests.FirstSuite/testTwo",
            "ModuleTests.SecondSuite/testThree()",
            "OtherTests.OnlySuite/testFour",
        ]
    )
    batches = gate.coverage_batches_from_inventory(inventory)
    assert len(batches) == 2, batches
    assert sum(batch.test_count for batch in batches) == 4, batches
    assert batches[0].suites == ("FirstSuite", "SecondSuite"), batches
    build_command = gate.coverage_build_command(
        "swift",
        Path("/tmp/coverage-scratch"),
        Path("/tmp/coverage-home"),
    )
    assert build_command[1] == "build", build_command
    assert "--enable-code-coverage" in build_command, build_command
    assert "--build-tests" in build_command, build_command
    list_command = gate.coverage_list_command(
        "swift",
        Path("/tmp/coverage-scratch"),
        Path("/tmp/coverage-home"),
    )
    assert list_command[1] == "test", list_command
    assert "--skip-build" in list_command, list_command
    assert list_command[-1] == "list", list_command
    command = gate.coverage_batch_command(
        "swift",
        Path("/tmp/coverage-scratch"),
        Path("/tmp/coverage-home"),
        batches[0],
    )
    assert "--enable-code-coverage" in command, command
    assert "--skip-build" not in command, command
    assert "--parallel" not in command, command
    assert command[command.index("--filter") + 1] == batches[0].filter_pattern, command

    assert gate.coverage_batch_retries({}) == 1
    assert gate.coverage_batch_retries({"SWIFT_COVERAGE_BATCH_RETRIES": "0"}) == 0
    assert gate.coverage_batch_retries({"SWIFT_COVERAGE_BATCH_RETRIES": "2"}) == 2

    class FakeProcess:
        next_pid = 1000

        def __init__(self) -> None:
            self.pid = FakeProcess.next_pid
            FakeProcess.next_pid += 1
            self.wait_calls = 0

        def wait(self, timeout: float | None = None) -> int:
            self.wait_calls += 1
            if self.pid == 1000 and self.wait_calls == 1:
                raise subprocess.TimeoutExpired("swift test", timeout)
            return 0

    processes: list[FakeProcess] = []
    killed_groups: list[tuple[int, int]] = []

    def fake_popen(*_args: object, **_kwargs: object) -> FakeProcess:
        process = FakeProcess()
        processes.append(process)
        return process

    original_popen = gate.subprocess.Popen
    original_killpg = gate.os.killpg
    gate.subprocess.Popen = fake_popen
    gate.os.killpg = lambda process_group, signal_number: killed_groups.append(
        (process_group, signal_number)
    )
    try:
        gate.run_coverage_batch(
            ["swift", "test"],
            root=Path("/tmp/coverage-root"),
            environment={},
            label="PublishingWorkbenchCoreTests: 1 suite, 1 test",
            timeout_seconds=1,
            retries=1,
        )
    finally:
        gate.subprocess.Popen = original_popen
        gate.os.killpg = original_killpg
    assert len(processes) == 2, processes
    assert killed_groups == [(1000, gate.signal.SIGTERM)], killed_groups

    with tempfile.TemporaryDirectory(prefix="swift-coverage-gate.") as temporary:
        fixture = Path(temporary)
        source = fixture / "Sources" / "Module" / "Feature.swift"
        source.parent.mkdir(parents=True)
        source.write_text("struct Feature {}\n", encoding="utf-8")
        coverage = fixture / "coverage.json"
        coverage.write_text(
            json.dumps(
                {
                    "data": [
                        {
                            "files": [
                                {
                                    "filename": str(source),
                                    "summary": {"lines": {"count": 10, "covered": 8}},
                                },
                                {
                                    "filename": str(fixture / "Tests" / "FeatureTests.swift"),
                                    "summary": {"lines": {"count": 100, "covered": 100}},
                                },
                            ]
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        baseline = fixture / "baseline.json"
        baseline.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "swiftFormatWarningMaximum": 0,
                    "sourceLineCoveragePercentMinimum": 80,
                }
            ),
            encoding="utf-8",
        )
        accepted = subprocess.run(
            [
                "python3",
                str(GATE),
                "--root",
                str(fixture),
                "--baseline",
                str(baseline),
                "--coverage-json",
                str(coverage),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        assert accepted.returncode == 0, accepted.stderr
        assert "8/10 Sources lines" in accepted.stdout, accepted.stdout

        baseline.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "swiftFormatWarningMaximum": 0,
                    "sourceLineCoveragePercentMinimum": 80.01,
                }
            ),
            encoding="utf-8",
        )
        rejected = subprocess.run(accepted.args, text=True, capture_output=True, check=False)
        assert rejected.returncode != 0, rejected
        assert "below progressive baseline" in rejected.stderr, rejected.stderr

    print("swift coverage gate test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
