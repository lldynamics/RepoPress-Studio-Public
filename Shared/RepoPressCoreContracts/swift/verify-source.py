#!/usr/bin/env python3
"""Verify a generated Swift source snapshot; never changes files or accesses the network."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import re


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def snapshot_digest(files: dict[str, str]) -> str:
    return digest(json.dumps(files, sort_keys=True, separators=(",", ":")).encode())


def verify(root: Path, *, allow_legacy: bool = False) -> str:
    lock = json.loads((root / "source-lock.json").read_text(encoding="utf-8"))
    if lock.get("formatVersion") != 1 or lock.get("source") != "RepoPressCore/swift":
        raise ValueError("unsupported source lock")
    source_commit = lock.get("sourceCommit")
    if source_commit is None and allow_legacy:
        pass
    elif not isinstance(source_commit, str) or not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("invalid source commit")
    files = lock["files"]
    if not isinstance(files, dict) or not files or snapshot_digest(files) != lock["snapshotSHA256"]:
        raise ValueError("invalid snapshot digest")
    for name, expected in files.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or str(relative) != name:
            raise ValueError(f"unsafe snapshot path: {name}")
        path = root / name
        if any(root.joinpath(*relative.parts[:index]).is_symlink() for index in range(1, len(relative.parts) + 1)):
            raise ValueError(f"symlink in snapshot path: {name}")
        if not path.is_file() or digest(path.read_bytes()) != expected:
            raise ValueError(f"shared source changed or missing: {name}")
    for directory in ("Sources", "Tests", "contracts"):
        for path in (root / directory).rglob("*"):
            if path.is_symlink() or (path.is_file() and path.relative_to(root).as_posix() not in files):
                raise ValueError(f"untracked shared source: {path.relative_to(root)}")
    return lock["snapshotSHA256"]


if __name__ == "__main__":
    try:
        print(f"Shared Swift source verified: {verify(Path(__file__).resolve().parent)}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Shared Swift source verification failed: {error}", file=sys.stderr)
        sys.exit(1)
