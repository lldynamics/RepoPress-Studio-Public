#!/usr/bin/env python3
"""Inventory and explicitly prune allow-listed, rebuildable local build outputs."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent

# These directories are reproducible outputs, not SwiftPM dependency caches or
# captured performance evidence. Keep the allow-list exact so a new directory
# is report-only until somebody deliberately classifies it.
REBUILDABLE_DIRECTORIES = (
    "coverage",
    "strict-concurrency",
    "swift-test-shards",
    "swift6-migration",
    "ui-smoke-derived-data",
)

PRESERVED_DIRECTORIES = {
    "arm64-apple-macosx": "active SwiftPM products and intermediates",
    "artifacts": "downloaded binary artifacts",
    "checkouts": "dependency source checkouts",
    "repositories": "SwiftPM repository cache",
    "benchmarks": "benchmark evidence",
    "performance-traces": "Instruments and signpost evidence",
    "release-performance": "release performance evidence",
    "release-performance-final": "release performance evidence",
    "release-performance-rerun": "release performance evidence",
}


class CachePolicyError(RuntimeError):
    pass


def directory_size(path: Path) -> int:
    total = 0
    for directory, _children, files in os.walk(path, followlinks=False):
        for filename in files:
            candidate = Path(directory, filename)
            try:
                if not candidate.is_symlink():
                    total += candidate.stat().st_size
            except OSError:
                continue
    return total


def checked_candidate(build_root: Path, name: str) -> Path:
    if name not in REBUILDABLE_DIRECTORIES:
        raise CachePolicyError(f"refusing non-allow-listed build output: {name}")
    candidate = build_root / name
    if candidate.is_symlink():
        raise CachePolicyError(f"refusing symlink build output: {candidate}")
    resolved = candidate.resolve(strict=False)
    if resolved.parent != build_root:
        raise CachePolicyError(f"refusing path outside the build root: {candidate}")
    return candidate


def inventory(build_root: Path) -> list[dict[str, object]]:
    if not build_root.exists():
        return []
    rows: list[dict[str, object]] = []
    for child in sorted(build_root.iterdir(), key=lambda item: item.name):
        if not child.is_dir() or child.is_symlink():
            continue
        if child.name in REBUILDABLE_DIRECTORIES:
            policy = "explicitly-prunable"
            note = "reproducible local output"
        else:
            policy = "preserve"
            note = PRESERVED_DIRECTORIES.get(child.name, "unclassified; preserve by default")
        rows.append(
            {
                "name": child.name,
                "path": str(child),
                "bytes": directory_size(child),
                "policy": policy,
                "note": note,
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--remove",
        action="append",
        default=[],
        choices=REBUILDABLE_DIRECTORIES,
        metavar="NAME",
        help="select one exact rebuildable directory; repeat for more than one",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform selected removals; omission is always a dry run",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    unresolved_build_root = root / ".build"
    if unresolved_build_root.is_symlink():
        print("build cache policy: refusing a symlink .build root", file=sys.stderr)
        return 2
    build_root = unresolved_build_root.resolve(strict=False)
    if build_root.parent != root:
        print("build cache policy: invalid .build root", file=sys.stderr)
        return 2
    if args.apply and not args.remove:
        print("build cache policy: --apply requires at least one --remove", file=sys.stderr)
        return 2

    try:
        selected = [checked_candidate(build_root, name) for name in dict.fromkeys(args.remove)]
        before = inventory(build_root)
        actions: list[dict[str, object]] = []
        for candidate in selected:
            candidate = checked_candidate(build_root, candidate.name)
            existed = candidate.exists()
            size = directory_size(candidate) if existed else 0
            if args.apply and existed:
                shutil.rmtree(candidate)
            actions.append(
                {
                    "name": candidate.name,
                    "path": str(candidate),
                    "bytes": size,
                    "existed": existed,
                    "removed": bool(args.apply and existed),
                }
            )
    except (CachePolicyError, OSError) as error:
        print(f"build cache policy: {error}", file=sys.stderr)
        return 1

    result = {
        "schemaVersion": 1,
        "root": str(root),
        "buildRoot": str(build_root),
        "dryRun": not args.apply,
        "inventory": before,
        "actions": actions,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
