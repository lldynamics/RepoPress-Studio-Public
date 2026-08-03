#!/usr/bin/env python3
"""Run Swift tests with coverage and enforce a progressive Sources line baseline."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BASELINES = ROOT / "script" / "quality_baselines.json"


def fail(message: str) -> None:
    print(f"swift coverage gate: {message}", file=sys.stderr)
    raise SystemExit(1)


def source_line_coverage(payload: dict[str, object], root: Path) -> tuple[int, int, float]:
    data = payload.get("data")
    if not isinstance(data, list) or not data or not isinstance(data[0], dict):
        fail("coverage JSON does not contain LLVM coverage data")
    files = data[0].get("files")
    if not isinstance(files, list):
        fail("coverage JSON does not contain a files list")
    count = 0
    covered = 0
    source_root = (root / "Sources").resolve()
    for item in files:
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
            continue
        try:
            filename = Path(item["filename"]).resolve()
            filename.relative_to(source_root)
        except (OSError, ValueError):
            continue
        summary = item.get("summary")
        lines = summary.get("lines") if isinstance(summary, dict) else None
        if not isinstance(lines, dict):
            continue
        file_count = lines.get("count")
        file_covered = lines.get("covered")
        if isinstance(file_count, int) and isinstance(file_covered, int):
            count += file_count
            covered += file_covered
    if count == 0:
        fail("coverage JSON contains no executable lines under Sources")
    percent = round((covered / count) * 100, 2)
    return covered, count, percent


def run_coverage(root: Path, scratch_path: Path) -> Path:
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

    command = [
        swift,
        "test",
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
    print("swift coverage gate: running " + " ".join(command))
    try:
        subprocess.run(command, cwd=root, env=environment, check=True)
        path_result = subprocess.run(
            [
                swift,
                "test",
                "--disable-sandbox",
                "--show-codecov-path",
                "--scratch-path",
                str(scratch_path),
                "--cache-path",
                str(swift_build_root / "Library/Caches/org.swift.swiftpm"),
                "--config-path",
                str(swift_build_root / "Library/org.swift.swiftpm/configuration"),
                "--security-path",
                str(swift_build_root / "Library/org.swift.swiftpm/security"),
            ],
            cwd=root,
            env=environment,
            text=True,
            capture_output=True,
            check=True,
        )
    except FileNotFoundError:
        print(
            "swift coverage gate [environment:tool-unavailable]: swift was not found; "
            "no network install was attempted",
            file=sys.stderr,
        )
        raise SystemExit(69)
    except subprocess.CalledProcessError as error:
        fail(f"coverage command failed with status {error.returncode}")
    candidates = [Path(line.strip()) for line in path_result.stdout.splitlines() if line.strip()]
    if not candidates:
        fail("swift --show-codecov-path returned no path")
    return candidates[-1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINES)
    parser.add_argument(
        "--coverage-json",
        type=Path,
        help="validate an existing SwiftPM coverage JSON instead of running tests",
    )
    parser.add_argument("--result-json", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        baseline_payload = json.loads(args.baseline.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load quality baseline: {error}")
    minimum = baseline_payload.get("sourceLineCoveragePercentMinimum")
    if (
        baseline_payload.get("schemaVersion") != 1
        or not isinstance(minimum, (int, float))
        or isinstance(minimum, bool)
        or not 0 <= float(minimum) <= 100
    ):
        fail("quality baseline must contain sourceLineCoveragePercentMinimum from 0 through 100")

    coverage_path = (
        args.coverage_json.resolve()
        if args.coverage_json
        else run_coverage(
            root,
            Path(
                os.environ.get(
                    "SWIFT_COVERAGE_SCRATCH_PATH",
                    str(root / ".build" / "coverage"),
                )
            ),
        )
    )
    try:
        coverage_payload = json.loads(coverage_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load coverage JSON {coverage_path}: {error}")
    covered, count, percent = source_line_coverage(coverage_payload, root)
    result = {
        "schemaVersion": 1,
        "sourceLines": {
            "covered": covered,
            "count": count,
            "percent": percent,
            "minimumPercent": float(minimum),
        },
        "coverageJSON": str(coverage_path),
    }
    if args.result_json:
        args.result_json.parent.mkdir(parents=True, exist_ok=True)
        args.result_json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if percent + 1e-9 < float(minimum):
        fail(f"Sources line coverage {percent:.2f}% is below progressive baseline {float(minimum):.2f}%")
    print(
        f"swift coverage gate: passed ({covered}/{count} Sources lines, "
        f"{percent:.2f}%; progressive minimum {float(minimum):.2f}%)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
