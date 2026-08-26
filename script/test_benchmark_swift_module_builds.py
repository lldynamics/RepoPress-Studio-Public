#!/usr/bin/env python3
"""Regression tests for benchmark_swift_module_builds.py."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().with_name("benchmark_swift_module_builds.py")


def make_package(root: Path) -> Path:
    package = root / "package"
    source = package / "Sources" / "Leaf"
    second_source = package / "Sources" / "Other"
    source.mkdir(parents=True)
    second_source.mkdir(parents=True)
    (package / "Package.swift").write_text(
        """// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "Fixture",
  targets: [.target(name: "Leaf"), .target(name: "Other")]
)
""",
        encoding="utf-8",
    )
    (package / "Package.resolved").write_text(
        '{"pins": [], "version": 2}\n', encoding="utf-8"
    )
    (source / "Leaf.swift").write_text(
        "public struct Leaf: Sendable {}\n", encoding="utf-8"
    )
    (second_source / "Other.swift").write_text(
        "public struct Other: Sendable {}\n", encoding="utf-8"
    )
    return package


def make_fake_swift(root: Path) -> tuple[Path, Path]:
    executable = root / "fake-swift"
    invocation_log = root / "swift-invocations.jsonl"
    executable.write_text(
        """#!/usr/bin/env python3
import json
import os
import pathlib
import sys

log_path = pathlib.Path(os.environ["FAKE_SWIFT_INVOCATION_LOG"])
is_resolve = sys.argv[1:3] == ["package", "resolve"]
is_build = "build" in sys.argv[1:]
is_local_resolve = is_resolve and "--skip-update" in sys.argv[1:]
is_cache_prime = is_resolve and not is_local_resolve
with log_path.open("a", encoding="utf-8") as stream:
    stream.write(
        json.dumps(
            {
                "argv": sys.argv[1:],
                "cwd": os.getcwd(),
                "environment": {
                    key: os.environ.get(key)
                    for key in (
                        "HOME",
                        "XDG_CACHE_HOME",
                        "CLANG_MODULE_CACHE_PATH",
                        "SWIFT_MODULE_CACHE_PATH",
                    )
                },
            },
            sort_keys=True,
        )
        + "\\n"
    )
if sys.argv[1:] == ["--version"]:
    print("Apple Swift version 6.2 (fixture)")
    raise SystemExit(0)
if os.environ.get("FAKE_SWIFT_FAIL_PRIME") == "1" and is_cache_prime:
    print("fixture dependency cache prime failure")
    raise SystemExit(19)
if os.environ.get("FAKE_SWIFT_FAIL_LOCAL") == "1" and is_local_resolve:
    print("fixture local dependency resolve failure")
    raise SystemExit(23)
if os.environ.get("FAKE_SWIFT_FAIL_BUILD") == "1" and is_build:
    print("fixture build failure")
    raise SystemExit(9)
