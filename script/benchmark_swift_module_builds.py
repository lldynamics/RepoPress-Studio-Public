#!/usr/bin/env python3
"""Measure SwiftPM target build topology without mutating the working tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


TOOL_VERSION = "1.2.0"
SCHEMA_VERSION = 1
DEFAULT_TARGETS = (
    "PublishingMarkdownCore",
    "PublishingGitCore",
    "PublishingAICore",
    "PublishingKnowledgeCore",
    "PublishingWorkbenchCore",
)
DEFAULT_SCENARIOS = ("cold", "warm")
VALID_SCENARIOS = frozenset(("cold", "warm", "incremental"))
COPY_EXCLUSIONS = frozenset(
    (
        ".build",
        ".git",
        ".DerivedData",
        ".DerivedDataCodex",
        "node_modules",
        "output",
    )
)


class BenchmarkError(ValueError):
    """A caller-visible benchmark configuration or execution error."""


def positive_integer(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_swift_sources(source_root: Path) -> str:
    digest = hashlib.sha256()
    paths = sorted(path for path in source_root.rglob("*.swift") if path.is_file())
    for path in paths:
        relative = path.relative_to(source_root).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def checked_output(arguments: Sequence[str], *, cwd: Path) -> str | None:
    try:
        result = subprocess.run(
            list(arguments),
            cwd=cwd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def provenance(package_root: Path, swift_bin: str, targets: Sequence[str]) -> dict[str, Any]:
    git_commit = checked_output(("git", "rev-parse", "HEAD"), cwd=package_root)
    git_status = checked_output(("git", "status", "--porcelain"), cwd=package_root)
    swift_version = checked_output((swift_bin, "--version"), cwd=package_root)
    return {
        "gitCommit": git_commit or "unknown",
        "gitDirty": bool(git_status),
        "packageManifestSHA256": sha256_file(package_root / "Package.swift"),
        "packageResolvedSHA256": sha256_file(package_root / "Package.resolved"),
        "targetSourceSHA256": {
            target: sha256_swift_sources(package_root / "Sources" / target)
            for target in targets
        },
        "toolchain": (swift_version or "unavailable").splitlines()[0],
        "host": {
            "architecture": platform.machine() or "unknown",
            "machine": platform.node() or "unknown",
            "operatingSystem": platform.platform() or "unknown",
            "processor": platform.processor() or "unknown",
        },
    }


def validate_package(package_root: Path, targets: Sequence[str]) -> None:
    if not (package_root / "Package.swift").is_file():
        raise BenchmarkError(f"package root has no Package.swift: {package_root}")
    if len(targets) != len(set(targets)):
        raise BenchmarkError("target names must be unique")
    for target in targets:
        if not target or target.startswith("-") or "/" in target or "\\" in target:
            raise BenchmarkError(f"invalid target name: {target!r}")
        source_directory = package_root / "Sources" / target
        if not source_directory.is_dir():
            raise BenchmarkError(f"target source directory is missing: {source_directory}")
        if not any(source_directory.rglob("*.swift")):
            raise BenchmarkError(f"target has no Swift sources: {target}")


def validate_work_root(package_root: Path, work_root: Path) -> None:
    resolved_package = package_root.resolve()
    resolved_work = work_root.resolve()
    if resolved_work == Path(resolved_work.anchor):
        raise BenchmarkError("work root must not be a filesystem root")
    if resolved_work == resolved_package or resolved_work in resolved_package.parents:
        raise BenchmarkError("work root must not be the package root or one of its parents")
    if resolved_package in resolved_work.parents:
        raise BenchmarkError("work root must be outside the package checkout")


def shared_dependency_paths(run_root: Path) -> dict[str, Path]:
    """Return the one dependency-resolution state shared by a benchmark run."""

    root = run_root / "shared-dependency-state"
    return {
        "cache": root / "package-cache",
        "config": root / "configuration",
        "security": root / "security",
    }


def compiler_cache_paths(cache_root: Path) -> dict[str, Path]:
    return {
        "xdg": cache_root / "xdg-cache",
        "clang": cache_root / "clang-module-cache",
        "swift": cache_root / "swift-module-cache",
    }


def isolated_environment(compiler_cache_root: Path) -> dict[str, str]:
    """Copy the caller environment without changing HOME.

    Compiler/module caches are deliberately scoped to one target/repetition
    (and, for incremental, to its own scenario). SwiftPM's dependency state is
    passed explicitly through ``--cache-path``/``--config-path``/
    ``--security-path`` and is shared separately for the whole run.
    """

    environment = os.environ.copy()
    paths = compiler_cache_paths(compiler_cache_root)
    environment.update(
        {
            "XDG_CACHE_HOME": str(paths["xdg"]),
            "CLANG_MODULE_CACHE_PATH": str(paths["clang"]),
            "SWIFT_MODULE_CACHE_PATH": str(paths["swift"]),
        }
    )
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return environment


def dependency_path_arguments(dependency_paths: dict[str, Path]) -> list[str]:
    return [
        "--cache-path",
        str(dependency_paths["cache"]),
        "--config-path",
        str(dependency_paths["config"]),
        "--security-path",
        str(dependency_paths["security"]),
    ]


def build_command(
    *,
    swift_bin: str,
    package_root: Path,
    target: str,
    configuration: str,
    scratch_root: Path,
    compiler_timing: bool,
    dependency_paths: dict[str, Path] | None = None,
) -> list[str]:
    dependency_paths = dependency_paths or shared_dependency_paths(scratch_root.parent)
    command = [
        swift_bin,
        "build",
        "--package-path",
        str(package_root),
        "--configuration",
        configuration,
        "--disable-sandbox",
        "--scratch-path",
        str(scratch_root / "swiftpm"),
        *dependency_path_arguments(dependency_paths),
        "--target",
        target,
    ]
    if compiler_timing:
        command.extend(("-Xswiftc", "-driver-time-compilation"))
    return command


def resolve_command(
    *,
    swift_bin: str,
    package_root: Path,
    scratch_root: Path,
    dependency_paths: dict[str, Path],
    skip_update: bool = False,
) -> list[str]:
    command = [
        swift_bin,
        "package",
        "resolve",
        "--package-path",
        str(package_root),
        "--disable-sandbox",
        "--scratch-path",
        str(scratch_root / "swiftpm"),
        *dependency_path_arguments(dependency_paths),
    ]
    if skip_update:
        command.append("--skip-update")
    return command


def plan_payload(
    *,
    package_root: Path,
    targets: Sequence[str],
    scenarios: Sequence[str],
    repetitions: int,
    configuration: str,
    swift_bin: str,
    compiler_timing: bool,
) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    placeholder = Path("<isolated-work-root>")
    dependency_paths = shared_dependency_paths(placeholder)
    prime_root = placeholder / "dependency-cache-prime"
    prime_scratch = prime_root / "scratch"
    prime_compiler_cache = prime_root / "compiler-caches"
    prime_command = resolve_command(
        swift_bin=swift_bin,
        package_root=package_root,
        scratch_root=prime_scratch,
        dependency_paths=dependency_paths,
        skip_update=False,
    )
    ordered_scenarios = tuple(
        scenario for scenario in ("cold", "warm", "incremental") if scenario in scenarios
    )
    shared_resolve_scenario = (
        "cold" if "cold" in scenarios else "warm" if "warm" in scenarios else None
    )
    for target in targets:
        for repetition in range(1, repetitions + 1):
            target_root = placeholder / target / f"repetition-{repetition}"
            shared_scratch = target_root / "shared"
            shared_resolve_compiler_cache = target_root / "resolve-caches"
            shared_compiler_cache = target_root / "compiler-caches"
            for scenario in ordered_scenarios:
                source_root = (
                    target_root / "source-snapshot"
                    if scenario == "incremental"
                    else package_root
                )
                scratch = (
                    target_root / "incremental"
                    if scenario == "incremental"
                    else shared_scratch
                )
                resolve_compiler_cache = (
                    target_root / "incremental-resolve-caches"
                    if scenario == "incremental"
                    else shared_resolve_compiler_cache
                )
                compiler_cache = (
                    target_root / "incremental" / "compiler-caches"
                    if scenario == "incremental"
                    else shared_compiler_cache
                )
                resolve = resolve_command(
                    swift_bin=swift_bin,
                    package_root=source_root,
                    scratch_root=scratch,
                    dependency_paths=dependency_paths,
                    skip_update=True,
                )
                build = build_command(
                    swift_bin=swift_bin,
                    package_root=source_root,
                    target=target,
                    configuration=configuration,
                    scratch_root=scratch,
                    compiler_timing=compiler_timing,
                    dependency_paths=dependency_paths,
                )
                compiler_paths = compiler_cache_paths(compiler_cache)
                resolve_compiler_paths = compiler_cache_paths(resolve_compiler_cache)
                resolve_executed = scenario == "incremental" or scenario == shared_resolve_scenario
                cache_policy = (
                    "independent temporary source, scratch, and compiler caches; "
                    "resolve and unmeasured prime precede the measured edit build"
                    if scenario == "incremental"
                    else (
                        "cold/warm share this target/repetition scratch and compiler caches; "
                        "cold is fresh per target/repetition"
                    )
                )
                entries.append(
                    {
                        "target": target,
                        "scenario": scenario,
                        "repetition": repetition,
                        "sourceMode": "temporary-copy" if scenario == "incremental" else "read-only-worktree",
                        "command": build,
                        "resolveCommand": resolve if resolve_executed else None,
                        "resolveExecuted": resolve_executed,
                        "resolveMeasured": False,
                        "cachePolicy": cache_policy,
                        "cachePaths": {
                            "dependency": {
                                key: str(path) for key, path in dependency_paths.items()
                            },
                            "compiler": {
                                key: str(path) for key, path in compiler_paths.items()
                            },
                            "resolveCompiler": {
                                key: str(path) for key, path in resolve_compiler_paths.items()
                            },
                        },
                        "steps": [
                            {
                                "name": (
                                    "dependency-resolve-local"
                                    if resolve_executed
                                    else "dependency-resolve-local-reused"
                                ),
                                "measured": False,
                                "command": resolve if resolve_executed else None,
                            },
                            {
                                "name": "build",
                                "measured": True,
                                "command": build,
                            },
                        ],
                    }
                )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "tool": {"name": "benchmark_swift_module_builds.py", "version": TOOL_VERSION},
        "mode": "plan",
        "configuration": configuration,
        "targets": list(targets),
        "scenarios": list(scenarios),
        "repetitions": repetitions,
        "compilerTiming": compiler_timing,
        "cachePolicy": {
            "dependency": "one isolated SwiftPM package/repository cache, config, and security path shared for the whole run",
            "dependencyCachePrime": "one unmeasured run-scoped resolve before target work; may access the network",
            "dependencyResolveLocal": "one unmeasured resolve per scratch with --skip-update; local-only after cache prime",
            "cold": "fresh target/repetition scratch plus XDG, Clang, and Swift module caches",
            "warm": "reuses the matching cold scratch and compiler caches",
            "incremental": "independent temporary source copy, scratch, and compiler caches; resolve and prime are unmeasured",
            "resolveCompiler": "separate unmeasured XDG, Clang, and Swift module caches; never warms the measured build caches",
            "home": "inherit HOME unchanged",
        },
        "dependencyCachePrime": {
            "measured": False,
            "count": 1,
            "skipUpdate": False,
            "command": prime_command,
            "scratch": str(prime_scratch),
            "compiler": {
                key: str(path) for key, path in compiler_cache_paths(prime_compiler_cache).items()
            },
            "sharedPaths": {key: str(path) for key, path in dependency_paths.items()},
        },
        "dependencyResolve": {
            "measured": False,
            "commandIsIncludedPerEntry": True,
            "phase": "dependency-resolve-local",
            "skipUpdate": True,
            "sharedResolvePerTargetRepetition": True,
            "incrementalResolvePerTargetRepetition": True,
            "sharedPaths": {key: str(path) for key, path in dependency_paths.items()},
        },
        "entries": entries,
    }


def copy_package_snapshot(package_root: Path, destination: Path) -> None:
    def ignore(directory: str, names: list[str]) -> set[str]:
        ignored = {name for name in names if name in COPY_EXCLUSIONS}
        ignored.update(name for name in names if name.startswith(".DerivedData"))
        return ignored

    shutil.copytree(package_root, destination, symlinks=True, ignore=ignore)


def incremental_probe(source_root: Path, target: str, marker: str) -> Path:
    candidates = sorted((source_root / "Sources" / target).rglob("*.swift"))
    if not candidates:
        raise BenchmarkError(f"no Swift source available for incremental probe: {target}")
    probe = candidates[0]
    with probe.open("a", encoding="utf-8") as stream:
        stream.write(f"\n// isolated swift-module-build benchmark probe: {marker}\n")
    return probe


def run_build(
    *,
    command: Sequence[str],
    cwd: Path,
    environment: dict[str, str],
    log_path: Path,
) -> tuple[int, float]:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    try:
        result = subprocess.run(
            list(command),
            cwd=cwd,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        return_code = result.returncode
        output = result.stdout
    except OSError as error:
        return_code = 127
        output = f"cannot execute Swift build: {error}\n"
    duration = time.monotonic() - started
    log_path.write_text(output, encoding="utf-8")
    return return_code, duration


def sample(
    *,
    scenario: str,
    target: str,
    repetition: int,
    command: Sequence[str],
    cwd: Path,
    environment: dict[str, str],
    log_path: Path,
    source_mode: str,
    measured: bool,
    probe_path: Path | None = None,
    phase: str = "build",
    cache_policy: str | None = None,
    skip_update: bool | None = None,
) -> dict[str, Any]:
    return_code, duration = run_build(
        command=command,
        cwd=cwd,
        environment=environment,
        log_path=log_path,
    )
    payload: dict[str, Any] = {
        "target": target,
        "scenario": scenario,
        "repetition": repetition,
        "phase": phase,
        "measured": measured,
        "status": "passed" if return_code == 0 else "failed",
        "returnCode": return_code,
        "durationSeconds": round(duration, 6),
        "sourceMode": source_mode,
        "command": list(command),
        "logPath": str(log_path),
    }
    if cache_policy is not None:
        payload["cachePolicy"] = cache_policy
    if skip_update is not None:
        payload["skipUpdate"] = skip_update
    if probe_path is not None:
        payload["probeSource"] = str(probe_path.relative_to(cwd))
    return payload


def summaries(samples: Sequence[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[tuple[str, str], list[float]] = {}
    for item in samples:
        if item.get("measured") is not True or item.get("status") != "passed":
            continue
        key = (str(item["target"]), str(item["scenario"]))
        grouped.setdefault(key, []).append(float(item["durationSeconds"]))
    output: dict[str, dict[str, Any]] = {}
    for (target, scenario), durations in sorted(grouped.items()):
        output.setdefault(target, {})[scenario] = {
            "sampleCount": len(durations),
            "minimumSeconds": min(durations),
            "medianSeconds": statistics.median(durations),
            "maximumSeconds": max(durations),
            "rawSamplesSeconds": durations,
        }
    return output


def execute_benchmark(
    *,
    package_root: Path,
    output_path: Path,
    run_root: Path,
    targets: Sequence[str],
    scenarios: Sequence[str],
    repetitions: int,
    configuration: str,
    swift_bin: str,
    compiler_timing: bool,
) -> int:
    dependency_paths = shared_dependency_paths(run_root)
    samples: list[dict[str, Any]] = []
    status = "passed"
    cache_policy = {
        "dependency": "one isolated SwiftPM package/repository cache, config, and security path shared for the whole run",
        "dependencyCachePrime": "one unmeasured run-scoped resolve before target work; may access the network",
        "dependencyResolveLocal": "one unmeasured resolve per scratch with --skip-update; local-only after cache prime",
        "cold": "fresh target/repetition scratch plus XDG, Clang, and Swift module caches",
        "warm": "reuses the matching cold scratch and compiler caches",
        "incremental": "independent temporary source copy, scratch, and compiler caches; resolve and prime are unmeasured",
        "resolveCompiler": "separate unmeasured XDG, Clang, and Swift module caches; never warms the measured build caches",
        "home": "inherit HOME unchanged",
    }
    log_root = (
        output_path.parent
        / f"{output_path.stem}-logs"
        / (
            datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            + f"-{uuid.uuid4().hex[:8]}"
        )
    )

    prime_root = run_root / "dependency-cache-prime"
    prime_scratch = prime_root / "scratch"
    prime_compiler_cache = prime_root / "compiler-caches"
    prime_environment = isolated_environment(prime_compiler_cache)
    prime_command = resolve_command(
        swift_bin=swift_bin,
        package_root=package_root,
        scratch_root=prime_scratch,
        dependency_paths=dependency_paths,
        skip_update=False,
    )
    prime = sample(
        scenario="dependency-cache-prime",
        target="__all__",
        repetition=0,
        command=prime_command,
        cwd=package_root,
        environment=prime_environment,
        log_path=log_root / "dependency-cache-prime.log",
        source_mode="read-only-worktree",
        measured=False,
        phase="dependency-cache-prime",
        cache_policy=cache_policy["dependencyCachePrime"],
        skip_update=False,
    )
    samples.append(prime)
    if prime["status"] != "passed":
        status = "failed"

    for target in targets:
        if status == "failed":
            break
        for repetition in range(1, repetitions + 1):
            target_root = run_root / target / f"repetition-{repetition}"
            shared_scratch = target_root / "shared"
            shared_resolve_compiler_cache = target_root / "resolve-caches"
            shared_compiler_cache = target_root / "compiler-caches"
            shared_resolve_environment = isolated_environment(shared_resolve_compiler_cache)
            shared_environment = isolated_environment(shared_compiler_cache)
            shared_resolve_command = resolve_command(
                swift_bin=swift_bin,
                package_root=package_root,
                scratch_root=shared_scratch,
                dependency_paths=dependency_paths,
                skip_update=True,
            )
            common_command = build_command(
                swift_bin=swift_bin,
                package_root=package_root,
                target=target,
                configuration=configuration,
                scratch_root=shared_scratch,
                compiler_timing=compiler_timing,
                dependency_paths=dependency_paths,
            )
            cold_passed = False
            if "cold" in scenarios or "warm" in scenarios:
                resolve_scenario = "cold" if "cold" in scenarios else "warm"
                resolved = sample(
                    scenario=resolve_scenario,
                    target=target,
                    repetition=repetition,
                    command=shared_resolve_command,
                    cwd=package_root,
                    environment=shared_resolve_environment,
                    log_path=log_root
                    / target
                    / f"repetition-{repetition}"
                    / "dependency-resolve-local.log",
                    source_mode="read-only-worktree",
                    measured=False,
                    phase="dependency-resolve-local",
                    cache_policy=cache_policy["dependencyResolveLocal"],
                    skip_update=True,
                )
                samples.append(resolved)
                if resolved["status"] != "passed":
                    status = "failed"
                    break
            if "cold" in scenarios:
                cold = sample(
                    scenario="cold",
                    target=target,
                    repetition=repetition,
                    command=common_command,
                    cwd=package_root,
                    environment=shared_environment,
                    log_path=log_root / target / f"repetition-{repetition}" / "cold.log",
                    source_mode="read-only-worktree",
                    measured=True,
                    cache_policy=cache_policy["cold"],
                )
                samples.append(cold)
                cold_passed = cold["status"] == "passed"
                if not cold_passed:
                    status = "failed"
                    break
            if "warm" in scenarios:
                if not cold_passed:
                    prime = sample(
                        scenario="warm-prime",
                        target=target,
                        repetition=repetition,
                        command=common_command,
                        cwd=package_root,
                        environment=shared_environment,
                        log_path=log_root
                        / target
                        / f"repetition-{repetition}"
                        / "warm-prime.log",
                        source_mode="read-only-worktree",
                        measured=False,
                        phase="prime",
                        cache_policy=cache_policy["warm"],
                    )
                    samples.append(prime)
                    if prime["status"] != "passed":
                        status = "failed"
                        break
                warm = sample(
                    scenario="warm",
                    target=target,
                    repetition=repetition,
                    command=common_command,
                    cwd=package_root,
                    environment=shared_environment,
                    log_path=log_root / target / f"repetition-{repetition}" / "warm.log",
                    source_mode="read-only-worktree",
                    measured=True,
                    cache_policy=cache_policy["warm"],
                )
                samples.append(warm)
                if warm["status"] != "passed":
                    status = "failed"
                    break
            if "incremental" in scenarios:
                snapshot_root = target_root / "source-snapshot"
                copy_package_snapshot(package_root, snapshot_root)
                incremental_scratch = target_root / "incremental"
                incremental_resolve_compiler_cache = target_root / "incremental-resolve-caches"
                incremental_compiler_cache = incremental_scratch / "compiler-caches"
                incremental_resolve_environment = isolated_environment(
                    incremental_resolve_compiler_cache
                )
                incremental_environment = isolated_environment(incremental_compiler_cache)
                incremental_resolve_command = resolve_command(
                    swift_bin=swift_bin,
                    package_root=snapshot_root,
                    scratch_root=incremental_scratch,
                    dependency_paths=dependency_paths,
                    skip_update=True,
                )
                resolved = sample(
                    scenario="incremental",
                    target=target,
                    repetition=repetition,
                    command=incremental_resolve_command,
                    cwd=snapshot_root,
                    environment=incremental_resolve_environment,
                    log_path=log_root
                    / target
                    / f"repetition-{repetition}"
                    / "incremental-dependency-resolve-local.log",
                    source_mode="temporary-copy",
                    measured=False,
                    phase="dependency-resolve-local",
                    cache_policy=cache_policy["dependencyResolveLocal"],
                    skip_update=True,
                )
                samples.append(resolved)
                if resolved["status"] != "passed":
                    status = "failed"
                    break
                incremental_command = build_command(
                    swift_bin=swift_bin,
                    package_root=snapshot_root,
                    target=target,
                    configuration=configuration,
                    scratch_root=incremental_scratch,
                    compiler_timing=compiler_timing,
                    dependency_paths=dependency_paths,
                )
                prime = sample(
                    scenario="incremental-prime",
                    target=target,
                    repetition=repetition,
                    command=incremental_command,
                    cwd=snapshot_root,
                    environment=incremental_environment,
                    log_path=log_root
                    / target
                    / f"repetition-{repetition}"
                    / "incremental-prime.log",
                    source_mode="temporary-copy",
                    measured=False,
                    phase="prime",
                    cache_policy=cache_policy["incremental"],
                )
                samples.append(prime)
                if prime["status"] != "passed":
                    status = "failed"
                    break
                probe = incremental_probe(snapshot_root, target, uuid.uuid4().hex)
                incremental = sample(
                    scenario="incremental",
                    target=target,
                    repetition=repetition,
                    command=incremental_command,
                    cwd=snapshot_root,
                    environment=incremental_environment,
                    log_path=log_root
                    / target
                    / f"repetition-{repetition}"
                    / "incremental.log",
                    source_mode="temporary-copy",
                    measured=True,
                    probe_path=probe,
                    cache_policy=cache_policy["incremental"],
                )
                samples.append(incremental)
                if incremental["status"] != "passed":
                    status = "failed"
                    break
        if status == "failed":
            break

    report = {
        "schemaVersion": SCHEMA_VERSION,
        "benchmark": "swift-module-builds",
        "tool": {"name": "benchmark_swift_module_builds.py", "version": TOOL_VERSION},
        "status": status,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "configuration": configuration,
        "targets": list(targets),
        "scenarios": list(scenarios),
        "repetitions": repetitions,
        "compilerTiming": compiler_timing,
        "cachePolicy": cache_policy,
        "cacheLayout": {
            "dependency": {
                key: str(path) for key, path in dependency_paths.items()
            },
            "dependencyCachePrime": {
                "scratch": str(prime_scratch),
                "compiler": {
                    key: str(path)
                    for key, path in compiler_cache_paths(prime_compiler_cache).items()
                },
            },
            "compiler": "per target/repetition; incremental has a separate compiler-cache directory",
            "scratch": "per target/repetition; cold and warm share one directory, incremental has a separate directory",
        },
        "dependencyCachePrime": {
            "measured": False,
            "failureIsFatal": True,
            "count": 1,
            "skipUpdate": False,
            "sampleCount": sum(
                1 for item in samples if item.get("phase") == "dependency-cache-prime"
            ),
            "command": prime_command,
            "scratch": str(prime_scratch),
            "compiler": {
                key: str(path)
                for key, path in compiler_cache_paths(prime_compiler_cache).items()
            },
        },
        "dependencyResolve": {
            "measured": False,
            "failureIsFatal": True,
            "phase": "dependency-resolve-local",
            "skipUpdate": True,
            "sampleCount": sum(
                1 for item in samples if item.get("phase") == "dependency-resolve-local"
            ),
        },
        "provenance": provenance(package_root, swift_bin, targets),
        "samples": samples,
        "summary": summaries(samples),
    }
    atomic_write_json(output_path, report)
    return 0 if status == "passed" else 1


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--package-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="JSON report path (default: .build/benchmarks/swift-module-builds.json)",
    )
    parser.add_argument(
        "--work-root",
        type=Path,
        help="isolated work directory outside the checkout (default: a temporary directory)",
    )
    parser.add_argument("--target", action="append", dest="targets", help="target to measure; repeatable")
    parser.add_argument(
        "--scenario",
        action="append",
        choices=sorted(VALID_SCENARIOS),
        dest="scenarios",
        help="scenario to measure; repeatable (default: cold and warm)",
    )
    parser.add_argument("--repetitions", type=positive_integer, default=1)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--swift-bin", default=os.environ.get("SWIFT_BIN", "swift"))
    parser.add_argument("--no-compiler-timing", action="store_true")
    parser.add_argument("--plan", action="store_true", help="print the build plan without running Swift")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    package_root = arguments.package_root.resolve()
    targets = tuple(arguments.targets or DEFAULT_TARGETS)
    scenarios = tuple(arguments.scenarios or DEFAULT_SCENARIOS)
    compiler_timing = not arguments.no_compiler_timing
    try:
        validate_package(package_root, targets)
        if len(scenarios) != len(set(scenarios)):
            raise BenchmarkError("scenarios must be unique")
        if arguments.plan:
            print(
                json.dumps(
                    plan_payload(
                        package_root=package_root,
                        targets=targets,
                        scenarios=scenarios,
                        repetitions=arguments.repetitions,
                        configuration=arguments.configuration,
                        swift_bin=arguments.swift_bin,
                        compiler_timing=compiler_timing,
                    ),
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
            )
            return 0

        output_path = arguments.output or (
            package_root / ".build" / "benchmarks" / "swift-module-builds.json"
        )
        if not output_path.is_absolute():
            output_path = package_root / output_path
        if arguments.work_root is not None:
            work_root = arguments.work_root.resolve()
            validate_work_root(package_root, work_root)
            run_root = work_root / f"swift-module-builds-{uuid.uuid4().hex}"
            run_root.mkdir(parents=True)
            return execute_benchmark(
                package_root=package_root,
                output_path=output_path,
                run_root=run_root,
                targets=targets,
                scenarios=scenarios,
                repetitions=arguments.repetitions,
                configuration=arguments.configuration,
                swift_bin=arguments.swift_bin,
                compiler_timing=compiler_timing,
            )

        with tempfile.TemporaryDirectory(prefix="swift-module-builds-") as directory:
            return execute_benchmark(
                package_root=package_root,
                output_path=output_path,
                run_root=Path(directory),
                targets=targets,
                scenarios=scenarios,
                repetitions=arguments.repetitions,
                configuration=arguments.configuration,
                swift_bin=arguments.swift_bin,
                compiler_timing=compiler_timing,
            )
    except BenchmarkError as error:
        print(f"swift module build benchmark: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
