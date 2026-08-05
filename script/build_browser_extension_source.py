#!/usr/bin/env python3
"""Materialize one browser extension from shared sources and a platform manifest."""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
EXTENSION_ROOT = ROOT / "BrowserExtension"
SHARED_ROOT = EXTENSION_ROOT / "shared"
PLATFORM_ROOTS = {
    "chrome": EXTENSION_ROOT / "Chrome",
    "firefox": EXTENSION_ROOT / "Firefox",
    "safari": EXTENSION_ROOT / "Safari",
}
SHARED_FILES = (
    "_locales/en/messages.json",
    "_locales/zh_CN/messages.json",
    "background-capture.js",
    "background-queue-operations.js",
    "background-queue-storage.js",
    "background-security.js",
    "background.js",
    "icons/icon16.png",
    "icons/icon32.png",
    "icons/icon48.png",
    "icons/icon128.png",
    "popup.css",
    "popup.html",
    "popup.js",
    "protocol.generated.js",
)


class SourceError(RuntimeError):
    pass


def source_path(browser: str, relative: str) -> Path:
    if relative == "manifest.json":
        return PLATFORM_ROOTS[browser] / relative
    return SHARED_ROOT / relative


def _regular_file(path: Path, label: str) -> None:
    if not path.is_file() or path.is_symlink():
        raise SourceError(f"{label} must be a regular file: {path}")


def validate_source(browser: str) -> None:
    if browser not in PLATFORM_ROOTS:
        raise SourceError(f"unsupported browser: {browser}")

    _regular_file(source_path(browser, "manifest.json"), f"{browser} manifest")
    for relative in SHARED_FILES:
        _regular_file(source_path(browser, relative), f"shared source {relative}")

    for platform, platform_root in PLATFORM_ROOTS.items():
        if not platform_root.is_dir() or platform_root.is_symlink():
            raise SourceError(f"platform source directory is missing: {platform_root}")
        entries = sorted(path.name for path in platform_root.iterdir())
        if entries != ["manifest.json"]:
            raise SourceError(
                f"{platform} source must contain only manifest.json; found {entries}"
            )


def build_source(browser: str, output_dir: Path) -> None:
    validate_source(browser)
    if output_dir.exists():
        if output_dir.is_symlink() or not output_dir.is_dir():
            raise SourceError(f"output must be a regular directory: {output_dir}")
        if any(output_dir.iterdir()):
            raise SourceError(f"output directory must be empty: {output_dir}")
    else:
        output_dir.mkdir(parents=True)

    for relative in SHARED_FILES + ("manifest.json",):
        destination = output_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path(browser, relative), destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", choices=tuple(PLATFORM_ROOTS), required=True)
    parser.add_argument("--check", action="store_true", help="validate source layout only")
    parser.add_argument("--output-dir", type=Path, help="empty directory for a materialized extension")
    args = parser.parse_args()

    if not args.check and args.output_dir is None:
        parser.error("--output-dir is required unless --check is used")
    try:
        validate_source(args.browser)
        if not args.check:
            build_source(args.browser, args.output_dir.resolve())
    except (OSError, SourceError) as error:
        print(f"browser extension source error: {error}", file=sys.stderr)
        return 1

    action = "validated" if args.check else "materialized"
    print(f"{args.browser} browser extension source: {action}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
