#!/usr/bin/env python3
"""Create and validate the Release app artifact hand-off manifest."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

APP_NAME = "PersonalSitePublisherMac"
BUNDLE_NAME = "RepoPress Studio.app"
BUNDLE_ID = "com.jinfang.PersonalSitePublisherMac"
BUILD_INPUTS = (
    "Package.swift",
    "Package.resolved",
    "Sources",
    "Packaging",
    "script/build_and_run.sh",
)


def digest_paths(root: Path, paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda item: str(item.relative_to(root))):
        relative = str(path.relative_to(root))
        mode = path.lstat().st_mode & 0o777
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update(f"{mode:o}".encode())
        digest.update(b"\0")
        if path.is_symlink():
            digest.update(b"symlink\0")
            digest.update(os.readlink(path).encode())
            continue
        digest.update(b"file\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def files_under(root: Path) -> list[Path]:
    return [path for path in root.rglob("*") if path.is_file() or path.is_symlink()]


def digest_tree(root: Path) -> str:
    return digest_paths(root, files_under(root))


def build_input_digest(root: Path) -> str:
    files: list[Path] = []
    for relative in BUILD_INPUTS:
        path = root / relative
        if not path.exists() and not path.is_symlink():
            raise SystemExit(f"release artifact manifest: build input is missing: {relative}")
        if path.is_dir() and not path.is_symlink():
            files.extend(files_under(path))
        else:
            files.append(path)
    if not files:
        raise SystemExit("release artifact manifest: build input set is empty")
    return digest_paths(root, files)


def commit(root: Path) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"release artifact manifest: cannot resolve current commit: {error}")


def make(root: Path, bundle: Path, output: Path) -> None:
    info = bundle / "Contents" / "Info.plist"
    binary = bundle / "Contents" / "MacOS" / APP_NAME
    if not bundle.is_dir() or not binary.is_file() or not info.is_file():
        raise SystemExit("release artifact manifest: Release app bundle is incomplete")
    # PlistBuddy is intentionally kept in the shell gates; this manifest binds
    # the immutable path and content, while the shell gate checks plist fields.
    payload = {
        "schemaVersion": 1,
        "configuration": "Release",
        "bundle": str(bundle),
        "bundleName": BUNDLE_NAME,
        "bundleIdentifier": BUNDLE_ID,
        "executable": str(binary),
        "executableName": APP_NAME,
        "commit": commit(root),
        "buildInputSHA256": build_input_digest(root),
        "contentSHA256": digest_tree(bundle),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print(f"release artifact manifest: wrote {output}")


def validate(root: Path, manifest: Path) -> None:
    try:
        data = json.loads(manifest.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"release artifact manifest: invalid or missing manifest: {error}")
    required = {
        "schemaVersion",
        "configuration",
        "bundle",
        "bundleName",
        "bundleIdentifier",
        "executable",
        "executableName",
        "commit",
        "buildInputSHA256",
        "contentSHA256",
    }
    if set(data) != required or data["schemaVersion"] != 1:
        raise SystemExit("release artifact manifest: schema or fields are invalid")
    bundle = Path(data["bundle"])
    expected_bundle = root / "dist" / BUNDLE_NAME
    if bundle != expected_bundle or data["bundleName"] != BUNDLE_NAME:
        raise SystemExit("release artifact manifest: bundle path drifted")
    if data["configuration"] != "Release" or data["bundleIdentifier"] != BUNDLE_ID or data["executableName"] != APP_NAME:
        raise SystemExit("release artifact manifest: Release identity drifted")
    executable = bundle / "Contents" / "MacOS" / APP_NAME
    if Path(data["executable"]) != executable or not executable.is_file():
        raise SystemExit("release artifact manifest: executable is missing or drifted")
    if data["commit"] != commit(root):
        raise SystemExit("release artifact manifest: current commit does not match artifact")
    if data["buildInputSHA256"] != build_input_digest(root):
        raise SystemExit("release artifact manifest: build inputs changed after packaging")
    actual = digest_tree(bundle)
    if data["contentSHA256"] != actual:
        raise SystemExit("release artifact manifest: artifact content digest changed")
    print(f"release artifact manifest: validated {manifest}")


parser = argparse.ArgumentParser()
parser.add_argument("command", choices=("create", "validate"))
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--manifest", type=Path, required=True)
args = parser.parse_args()
if args.command == "create":
    make(args.root, args.root / "dist" / BUNDLE_NAME, args.manifest)
else:
    validate(args.root, args.manifest)
