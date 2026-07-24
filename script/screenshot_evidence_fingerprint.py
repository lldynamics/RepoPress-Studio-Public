#!/usr/bin/env python3
"""Compute a stable fingerprint for screenshot-visible product sources."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


SCRIPT_INPUTS = (
    "script/build_and_run.sh",
    "script/capture_app_screenshots.sh",
    "script/check_screenshot_surface_map.sh",
    "script/release_evidence_source_manifest.py",
    "script/screenshot_capture_provenance.py",
    "script/screenshot_evidence_fingerprint.py",
)


def add_file(digest: "hashlib._Hash", label: str, path: Path) -> None:
    add_bytes(digest, label, path.read_bytes())


def add_bytes(digest: "hashlib._Hash", label: str, data: bytes) -> None:
    digest.update(label.encode("utf-8"))
    digest.update(b"\0")
    digest.update(data)
    digest.update(b"\0")


def fingerprint(root: Path, manifest: Path) -> str:
    digest = hashlib.sha256()
    manifest_lines = []
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if line.startswith("| `"):
            columns = line.split("|")
            if len(columns) >= 7:
                columns[-2] = " <capture-status> "
                line = "|".join(columns)
        manifest_lines.append(line)
    add_bytes(
        digest,
        "docs/app-store-screenshots/SCREENSHOT_MANIFEST.md",
        ("\n".join(manifest_lines) + "\n").encode("utf-8"),
    )

    sources = root / "Sources"
    for path in sorted(item for item in sources.rglob("*") if item.is_file()):
        if path.name.startswith("._"):
            continue
        add_file(digest, path.relative_to(root).as_posix(), path)

    for relative_path in SCRIPT_INPUTS:
        add_file(digest, relative_path, root / relative_path)

    return f"sha256:{digest.hexdigest()}"


def main() -> int:
    parser = argparse.ArgumentParser()
    default_root = Path(__file__).resolve().parent.parent
    parser.add_argument("--root", type=Path, default=default_root)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help="Override the screenshot manifest path (used by fixture tests).",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = (
        args.manifest.resolve()
        if args.manifest is not None
        else root / "docs/app-store-screenshots/SCREENSHOT_MANIFEST.md"
    )
    print(fingerprint(root, manifest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