print("fixture Swift command passed")
""",
        encoding="utf-8",
    )
    executable.chmod(0o755)
    return executable, invocation_log


def option_value(argv: list[str], option: str) -> str:
    index = argv.index(option)
    return argv[index + 1]


class SwiftModuleBuildBenchmarkTests(unittest.TestCase):
    def run_script(
        self,
        package: Path,
        *arguments: str,
        targets: tuple[str, ...] = ("Leaf",),
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(SCRIPT),
            "--package-root",
            str(package),
        ]
        for target in targets:
            command.extend(("--target", target))
        command.extend(arguments)
        return subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )

    def test_plan_is_deterministic_and_does_not_invoke_swift(self) -> None:
        with tempfile.TemporaryDirectory(prefix="swift-build-plan-test-") as directory:
            root = Path(directory)
            package = make_package(root)
            first = self.run_script(
                package,
                "--swift-bin",
                str(root / "does-not-exist"),
                "--scenario",
                "cold",
                "--scenario",
                "warm",
                "--scenario",
                "incremental",
                "--repetitions",
                "2",
                "--plan",
            )
            second = self.run_script(
                package,
                "--swift-bin",
                str(root / "does-not-exist"),
                "--scenario",
                "cold",
                "--scenario",
                "warm",
                "--scenario",
                "incremental",
                "--repetitions",
                "2",
                "--plan",
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(first.stdout, second.stdout)
            payload = json.loads(first.stdout)
            self.assertEqual(payload["mode"], "plan")
            self.assertEqual(len(payload["entries"]), 6)
            self.assertFalse(payload["dependencyResolve"]["measured"])
            self.assertEqual(payload["dependencyResolve"]["phase"], "dependency-resolve-local")
            self.assertTrue(payload["dependencyResolve"]["skipUpdate"])
            cache_prime = payload["dependencyCachePrime"]
            self.assertEqual(cache_prime["count"], 1)
            self.assertFalse(cache_prime["measured"])
            self.assertFalse(cache_prime["skipUpdate"])
            self.assertNotIn("--skip-update", cache_prime["command"])
            self.assertEqual(payload["cachePolicy"]["home"], "inherit HOME unchanged")
            resolves = [
                item["resolveCommand"]
                for item in payload["entries"]
                if item["resolveCommand"] is not None
            ]
            self.assertEqual(
                len({option_value(command, "--cache-path") for command in resolves}), 1
            )
            self.assertTrue(all("--skip-update" in command for command in resolves))
            self.assertTrue(
                all(item["resolveMeasured"] is False for item in payload["entries"])
            )
            self.assertTrue(
                all(
                    item["steps"][0]["name"]
                    in {"dependency-resolve-local", "dependency-resolve-local-reused"}
                    and item["steps"][0]["measured"] is False
                    for item in payload["entries"]
                )
            )
            self.assertEqual(
                sum(item["resolveExecuted"] for item in payload["entries"]), 4
            )
            warm_entries = [
                item for item in payload["entries"] if item["scenario"] == "warm"
            ]
            self.assertTrue(all(item["resolveCommand"] is None for item in warm_entries))
            incremental = [
                item for item in payload["entries"] if item["scenario"] == "incremental"
            ]
            self.assertTrue(incremental)
            self.assertTrue(
                all(item["sourceMode"] == "temporary-copy" for item in incremental)
            )
            self.assertTrue(
                all("-driver-time-compilation" in item["command"] for item in incremental)
            )
            self.assertEqual(
                option_value(incremental[0]["command"], "--scratch-path"),
                option_value(incremental[0]["resolveCommand"], "--scratch-path"),
            )
            self.assertNotEqual(
                incremental[0]["cachePaths"]["compiler"],
                incremental[0]["cachePaths"]["resolveCompiler"],
            )
            self.assertNotEqual(
                cache_prime["compiler"], incremental[0]["cachePaths"]["compiler"]
            )

    def test_cold_warm_and_incremental_use_isolated_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="swift-build-run-test-") as directory:
            root = Path(directory)
            package = make_package(root)
            original_source = (package / "Sources" / "Leaf" / "Leaf.swift").read_bytes()
            fake_swift, invocation_log = make_fake_swift(root)
            output = root / "report.json"
            work_root = root / "work"
            environment = os.environ.copy()
            environment["FAKE_SWIFT_INVOCATION_LOG"] = str(invocation_log)
            environment["HOME"] = str(root / "fixture-home")
            result = self.run_script(
                package,
                "--swift-bin",
                str(fake_swift),
                "--scenario",
                "cold",
                "--scenario",
                "warm",
                "--scenario",
                "incremental",
                "--repetitions",
                "2",
                "--output",
                str(output),
                "--work-root",
                str(work_root),
                targets=("Leaf", "Other"),
                environment=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "passed")
            self.assertEqual(report["targets"], ["Leaf", "Other"])
            self.assertEqual(report["scenarios"], ["cold", "warm", "incremental"])
            measured = [item for item in report["samples"] if item["measured"]]
            self.assertEqual(
                [item["scenario"] for item in measured],
                ["cold", "warm", "incremental"] * 4,
            )
            self.assertEqual(
                [item["scenario"] for item in measured].count("incremental"), 4
            )
            self.assertTrue(
                all(
                    item["phase"] == "dependency-resolve-local"
                    and item["measured"] is False
                    for item in report["samples"]
                    if item["phase"] == "dependency-resolve-local"
                )
            )
            self.assertEqual(report["dependencyCachePrime"]["sampleCount"], 1)
            self.assertEqual(report["dependencyResolve"]["sampleCount"], 8)
            incremental = [item for item in measured if item["scenario"] == "incremental"]
            self.assertTrue(all(item["sourceMode"] == "temporary-copy" for item in incremental))
            self.assertEqual(
                sorted(item["probeSource"] for item in incremental),
                ["Sources/Leaf/Leaf.swift"] * 2 + ["Sources/Other/Other.swift"] * 2,
            )
            self.assertEqual(
                (package / "Sources" / "Leaf" / "Leaf.swift").read_bytes(), original_source
            )
            invocations = [
                json.loads(line)
                for line in invocation_log.read_text(encoding="utf-8").splitlines()
            ]
            build_invocations = [item for item in invocations if "build" in item["argv"]]
            resolve_invocations = [
                item for item in invocations if item["argv"][:2] == ["package", "resolve"]
            ]
            prime_invocations = [
                item for item in resolve_invocations if "--skip-update" not in item["argv"]
            ]
            local_resolve_invocations = [
                item for item in resolve_invocations if "--skip-update" in item["argv"]
            ]
            self.assertEqual(len(build_invocations), 16)
            self.assertEqual(len(prime_invocations), 1)
            self.assertEqual(len(local_resolve_invocations), 8)
            self.assertNotIn("--skip-update", prime_invocations[0]["argv"])
            self.assertTrue(
                all("--skip-update" in item["argv"] for item in local_resolve_invocations)
            )
            self.assertTrue(
                all("--scratch-path" in item["argv"] for item in build_invocations)
            )
            self.assertTrue(
                all("--cache-path" in item["argv"] for item in build_invocations)
            )
            all_swift_commands = build_invocations + resolve_invocations
            for option in ("--cache-path", "--config-path", "--security-path"):
                self.assertEqual(
                    len({option_value(item["argv"], option) for item in all_swift_commands}), 1
                )
            self.assertIn(
                "shared-dependency-state",
                option_value(build_invocations[0]["argv"], "--cache-path"),
            )
            self.assertEqual(
                {item["environment"]["HOME"] for item in all_swift_commands},
                {str(root / "fixture-home")},
            )
            for target, repetition in (
                ("Leaf", 1),
                ("Leaf", 2),
                ("Other", 1),
                ("Other", 2),
            ):
                rep_builds = [
                    item
                    for item in build_invocations
                    if f"/{target}/repetition-{repetition}/"
                    in option_value(item["argv"], "--scratch-path")
                ]
                self.assertEqual(len(rep_builds), 4)
                rep_scratch = [option_value(item["argv"], "--scratch-path") for item in rep_builds]
                self.assertEqual(rep_scratch[0], rep_scratch[1])
                self.assertEqual(rep_scratch[2], rep_scratch[3])
                self.assertNotEqual(rep_scratch[0], rep_scratch[2])
                rep_compiler = [
                    item["environment"]["SWIFT_MODULE_CACHE_PATH"] for item in rep_builds
                ]
                self.assertEqual(rep_compiler[0], rep_compiler[1])
                self.assertEqual(rep_compiler[2], rep_compiler[3])
                self.assertNotEqual(rep_compiler[0], rep_compiler[2])
                rep_resolves = [
                    item
                    for item in local_resolve_invocations
                    if f"/{target}/repetition-{repetition}/"
                    in option_value(item["argv"], "--scratch-path")
                ]
                self.assertEqual(len(rep_resolves), 2)
                self.assertLess(
                    invocations.index(rep_resolves[0]), invocations.index(rep_builds[0])
                )
                self.assertLess(
                    invocations.index(rep_resolves[1]), invocations.index(rep_builds[2])
                )
                resolve_compiler = [
                    item["environment"]["SWIFT_MODULE_CACHE_PATH"] for item in rep_resolves
                ]
                self.assertNotEqual(resolve_compiler[0], rep_compiler[0])
                self.assertNotEqual(resolve_compiler[1], rep_compiler[2])
                self.assertNotEqual(resolve_compiler[0], resolve_compiler[1])

    def test_failed_build_writes_report_and_returns_nonzero(self) -> None:
        with tempfile.TemporaryDirectory(prefix="swift-build-failure-test-") as directory:
            root = Path(directory)
            package = make_package(root)
            fake_swift, invocation_log = make_fake_swift(root)
            output = root / "failed.json"
            environment = os.environ.copy()
            environment.update(
                {
                    "FAKE_SWIFT_INVOCATION_LOG": str(invocation_log),
                    "FAKE_SWIFT_FAIL_BUILD": "1",
                }
            )
            result = self.run_script(
                package,
                "--swift-bin",
                str(fake_swift),
                "--scenario",
                "cold",
                "--output",
                str(output),
                environment=environment,
            )
            self.assertEqual(result.returncode, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "failed")
            failed = [item for item in report["samples"] if item["status"] == "failed"]
            self.assertEqual(len(failed), 1)
            self.assertEqual(failed[0]["returnCode"], 9)
            self.assertEqual(failed[0]["phase"], "build")

    def test_failed_dependency_cache_prime_writes_report_and_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="swift-prime-failure-test-") as directory:
            root = Path(directory)
            package = make_package(root)
            fake_swift, invocation_log = make_fake_swift(root)
            output = root / "prime-failed.json"
            environment = os.environ.copy()
            environment.update(
                {
                    "FAKE_SWIFT_INVOCATION_LOG": str(invocation_log),
                    "FAKE_SWIFT_FAIL_PRIME": "1",
                }
            )
            result = self.run_script(
                package,
                "--swift-bin",
                str(fake_swift),
                "--scenario",
                "cold",
                "--output",
                str(output),
                targets=("Leaf", "Other"),
                environment=environment,
            )
            self.assertEqual(result.returncode, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "failed")
            failed = [item for item in report["samples"] if item["status"] == "failed"]
            self.assertEqual(len(failed), 1)
            self.assertEqual(failed[0]["phase"], "dependency-cache-prime")
            self.assertEqual(failed[0]["returnCode"], 19)
            self.assertFalse(failed[0]["skipUpdate"])
            resolve_log = Path(failed[0]["logPath"])
            self.assertTrue(resolve_log.is_file())
            self.assertIn("fixture dependency cache prime failure", resolve_log.read_text(encoding="utf-8"))
            invocations = [
                json.loads(line)
                for line in invocation_log.read_text(encoding="utf-8").splitlines()
            ]
            resolve_invocations = [
                item for item in invocations if item["argv"][:2] == ["package", "resolve"]
            ]
            self.assertEqual(len(resolve_invocations), 1)
            self.assertNotIn("--skip-update", resolve_invocations[0]["argv"])
            self.assertFalse(any("build" in item["argv"] for item in invocations))

    def test_failed_dependency_local_resolve_writes_report_and_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="swift-local-resolve-failure-test-") as directory:
            root = Path(directory)
            package = make_package(root)
            fake_swift, invocation_log = make_fake_swift(root)
            output = root / "local-resolve-failed.json"
            environment = os.environ.copy()
            environment.update(
                {
                    "FAKE_SWIFT_INVOCATION_LOG": str(invocation_log),
                    "FAKE_SWIFT_FAIL_LOCAL": "1",
                }
            )
            result = self.run_script(
                package,
                "--swift-bin",
                str(fake_swift),
                "--scenario",
                "cold",
                "--output",
                str(output),
                targets=("Leaf", "Other"),
                environment=environment,
            )
            self.assertEqual(result.returncode, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["dependencyCachePrime"]["sampleCount"], 1)
            self.assertEqual(report["dependencyResolve"]["sampleCount"], 1)
            failed = [item for item in report["samples"] if item["status"] == "failed"]
            self.assertEqual(len(failed), 1)
            self.assertEqual(failed[0]["phase"], "dependency-resolve-local")
            self.assertEqual(failed[0]["returnCode"], 23)
            self.assertTrue(failed[0]["skipUpdate"])
            resolve_log = Path(failed[0]["logPath"])
            self.assertTrue(resolve_log.is_file())
            self.assertIn(
                "fixture local dependency resolve failure", resolve_log.read_text(encoding="utf-8")
            )
            invocations = [
                json.loads(line)
                for line in invocation_log.read_text(encoding="utf-8").splitlines()
            ]
            resolve_invocations = [
                item for item in invocations if item["argv"][:2] == ["package", "resolve"]
            ]
            self.assertEqual(len(resolve_invocations), 2)
            self.assertNotIn("--skip-update", resolve_invocations[0]["argv"])
            self.assertIn("--skip-update", resolve_invocations[1]["argv"])
            self.assertFalse(any("build" in item["argv"] for item in invocations))

    def test_work_root_inside_checkout_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="swift-build-path-test-") as directory:
            root = Path(directory)
            package = make_package(root)
            result = self.run_script(
                package,
                "--work-root",
                str(package / ".build" / "unsafe-work"),
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("outside the package checkout", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
