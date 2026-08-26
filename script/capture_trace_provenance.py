#!/usr/bin/env python3
"""Emit source and packaged-bundle provenance for a performance trace.

The output intentionally contains digests rather than Git diff/status text.
That keeps trace metadata useful for reproducibility checks without embedding
changed source, untracked paths, or other workspace contents.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable, Iterator


UNKNOWN = "unknown"


def run_git(root: Path, *arguments: str) -> subprocess.CompletedProcess[bytes] | None:
    try:
        return subprocess.run(
            ["git", "-C", str(root), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return None


def git_commit(root: Path) -> str:
    result = run_git(root, "rev-parse", "HEAD")
    if result is None or result.returncode != 0:
        return UNKNOWN
    commit = result.stdout.decode("ascii", errors="replace").strip()
    return commit or UNKNOWN


def untracked_paths(root: Path) -> list[bytes] | None:
    result = run_git(root, "ls-files", "--others", "--exclude-standard", "-z")
    if result is None or result.returncode != 0:
        return None
    return sorted(path for path in result.stdout.split(b"\0") if path)


def stream_hash(digest: "hashlib._Hash", stream: Iterable[bytes]) -> None:
    for chunk in stream:
        digest.update(chunk)


def file_digest(path: Path) -> str | None:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            stream_hash(digest, iter(lambda: handle.read(1024 * 1024), b""))
        return f"sha256:{digest.hexdigest()}"
    except (OSError, ValueError):
        return None


def symlink_digest(path: Path) -> str | None:
    try:
        return hashlib.sha256(os.readlink(path).encode("utf-8", errors="surrogateescape")).hexdigest()
    except OSError:
        return None


def append_untracked_entry(digest: "hashlib._Hash", root: Path, encoded_path: bytes) -> None:
    # The relative path is input to the digest only; it is never emitted in
    # metadata. Decode with surrogateescape so every Git path is representable.
    relative = os.fsdecode(encoded_path)
    path = root / Path(relative)
    digest.update(b"untracked\0" + encoded_path + b"\0")
    try:
        if path.is_symlink():
            digest.update(b"symlink\0")
            digest.update((symlink_digest(path) or UNKNOWN).encode("ascii"))
        elif path.is_file():
            digest.update(b"file\0")
            digest.update((file_digest(path) or UNKNOWN).encode("ascii"))
        elif path.is_dir():
            digest.update(b"directory\0")
        else:
            digest.update(b"other\0")
    except OSError:
        digest.update(b"unreadable\0")


def working_tree_state(root: Path, commit: str) -> tuple[bool | None, str]:
    tracked_diff = run_git(root, "diff", "--binary", "--no-ext-diff", "HEAD", "--")
    paths = untracked_paths(root)
    if (
        tracked_diff is None
        or paths is None
        or tracked_diff.returncode != 0
    ):
        return None, UNKNOWN

    digest = hashlib.sha256()
    digest.update(b"repopress-working-tree-state-v1\0")
    digest.update(commit.encode("ascii", errors="replace"))
    digest.update(b"\0tracked-diff\0")
    # Hash the diff bytes, never place them in the JSON output.  HEAD-relative
    # diff includes both index and worktree changes and is deterministic for a
    # fixed checkout state.
    digest.update(hashlib.sha256(tracked_diff.stdout).digest())
    digest.update(b"\0untracked\0")
    for path in paths:
        append_untracked_entry(digest, root, path)
    dirty = bool(tracked_diff.stdout) or bool(paths)
    return dirty, f"sha256:{digest.hexdigest()}"


def iter_tree_entries(root: Path) -> Iterator[tuple[str, str, str | None]]:
    """Yield deterministic (relative path, kind, digest) records."""

    if not root.is_dir():
        return
    for current, directories, files in os.walk(root, followlinks=False):
        directories.sort()
        files.sort()
        current_path = Path(current)
        directory_names = list(directories)
        for name in directory_names:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                directories.remove(name)
                yield relative, "symlink", symlink_digest(path)
            else:
                yield relative, "directory", None
        for name in files:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                yield relative, "symlink", symlink_digest(path)
            else:
                yield relative, "file", file_digest(path)


def tree_digest(root: Path) -> str | None:
    if not root.is_dir():
        return None
    digest = hashlib.sha256()
    digest.update(b"repopress-bundle-tree-v1\0")
    try:
        for relative, kind, entry_digest in iter_tree_entries(root):
            digest.update(kind.encode("ascii"))
            digest.update(b"\0")
            digest.update(relative.encode("utf-8", errors="surrogateescape"))
            digest.update(b"\0")
            digest.update((entry_digest or UNKNOWN).encode("ascii"))
            digest.update(b"\0")
    except OSError:
        return None
    return f"sha256:{digest.hexdigest()}"


def build_payload(root: Path, app_bundle: Path, app_binary: Path) -> dict[str, object]:
    commit = git_commit(root)
    dirty, state_hash = working_tree_state(root, commit)
    return {
        "commit": commit,
        "workingTreeDirty": dirty,
        "workingTreeStateHash": state_hash,
        "reproducibleCleanCommit": commit != UNKNOWN and dirty is False,
        "appBundleSHA256": tree_digest(app_bundle),
        "appBinarySHA256": file_digest(app_binary),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    arguments = parser.parse_args()
    payload = build_payload(
        arguments.root.resolve(),
        arguments.bundle,
        arguments.binary,
    )
    json.dump(payload, sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
