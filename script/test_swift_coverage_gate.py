#!/usr/bin/env python3
"""Regression tests for check_swift_coverage.py report validation."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "script" / "check_swift_coverage.py"


def main() -> int:
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
