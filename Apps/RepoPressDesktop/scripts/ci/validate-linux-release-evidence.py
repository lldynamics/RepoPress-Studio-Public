#!/usr/bin/env python3
"""Fail-closed validation for P14's real-machine Linux acceptance evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

SCHEMA = "linux-release-evidence/v1"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
DESKTOPS = {"GNOME", "KDE"}
SESSIONS = {"Wayland", "X11"}
IMES = {"IBus", "Fcitx5"}
SCALES = {"1x", "2x"}
REQUIRED_CHECKS = {"launch", "chinese_input", "candidate_window", "accessibility"}
EXPECTED = {
    ("Ubuntu", "22.04", "GNOME", "X11", "zh_CN.UTF-8", "1x", "IBus"),
    ("Ubuntu", "22.04", "GNOME", "Wayland", "zh_CN.UTF-8", "2x", "IBus"),
    ("Ubuntu", "24.04", "GNOME", "Wayland", "zh_CN.UTF-8", "1x", "IBus"),
    ("Ubuntu", "24.04", "KDE", "X11", "zh_CN.UTF-8", "2x", "Fcitx5"),
    ("Ubuntu", "24.04", "KDE", "Wayland", "zh_CN.UTF-8", "1x", "Fcitx5"),
}
MAX_EVIDENCE_BYTES = 2 * 1024 * 1024
MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
MAX_TOTAL_ATTACHMENT_BYTES = 100 * 1024 * 1024
MAX_ATTACHMENTS_PER_ENVIRONMENT = 8


class EvidenceError(ValueError):
    pass


def _keys(obj: dict[str, Any], allowed: set[str], where: str) -> None:
    unknown = set(obj) - allowed
    if unknown:
        raise EvidenceError(f"{where}: unknown field(s): {', '.join(sorted(unknown))}")


def _text(value: Any, where: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        raise EvidenceError(f"{where}: expected non-empty string")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise EvidenceError(f"{where}: control characters are not allowed")
    return value


def _sha(value: Any, where: str) -> str:
    value = _text(value, where)
    if not SHA256.fullmatch(value):
        raise EvidenceError(f"{where}: expected lowercase SHA-256")
    return value


def _attachment(path_text: str, evidence_dir: Path, where: str) -> Path:
    _text(path_text, where)
    path = Path(path_text)
    if path.is_absolute() or ".." in path.parts:
        raise EvidenceError(f"{where}: path must be relative and stay inside evidence directory")
    resolved = (evidence_dir / path).resolve()
    try:
        resolved.relative_to(evidence_dir.resolve())
    except ValueError as exc:
        raise EvidenceError(f"{where}: path escapes evidence directory") from exc
    if not resolved.is_file():
        raise EvidenceError(f"{where}: attachment does not exist")
    if resolved.stat().st_size > MAX_ATTACHMENT_BYTES:
        raise EvidenceError(f"{where}: attachment exceeds size limit")
    return resolved


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate(data: Any, evidence_file: Path, artifact: Path | None = None) -> None:
    if not isinstance(data, dict):
        raise EvidenceError("evidence root must be an object")
    _keys(data, {"schema", "release_version", "artifact_sha256", "recorded_at", "tester", "environments"}, "root")
    for field in ("schema", "release_version", "artifact_sha256", "recorded_at", "tester", "environments"):
        if field not in data:
            raise EvidenceError(f"root: missing field: {field}")
    if data["schema"] != SCHEMA:
        raise EvidenceError(f"root.schema: expected {SCHEMA}")
    _text(data["release_version"], "root.release_version")
    digest = _sha(data["artifact_sha256"], "root.artifact_sha256")
    try:
        parsed = datetime.fromisoformat(_text(data["recorded_at"], "root.recorded_at").replace("Z", "+00:00"))
    except ValueError as exc:
        raise EvidenceError("root.recorded_at: expected ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise EvidenceError("root.recorded_at: timezone is required")
    _text(data["tester"], "root.tester")
    if not isinstance(data["environments"], list) or len(data["environments"]) != len(EXPECTED):
        raise EvidenceError(f"root.environments: exactly {len(EXPECTED)} environments are required")
    seen: set[tuple[str, str, str, str, str, str, str]] = set()
    attachment_paths: set[Path] = set()
    total_attachment_bytes = 0
    for index, row in enumerate(data["environments"]):
        where = f"environments[{index}]"
        if not isinstance(row, dict):
            raise EvidenceError(f"{where}: expected object")
        _keys(row, {"environment", "checks", "attachments"}, where)
        if set(row) != {"environment", "checks", "attachments"}:
            raise EvidenceError(f"{where}: environment, checks and attachments are required")
        env = row["environment"]
        if not isinstance(env, dict):
            raise EvidenceError(f"{where}.environment: expected object")
        _keys(env, {"distro", "version", "desktop", "session", "locale", "scale", "ime"}, where + ".environment")
        if set(env) != {"distro", "version", "desktop", "session", "locale", "scale", "ime"}:
            raise EvidenceError(f"{where}.environment: all exact environment fields are required")
        for field in ("distro", "version", "desktop", "session", "locale", "scale", "ime"):
            _text(env[field], where + ".environment." + field)
        if env["desktop"] not in DESKTOPS or env["session"] not in SESSIONS or env["scale"] not in SCALES or env["ime"] not in IMES:
            raise EvidenceError(f"{where}: unsupported desktop/session/scale/IME value")
        identity = tuple(env[field] for field in ("distro", "version", "desktop", "session", "locale", "scale", "ime"))
        if identity not in EXPECTED:
            raise EvidenceError(f"{where}: environment is not one of the required risk-matrix rows")
        if identity in seen:
            raise EvidenceError(f"{where}: duplicate environment")
        seen.add(identity)
        checks = row["checks"]
        if not isinstance(checks, dict):
            raise EvidenceError(f"{where}.checks: expected object")
        _keys(checks, REQUIRED_CHECKS, where + ".checks")
        if set(checks) != REQUIRED_CHECKS:
            raise EvidenceError(f"{where}.checks: all required checks are required")
        for check, result in checks.items():
            if result != "pass":
                raise EvidenceError(f"{where}.checks.{check}: only pass is acceptable (pending/skip/fail rejected)")
        attachments = row["attachments"]
        if not isinstance(attachments, list) or not attachments:
            raise EvidenceError(f"{where}.attachments: at least one attachment is required")
        if len(attachments) > MAX_ATTACHMENTS_PER_ENVIRONMENT:
            raise EvidenceError(f"{where}.attachments: no more than {MAX_ATTACHMENTS_PER_ENVIRONMENT} attachments are allowed")
        for ai, item in enumerate(attachments):
            aw = f"{where}.attachments[{ai}]"
            if not isinstance(item, dict):
                raise EvidenceError(f"{aw}: expected object")
            _keys(item, {"path", "sha256"}, aw)
            if set(item) != {"path", "sha256"}:
                raise EvidenceError(f"{aw}: path and sha256 are required")
            actual_path = _attachment(item["path"], evidence_file.parent, aw + ".path")
            if actual_path in attachment_paths:
                raise EvidenceError(f"{aw}: attachment path is reused across environments")
            attachment_paths.add(actual_path)
            total_attachment_bytes += actual_path.stat().st_size
            if total_attachment_bytes > MAX_TOTAL_ATTACHMENT_BYTES:
                raise EvidenceError("attachments: total size exceeds limit")
            expected_hash = _sha(item["sha256"], aw + ".sha256")
            actual_hash = _file_sha256(actual_path)
            if actual_hash != expected_hash:
                raise EvidenceError(f"{aw}: SHA-256 mismatch")
    if seen != EXPECTED:
        missing = EXPECTED - seen
        raise EvidenceError(f"root.environments: required matrix incomplete; missing {sorted(missing)}")
    if artifact is not None:
        if not artifact.is_file():
            raise EvidenceError(f"artifact: file does not exist: {artifact}")
        actual = _file_sha256(artifact)
        if actual != digest:
            raise EvidenceError("root.artifact_sha256: does not match supplied artifact")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate Linux real-machine release evidence")
    parser.add_argument("evidence", type=Path, help="evidence JSON file")
    parser.add_argument("--artifact", type=Path, help="release artifact whose SHA-256 must match")
    args = parser.parse_args(argv)
    try:
        if args.evidence.stat().st_size > MAX_EVIDENCE_BYTES:
            raise EvidenceError("evidence JSON exceeds size limit")
        data = json.loads(args.evidence.read_text(encoding="utf-8"))
        validate(data, args.evidence, args.artifact)
    except (OSError, UnicodeError, json.JSONDecodeError, EvidenceError) as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        return 1
    print("VALID: Linux release evidence contract and artifact binding passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
