#!/usr/bin/env python3
"""Record and verify that each screenshot came from the current visible source."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
from pathlib import Path


def source_fingerprint(root: Path, manifest: Path) -> str:
    helper = root / "script/screenshot_evidence_fingerprint.py"
    spec = importlib.util.spec_from_file_location("screenshot_evidence_fingerprint", helper)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module.fingerprint(root, manifest)


def image_digest(path: Path) -> str:
    return f"sha256:{hashlib.sha256(path.read_bytes()).hexdigest()}"


def image_for(screenshot_dir: Path, screenshot_id: str) -> Path | None:
    for suffix in (".png", ".jpg", ".jpeg"):
        candidate = screenshot_dir / f"{screenshot_id}{suffix}"
        if candidate.is_file():
            return candidate
    return None


def record(args: argparse.Namespace) -> int:
    image = args.image.resolve()
    expected_image = image_for(args.screenshot_dir.resolve(), args.id)
    if expected_image != image:
        raise SystemExit(f"capture provenance: image does not match manifest id {args.id}")
    payload = {
        "schemaVersion": 1,
        "screenshotID": args.id,
        "sourceFingerprint": source_fingerprint(args.root.resolve(), args.manifest.resolve()),
        "imageFingerprint": image_digest(image),
    }
    sidecar = args.screenshot_dir.resolve() / f"{args.id}.capture.json"
    sidecar.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(f"capture provenance: recorded {args.id}")
    return 0


def check(args: argparse.Namespace) -> int:
    root = args.root.resolve()
    manifest = args.manifest.resolve()
    screenshot_dir = args.screenshot_dir.resolve()
    expected_source = source_fingerprint(root, manifest)
    required_ids = []
    for line in manifest.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\| `([^`]+)` \|", line)
        if match:
            required_ids.append(match.group(1))
    if not required_ids:
        raise SystemExit("capture provenance: manifest contains no screenshot IDs")

    stale = []
    for screenshot_id in required_ids:
        image = image_for(screenshot_dir, screenshot_id)
        sidecar = screenshot_dir / f"{screenshot_id}.capture.json"
        try:
            payload = json.loads(sidecar.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            stale.append(screenshot_id)
            continue
        if (
            image is None
            or payload.get("schemaVersion") != 1
            or payload.get("screenshotID") != screenshot_id
            or payload.get("sourceFingerprint") != expected_source
            or payload.get("imageFingerprint") != image_digest(image)
        ):
            stale.append(screenshot_id)
    if stale:
        raise SystemExit(
            "capture provenance: stale or missing capture provenance for: " + " ".join(stale)
        )
    print(f"capture provenance: {len(required_ids)} screenshots match {expected_source}")
    return 0


def main() -> int:
    default_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("record", "check"))
    parser.add_argument("--root", type=Path, default=default_root)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--screenshot-dir", type=Path, required=True)
    parser.add_argument("--id")
    parser.add_argument("--image", type=Path)
    args = parser.parse_args()
    if args.command == "record":
        if not args.id or args.image is None:
            parser.error("record requires --id and --image")
        return record(args)
    return check(args)


if __name__ == "__main__":
    raise SystemExit(main())
