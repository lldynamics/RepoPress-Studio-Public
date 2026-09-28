#!/usr/bin/env python3
"""Fixtures for the fail-closed monotonic quality-baseline policy."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "script" / "check_quality_baseline_policy.py"


def run(*args: str, cwd: Path) -> None:
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


def v1() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "swiftFormatWarningMaximum": 6,
        "sourceLineCoveragePercentMinimum": 40,
        "swiftTestMinimumCountsByTarget": {"TargetATests": 5},
    }


def v2() -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "sourceLineCoveragePercentMinimum": 40,
        "sourceLineCoveragePercentMinimumByTarget": {"TargetA": 40},
        "changedExecutableSourceLineCoveragePercentMinimum": 100,
        "swiftFormatWarningMaximums": {
            "sourcesByTarget": {"TargetA": 3},
            "testsByTarget": {"TargetATests": 2},
            "packageSwift": 1,
            "changedLines": 0,
        },
        "swiftTestMinimumCountsByTarget": {"TargetATests": 5},
        "swiftModuleBoundaryMaximums": {
            "publishingWorkbenchCoreImportsByScope": {
                "Sources": 4,
                "Tests": 3,
            }
        },
        "sourceFileLineMaximums": {
            "defaultMaximum": 600,
            "existingFileMaximums": {},
        },
        "releasePerformance": {
            "schemaVersion": 1,
            "configuration": "release",
            "minimumSampleCount": 7,
            "siteMaintenanceRelation": {
                "sizes": [512, 2048, 4096],
                "labelGroupSize": 8,
                "complexity": "fixed-label-density-linear",
            },
            "wallTime": {
                "policy": "trend-only",
                "blocking": False,
            },
        },
    }


def write(repo: Path, payload: dict[str, object]) -> None:
    path = repo / "script" / "quality_baselines.json"
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_target(repo: Path, parent: str, target: str, *, present: bool) -> None:
    directory = repo / parent / target
    if present:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "Fixture.swift").write_text("fixture\n", encoding="utf-8")
    else:
        fixture = directory / "Fixture.swift"
        if fixture.exists():
            fixture.unlink()
        if directory.exists():
            directory.rmdir()


def write_package(repo: Path, *, source_present: bool, test_present: bool) -> None:
    names = []
    if source_present:
        names.append('name: "TargetA"')
    if test_present:
        names.append('name: "TargetATests"')
    (repo / "Package.swift").write_text("\n".join(names) + "\n", encoding="utf-8")


def invoke(
    repo: Path, base: str | None = None, *, tighten_source_lines: bool = False
) -> subprocess.CompletedProcess[str]:
    command = ["python3", str(GATE), "--root", str(repo)]
    if base is not None:
        command.extend(["--diff-base", base])
    if tighten_source_lines:
        command.append("--tighten-source-lines")
    return subprocess.run(command, cwd=repo, capture_output=True, text=True, check=False)


def expect_failure(repo: Path, payload: dict[str, object], needle: str) -> None:
    write(repo, payload)
    result = invoke(repo)
    assert result.returncode != 0, result.stdout
    assert needle in result.stderr, result.stderr


def write_swift_lines(repo: Path, relative: str, line_count: int) -> None:
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"// fixture {index}\n" for index in range(line_count)), encoding="utf-8")


def source_file_line_limit_fixtures() -> None:
    """Exercise actual Sources line limits and their monotonic baseline policy."""
    with tempfile.TemporaryDirectory(prefix="quality-baseline-policy-source-bootstrap.") as temporary:
        repo = Path(temporary)
        run("git", "init", "-q", cwd=repo)
        old_baseline = v2()
        old_baseline.pop("sourceFileLineMaximums")
        write(repo, old_baseline)
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 620)
        write_package(repo, source_present=True, test_present=False)
        run("git", "add", ".", cwd=repo)
        run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "old", cwd=repo)

        bootstrapped = v2()
        bootstrapped["sourceFileLineMaximums"]["existingFileMaximums"] = {
            "Sources/TargetA/Legacy.swift": 620,
        }
        write(repo, bootstrapped)
        bootstrap = invoke(repo)
        assert bootstrap.returncode == 0, bootstrap.stderr

        write_swift_lines(repo, "Sources/TargetA/New.swift", 601)
        bootstrapped["sourceFileLineMaximums"]["existingFileMaximums"]["Sources/TargetA/New.swift"] = 601
        expect_failure(
            repo,
            bootstrapped,
            "initial existing-file maximum requires a source file present at the comparison base",
        )

    with tempfile.TemporaryDirectory(prefix="quality-baseline-policy-source-lines.") as temporary:
        repo = Path(temporary)
        run("git", "init", "-q", cwd=repo)
        baseline = v2()
        baseline["sourceFileLineMaximums"]["existingFileMaximums"] = {
            "Sources/TargetA/Legacy.swift": 620,
        }
        write(repo, baseline)
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 620)
        write_swift_lines(repo, "Sources/TargetA/Regular.swift", 600)
        write_package(repo, source_present=True, test_present=False)
        run("git", "add", ".", cwd=repo)
        run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "base", cwd=repo)

        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 621)
        grown = invoke(repo)
        assert grown.returncode != 0 and "Legacy.swift has 621 lines" in grown.stderr, grown.stderr
        cannot_auto_widen = invoke(repo, tighten_source_lines=True)
        assert cannot_auto_widen.returncode != 0 and "Legacy.swift has 621 lines" in cannot_auto_widen.stderr, cannot_auto_widen.stderr
        assert json.loads((repo / "script/quality_baselines.json").read_text())[
            "sourceFileLineMaximums"
        ]["existingFileMaximums"]["Sources/TargetA/Legacy.swift"] == 620

        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 619)
        shrunk = invoke(repo)
        assert shrunk.returncode != 0 and "is stale" in shrunk.stderr, shrunk.stderr
        tightened = invoke(repo, tighten_source_lines=True)
        assert tightened.returncode == 0, tightened.stderr
        assert "source-file ceilings tightened: 1" in tightened.stdout, tightened.stdout
        assert json.loads((repo / "script/quality_baselines.json").read_text())[
            "sourceFileLineMaximums"
        ]["existingFileMaximums"]["Sources/TargetA/Legacy.swift"] == 619
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 620)
        regrown = invoke(repo)
        assert regrown.returncode != 0 and "Legacy.swift has 620 lines" in regrown.stderr, regrown.stderr
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 619)

        write_swift_lines(repo, "Sources/TargetA/Regular.swift", 601)
        ordinary_crossing = invoke(repo)
        assert ordinary_crossing.returncode != 0 and "Regular.swift has 601 lines" in ordinary_crossing.stderr, ordinary_crossing.stderr
        write_swift_lines(repo, "Sources/TargetA/Regular.swift", 600)

        write_swift_lines(repo, "Sources/TargetA/New.swift", 601)
        new_large_file = invoke(repo)
        assert new_large_file.returncode != 0 and "New.swift has 601 lines" in new_large_file.stderr, new_large_file.stderr
        (repo / "Sources/TargetA/New.swift").unlink()

        raised = v2()
        raised["sourceFileLineMaximums"]["existingFileMaximums"] = {
            "Sources/TargetA/Legacy.swift": 621,
        }
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 621)
        expect_failure(repo, raised, "Swift source file maximum Sources/TargetA/Legacy.swift increased")
        write(repo, baseline)
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 619)

        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 600)
        tightened_to_default = invoke(repo, tighten_source_lines=True)
        assert tightened_to_default.returncode == 0, tightened_to_default.stderr
        assert "Sources/TargetA/Legacy.swift" not in json.loads(
            (repo / "script/quality_baselines.json").read_text()
        )["sourceFileLineMaximums"]["existingFileMaximums"]
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 601)
        regrown_past_default = invoke(repo)
        assert regrown_past_default.returncode != 0 and "without a reviewed" in regrown_past_default.stderr, regrown_past_default.stderr
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 600)

        (repo / "Sources/TargetA/Legacy.swift").unlink()
        deleted = v2()
        write(repo, deleted)
        deletion = invoke(repo)
        assert deletion.returncode == 0, deletion.stderr

    with tempfile.TemporaryDirectory(prefix="quality-baseline-policy-source-rename.") as temporary:
        repo = Path(temporary)
        run("git", "init", "-q", cwd=repo)
        baseline = v2()
        baseline["sourceFileLineMaximums"]["existingFileMaximums"] = {
            "Sources/TargetA/Legacy.swift": 620,
        }
        write(repo, baseline)
        write_swift_lines(repo, "Sources/TargetA/Legacy.swift", 620)
        write_package(repo, source_present=True, test_present=False)
        run("git", "add", ".", cwd=repo)
        run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "base", cwd=repo)

        old_path = repo / "Sources/TargetA/Legacy.swift"
        renamed_path = repo / "Sources/TargetA/Renamed.swift"
        old_path.replace(renamed_path)
        renamed = v2()
        renamed["sourceFileLineMaximums"]["existingFileMaximums"] = {
            "Sources/TargetA/Renamed.swift": 620,
        }
        write(repo, renamed)
        rename = invoke(repo)
        assert rename.returncode == 0, rename.stderr


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="quality-baseline-policy.") as temporary:
        repo = Path(temporary)
        run("git", "init", "-q", cwd=repo)
        write(repo, v1())
        write_target(repo, "Sources", "TargetA", present=True)
        write_target(repo, "Tests", "TargetATests", present=True)
        write_package(repo, source_present=True, test_present=True)
        run("git", "add", ".", cwd=repo)
        run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "v1", cwd=repo)

        # The actual v1-to-v2 transition is permitted only because the v2
        # buckets sum to no more than v1's one legacy total.
        write(repo, v2())
        migration = invoke(repo)
        assert migration.returncode == 0, migration.stderr
        assert "schema v1" in migration.stdout, migration.stdout

        widened_migration = v2()
        widened_migration["swiftFormatWarningMaximums"]["sourcesByTarget"]["TargetA"] = 4
        # 4 + 2 + 1 is greater than the legacy v1 total of 6, so splitting
        # the old ceiling cannot hide a format-baseline relaxation.
        expect_failure(repo, widened_migration, "total migration maximum increased")
        write(repo, v2())

        run("git", "add", ".", cwd=repo)
        run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "v2", cwd=repo)
        base = v2()

        stronger = v2()
        stronger["sourceLineCoveragePercentMinimum"] = 41
        stronger["sourceLineCoveragePercentMinimumByTarget"] = {"TargetA": 41, "TargetB": 1}
        stronger["swiftTestMinimumCountsByTarget"] = {"TargetATests": 6, "TargetBTests": 1}
        stronger["swiftFormatWarningMaximums"] = {
            "sourcesByTarget": {"TargetA": 2, "TargetB": 0},
            "testsByTarget": {"TargetATests": 1, "TargetBTests": 0},
            "packageSwift": 0,
            "changedLines": 0,
        }
        write(repo, stronger)
        accepted = invoke(repo)
        assert accepted.returncode == 0, accepted.stderr

        lower_global = v2()
        lower_global["sourceLineCoveragePercentMinimum"] = 39
        expect_failure(repo, lower_global, "global minimum decreased")

        lower_target = v2()
        lower_target["sourceLineCoveragePercentMinimumByTarget"] = {"TargetA": 39}
        expect_failure(repo, lower_target, "target TargetA decreased")

        partial_retirement = v2()
        partial_retirement["sourceLineCoveragePercentMinimumByTarget"] = {"TargetB": 1}
        partial_retirement["swiftFormatWarningMaximums"]["sourcesByTarget"] = {"TargetB": 0}
        expect_failure(repo, partial_retirement, "without a full target retirement: TargetA")

        changed_coverage = v2()
        changed_coverage["changedExecutableSourceLineCoveragePercentMinimum"] = 99
        expect_failure(repo, changed_coverage, "changed executable")

        higher_format = v2()
        higher_format["swiftFormatWarningMaximums"]["sourcesByTarget"]["TargetA"] = 4
        expect_failure(repo, higher_format, "format maximum sourcesByTarget.TargetA increased")

        added_format_bucket = v2()
        added_format_bucket["swiftFormatWarningMaximums"]["sourcesByTarget"]["TargetB"] = 1
        expect_failure(repo, added_format_bucket, "format total maximum increased")

        redistributed_format_bucket = v2()
        redistributed_format_bucket["swiftFormatWarningMaximums"]["sourcesByTarget"] = {
            "TargetA": 2,
            "TargetB": 1,
        }
        write(repo, redistributed_format_bucket)
        redistributed = invoke(repo)
        assert redistributed.returncode == 0, redistributed.stderr

        changed_format = v2()
        changed_format["swiftFormatWarningMaximums"]["changedLines"] = 1
        expect_failure(repo, changed_format, "changedLines maximum")

        lower_tests = v2()
        lower_tests["swiftTestMinimumCountsByTarget"]["TargetATests"] = 4
        expect_failure(repo, lower_tests, "Swift test target TargetATests decreased")

        higher_workbench_import_maximum = v2()
        higher_workbench_import_maximum["swiftModuleBoundaryMaximums"][
            "publishingWorkbenchCoreImportsByScope"
        ]["Sources"] = 5
        expect_failure(
            repo,
            higher_workbench_import_maximum,
            "PublishingWorkbenchCore import maximum Sources increased",
        )

        fewer_performance_samples = v2()
        fewer_performance_samples["releasePerformance"]["minimumSampleCount"] = 6
        expect_failure(repo, fewer_performance_samples, "minimum sample count decreased")

        smaller_performance_fixture = v2()
        smaller_performance_fixture["releasePerformance"]["siteMaintenanceRelation"][
            "sizes"
        ] = [512, 2048]
        expect_failure(repo, smaller_performance_fixture, "relation sizes were removed")

        weaker_performance_complexity = v2()
        weaker_performance_complexity["releasePerformance"]["siteMaintenanceRelation"][
            "complexity"
        ] = "trend-only"
        expect_failure(repo, weaker_performance_complexity, "complexity policy changed")

        invalid_new_target = v2()
        invalid_new_target["swiftTestMinimumCountsByTarget"]["TargetBTests"] = 0
        expect_failure(repo, invalid_new_target, "positive integer")

        retired = v2()
        retired["sourceLineCoveragePercentMinimumByTarget"] = {"TargetB": 1}
        retired["swiftFormatWarningMaximums"]["sourcesByTarget"] = {"TargetB": 0}
        retired["swiftTestMinimumCountsByTarget"] = {"TargetBTests": 1}
        retired["swiftFormatWarningMaximums"]["testsByTarget"] = {"TargetBTests": 0}
        write_target(repo, "Sources", "TargetA", present=False)
        write_target(repo, "Tests", "TargetATests", present=False)
        write_package(repo, source_present=False, test_present=False)
        write(repo, retired)
        accepted_retirement = invoke(repo)
        assert accepted_retirement.returncode == 0, accepted_retirement.stderr
        run("git", "add", "-A", cwd=repo)
        run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "retire", cwd=repo)
        stable_retirement = invoke(repo)
        assert stable_retirement.returncode == 0, stable_retirement.stderr

        write(repo, retired)
        invalid_ref = invoke(repo, "does-not-exist")
        assert invalid_ref.returncode != 0 and "invalid-diff-base" in invalid_ref.stderr, invalid_ref.stderr
        zero_ref = invoke(repo, "0" * 40)
        assert zero_ref.returncode == 0 and "all-zero SHA fallback" in zero_ref.stdout, zero_ref.stderr

        with tempfile.TemporaryDirectory(prefix="quality-baseline-policy-base-missing.") as missing_temporary:
            empty_base_repo = Path(missing_temporary)
            run("git", "init", "-q", cwd=empty_base_repo)
            (empty_base_repo / "README").write_text("fixture\n", encoding="utf-8")
            run("git", "add", "README", cwd=empty_base_repo)
            run("git", "-c", "user.name=gate", "-c", "user.email=gate@example.invalid", "commit", "-qm", "empty", cwd=empty_base_repo)
            write(empty_base_repo, v2())
            write_target(empty_base_repo, "Sources", "TargetA", present=True)
            missing = invoke(empty_base_repo)
            assert missing.returncode != 0 and "base-baseline-missing" in missing.stderr, missing.stderr

    source_file_line_limit_fixtures()
    print("quality baseline policy test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
