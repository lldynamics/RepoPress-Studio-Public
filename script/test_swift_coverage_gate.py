#!/usr/bin/env python3
"""Regression tests for target and changed-line Swift coverage enforcement."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from quality_gate_common import changed_lines, parse_unified_zero_diff


ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "script" / "check_swift_coverage.py"


def load_gate_module() -> object:
    spec = importlib.util.spec_from_file_location("check_swift_coverage", GATE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run(*arguments: str, cwd: Path) -> None:
    subprocess.run(arguments, cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def baseline(target_b_minimum: float = 40, changed_minimum: float = 50) -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "sourceLineCoveragePercentMinimum": 40,
        "sourceLineCoveragePercentMinimumByTarget": {"TargetA": 40, "TargetB": target_b_minimum},
        "changedExecutableSourceLineCoveragePercentMinimum": changed_minimum,
        "swiftFormatWarningMaximums": {
            "sourcesByTarget": {"TargetA": 0, "TargetB": 0},
            "testsByTarget": {},
            "packageSwift": 0,
            "changedLines": 0,
        },
    }


def coverage_payload(root: Path, target_b_covered: int = 1) -> dict[str, object]:
    def entry(target: str, covered: int, segments: list[list[object]]) -> dict[str, object]:
        return {
            "filename": str(root / "Sources" / target / "Feature.swift"),
            "summary": {"lines": {"count": 2, "covered": covered}},
            "segments": segments,
        }

    return {
        "data": [{"files": [
            entry("TargetA", 1, [[1, 1, 1, True, True, False], [2, 1, 0, True, True, False], [3, 1, 0, False, False, False]]),
            entry("TargetB", target_b_covered, [[1, 1, 1, True, True, False], [2, 1, 0, True, True, False], [3, 1, 0, False, False, False]]),
            {
                "filename": str(root / "Tests" / "TargetATests" / "FeatureTests.swift"),
                "summary": {"lines": {"count": 99, "covered": 99}},
                "segments": [[1, 1, 1, True, True, False]],
            },
        ]}]}


def main() -> int:
    gate = load_gate_module()
    assert not gate.meets_minimum(1, 15_000, 0.01)
    assert gate.meets_minimum(1, 10_000, 0.01)
    assert not gate.meets_minimum(19_999, 20_000, 100)
    assert gate.meets_minimum(20_000, 20_000, 100)

    inventory = "\n".join([
        "ModuleTests.FirstSuite/testOne",
        "ModuleTests.FirstSuite/testTwo",
        "ModuleTests.SecondSuite/testThree(value: 1, type: Int)",
        "OtherTests.OnlySuite/testFour",
    ])
    batches = gate.coverage_batches_from_inventory(inventory)
    assert len(batches) == 2 and sum(batch.test_count for batch in batches) == 4, batches
    assert batches[0].suites == ("FirstSuite", "SecondSuite"), batches
    assert "--build-tests" in gate.coverage_build_command("swift", Path("/tmp/a"), Path("/tmp/b"))
    assert "--skip-build" in gate.coverage_batch_command(
        "swift", Path("/tmp/a"), Path("/tmp/b"), batches[0]
    )
    assert gate.coverage_batch_retries({}) == 1

    # The timeout path captures an actual xctest descendant, rather than only
    # assuming the `swift test` wrapper process is enough to kill.
    captured = gate.xctest_pids_from_process_rows(100, [
        "100 1 /usr/bin/swift test",
        "101 100 /bin/sh runner",
        "102 101 /tmp/Tests.xctest/Contents/MacOS/Tests",
        "103 102 helper",
        "104 100 /usr/bin/log",
    ])
    assert captured == {102}, captured

    assert parse_unified_zero_diff(
        "+++ b/Sources/A/F.swift\n@@ -2,2 +2,3 @@\n-x\n+y\n+z\n+++ b/Sources/A/G.swift\n@@ -1 +0,0 @@\n-x\n"
    ) == {"Sources/A/F.swift": {2, 3, 4}}
    interval_evidence = gate.executable_line_evidence(
        {
            "segments": [
                [1, 1, 3, True, True, False],
                [2, 10, 0, True, False, False],
                [4, 1, 0, False, False, False],
            ]
        }
    )
    assert interval_evidence == {1: True, 2: True, 3: False}, interval_evidence
    changed_covered, changed_count, _files, unmatched, no_executable = gate.changed_source_line_coverage(
        Path("/fixture"),
        {"Sources/TargetA/Feature.swift": {2, 3}},
        {Path("/fixture/Sources/TargetA/Feature.swift"): interval_evidence},
    )
    assert (changed_covered, changed_count) == (1, 2)
    assert unmatched == [] and no_executable == []

    compiled_declaration = Path("/fixture/Sources/TargetA/CompiledDeclaration.swift")
    changed_covered, changed_count, _files, unmatched, no_executable = gate.changed_source_line_coverage(
        Path("/fixture"),
        {"Sources/TargetA/CompiledDeclaration.swift": {1}},
        {},
        {compiled_declaration},
    )
    assert (changed_covered, changed_count) == (0, 0)
    assert unmatched == []
    assert no_executable == ["Sources/TargetA/CompiledDeclaration.swift"]

    with tempfile.TemporaryDirectory(prefix="swift-coverage-gate.") as temporary:
        fixture = Path(temporary)
        for target in ("TargetA", "TargetB"):
            path = fixture / "Sources" / target / "Feature.swift"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("let value = 1\n", encoding="utf-8")
        test_path = fixture / "Tests" / "TargetATests" / "FeatureTests.swift"
        test_path.parent.mkdir(parents=True)
        test_path.write_text("func testFeature() {}\n", encoding="utf-8")
        run("git", "init", "-q", cwd=fixture)
        run("git", "add", "Sources", "Tests", cwd=fixture)
        run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "baseline", cwd=fixture)
        (fixture / "Sources" / "TargetA" / "Feature.swift").write_text("let value = 2\nlet newValue = 3\n", encoding="utf-8")
        # A changed Tests line must not enter the changed executable Sources denominator.
        test_path.write_text("func testFeature() { _ = 1 }\n", encoding="utf-8")

        coverage = fixture / "coverage.json"
        coverage.write_text(json.dumps(coverage_payload(fixture)), encoding="utf-8")
        baseline_path = fixture / "baseline.json"
        baseline_path.write_text(json.dumps(baseline()), encoding="utf-8")
        result_path = fixture / "result.json"
        command = ["python3", str(GATE), "--root", str(fixture), "--baseline", str(baseline_path),
                   "--coverage-json", str(coverage), "--result-json", str(result_path)]
        accepted = subprocess.run(command, text=True, capture_output=True, check=False)
        assert accepted.returncode == 0, accepted.stderr
        result = json.loads(result_path.read_text(encoding="utf-8"))
        assert result["sourceLines"]["count"] == 4 and result["targets"]["TargetA"]["count"] == 2, result
        assert result["sourceLines"]["meetsMinimum"] is True, result
        assert result["targets"]["TargetA"]["meetsMinimum"] is True, result
        assert result["changedExecutableSourceLines"]["covered"] == 1
        assert result["changedExecutableSourceLines"]["count"] == 2, result
        assert result["changedExecutableSourceLines"]["meetsMinimum"] is True, result
        assert result["changedExecutableSourceLines"]["unmatchedChangedSourceFiles"] == [], result
        assert result["changedExecutableSourceLines"]["noExecutableChangedLineFiles"] == [], result

        no_executable_path = fixture / "Sources" / "TargetA" / "Declarations.swift"
        no_executable_path.write_text("struct DeclarationOnly {}\n", encoding="utf-8")
        payload_with_declaration = coverage_payload(fixture)
        payload_with_declaration["data"][0]["files"].append(
            {
                "filename": str(no_executable_path),
                "summary": {"lines": {"count": 0, "covered": 0}},
                "segments": [[1, 1, 0, False, False, False]],
            }
        )
        coverage.write_text(json.dumps(payload_with_declaration), encoding="utf-8")
        declaration_accepted = subprocess.run(command, text=True, capture_output=True, check=False)
        assert declaration_accepted.returncode == 0, declaration_accepted.stderr
        declaration_result = json.loads(result_path.read_text(encoding="utf-8"))
        assert declaration_result["changedExecutableSourceLines"]["noExecutableChangedLineFiles"] == [
            "Sources/TargetA/Declarations.swift"
        ], declaration_result

        missing_path = fixture / "Sources" / "TargetA" / "Missing.swift"
        missing_path.write_text("let missingFromCoverage = true\n", encoding="utf-8")
        missing_rejected = subprocess.run(command, text=True, capture_output=True, check=False)
        assert missing_rejected.returncode != 0, missing_rejected.stdout
        assert "coverage JSON contains no file entry" in missing_rejected.stderr, missing_rejected.stderr
        missing_result = json.loads(result_path.read_text(encoding="utf-8"))
        assert missing_result["changedExecutableSourceLines"]["unmatchedChangedSourceFiles"] == [
            "Sources/TargetA/Missing.swift"
        ], missing_result
        missing_path.unlink()

        compiled_only_path = fixture / "Sources" / "TargetA" / "CompiledOnly.swift"
        compiled_only_path.write_text("struct CompiledOnly {}\n", encoding="utf-8")
        build_description = fixture / "description.json"
        build_description.write_text(
            json.dumps(
                {
                    "swiftCommands": {
                        "TargetA": {
                            "sources": [
                                str(fixture / "Sources" / "TargetA" / "Feature.swift"),
                                str(no_executable_path),
                                str(compiled_only_path),
                            ]
                        },
                        "TargetB": {
                            "sources": [str(fixture / "Sources" / "TargetB" / "Feature.swift")]
                        },
                    }
                }
            ),
            encoding="utf-8",
        )
        compiled_only_accepted = subprocess.run(
            command + ["--swift-build-description", str(build_description)],
            text=True,
            capture_output=True,
            check=False,
        )
        assert compiled_only_accepted.returncode == 0, compiled_only_accepted.stderr
        compiled_only_result = json.loads(result_path.read_text(encoding="utf-8"))
        assert compiled_only_result["changedExecutableSourceLines"]["unmatchedChangedSourceFiles"] == []
        assert "Sources/TargetA/CompiledOnly.swift" in compiled_only_result[
            "changedExecutableSourceLines"
        ]["noExecutableChangedLineFiles"]
        compiled_only_path.unlink()

        baseline_path.write_text(json.dumps(baseline(changed_minimum=100)), encoding="utf-8")
        uncovered = subprocess.run(command, text=True, capture_output=True, check=False)
        assert uncovered.returncode != 0 and "changed executable" in uncovered.stderr, uncovered.stderr

        baseline_path.write_text(json.dumps(baseline(target_b_minimum=60)), encoding="utf-8")
        target_failure = subprocess.run(command, text=True, capture_output=True, check=False)
        assert target_failure.returncode != 0 and "TargetB" in target_failure.stderr, target_failure.stderr

        invalid_base = subprocess.run(command + ["--diff-base", "does-not-exist"], text=True, capture_output=True, check=False)
        assert invalid_base.returncode != 0 and "invalid" in invalid_base.stderr, invalid_base.stderr

        invalid_schema = baseline()
        invalid_schema["schemaVersion"] = 1
        baseline_path.write_text(json.dumps(invalid_schema), encoding="utf-8")
        schema_failure = subprocess.run(command, text=True, capture_output=True, check=False)
        assert schema_failure.returncode != 0 and "schemaVersion" in schema_failure.stderr, schema_failure.stderr

        # A clean checkout can still compare committed work to an explicit local base.
        baseline_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=fixture, text=True, capture_output=True, check=True
        ).stdout.strip()
        run("git", "add", "Sources", "Tests", cwd=fixture)
        run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "changed", cwd=fixture)
        committed = changed_lines(fixture, baseline_commit)
        assert committed["Sources/TargetA/Feature.swift"] == {1, 2}, committed
        zero_sha_fallback = changed_lines(fixture, "0" * 40)
        assert zero_sha_fallback["Sources/TargetA/Feature.swift"] == {1, 2}, zero_sha_fallback
        untracked = fixture / "Sources" / "TargetA" / "Untracked.swift"
        untracked.write_text("let fresh = 1\nlet second = 2\n", encoding="utf-8")
        assert changed_lines(fixture, baseline_commit)["Sources/TargetA/Untracked.swift"] == {1, 2}

    print("swift coverage gate test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
