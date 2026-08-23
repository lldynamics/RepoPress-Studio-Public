#!/usr/bin/env python3
"""Verify tooling pull-request paths cover every browser release input."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def browser_release_sources(manifest_path: Path) -> list[str]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    matching = [check for check in manifest.get("checks", []) if check.get("id") == "browser-extension-release"]
    if len(matching) != 1:
        raise ValueError("release manifest must define exactly one browser-extension-release check")
    sources = matching[0].get("source")
    if not isinstance(sources, list) or not sources or not all(isinstance(item, str) for item in sources):
        raise ValueError("browser-extension-release source must be a non-empty string list")
    return sources


def pull_request_paths(workflow_path: Path) -> list[str]:
    lines = workflow_path.read_text(encoding="utf-8").splitlines()
    in_pull_request = False
    in_paths = False
    paths: list[str] = []
    for line in lines:
        stripped = line.strip()
        indentation = len(line) - len(line.lstrip(" "))
        if indentation == 2 and stripped == "pull_request:":
            in_pull_request = True
            in_paths = False
            continue
        if in_pull_request and indentation <= 2 and stripped:
            break
        if in_pull_request and indentation == 4 and stripped == "paths:":
            in_paths = True
            continue
        if in_paths and indentation <= 4 and stripped:
            break
        if in_paths and indentation >= 6 and stripped.startswith("- "):
            value = stripped[2:].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
                value = value[1:-1]
            if value:
                paths.append(value)
    if not paths:
        raise ValueError("tooling workflow must define non-empty pull_request.paths")
    return paths


def pattern_covers_source(pattern: str, source: str) -> bool:
    if pattern.endswith("/**"):
        prefix = pattern[:-3].rstrip("/")
        return source == prefix or source.startswith(f"{prefix}/")
    return pattern == source


def uncovered_sources(sources: list[str], patterns: list[str]) -> list[str]:
    return sorted(source for source in sources if not any(pattern_covers_source(pattern, source) for pattern in patterns))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / "script" / "release_checks.json")
    parser.add_argument("--workflow", type=Path, default=ROOT / ".github" / "workflows" / "tooling.yml")
    args = parser.parse_args()
    try:
        sources = browser_release_sources(args.manifest)
        paths = pull_request_paths(args.workflow)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"tooling workflow source paths: {error}", file=sys.stderr)
        return 1
    missing = uncovered_sources(sources, paths)
    if missing:
        for source in missing:
            print(f"tooling workflow source paths: uncovered browser release input: {source}", file=sys.stderr)
        return 1
    print(f"tooling workflow source paths: passed ({len(sources)} browser release inputs covered)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
