#!/usr/bin/env python3
"""Behavior tests for the App Store listing metadata gate."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "script" / "check_app_store_listing_metadata.py"
SOURCE = ROOT / "docs" / "app-store" / "metadata.json"


def run(path: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(CHECKER), "--metadata", str(path), *arguments],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    payload = json.loads(SOURCE.read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory(prefix="app-store-listing-test-") as directory:
        path = Path(directory) / "metadata.json"
        path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        local_result = run(path)
        expect(local_result.returncode == 0, local_result.stderr)
        strict_result = run(path, "--strict")
        expect(strict_result.returncode == 0, strict_result.stderr)

        pending = json.loads(json.dumps(payload))
        pending["appReview"]["contact"]["configuredInAppStoreConnect"] = False
        path.write_text(json.dumps(pending, ensure_ascii=False), encoding="utf-8")
        pending_result = run(path, "--strict")
        expect(pending_result.returncode != 0, "strict mode accepted an unconfirmed review contact")

        complete = json.loads(json.dumps(payload))
        complete["privacyPolicyURL"] = "https://example.com/privacy"
        for localization in complete["localizations"].values():
            localization["supportURL"] = "https://example.com/support"
        complete["appReview"]["contact"]["configuredInAppStoreConnect"] = False
        complete["appReview"]["contact"]["name"] = "Review Contact"
        complete["appReview"]["contact"]["phone"] = "+1 555 0100"
        path.write_text(json.dumps(complete, ensure_ascii=False), encoding="utf-8")
        complete_result = run(path, "--strict")
        expect(complete_result.returncode == 0, complete_result.stderr)

        complete["appReview"]["contact"]["configuredInAppStoreConnect"] = "yes"
        path.write_text(json.dumps(complete, ensure_ascii=False), encoding="utf-8")
        contact_flag_result = run(path)
        expect(contact_flag_result.returncode != 0, "checker accepted a non-boolean review contact flag")
        complete["appReview"]["contact"]["configuredInAppStoreConnect"] = False

        complete["localizations"]["en-US"]["subtitle"] = "x" * 31
        path.write_text(json.dumps(complete, ensure_ascii=False), encoding="utf-8")
        length_result = run(path)
        expect(length_result.returncode != 0, "checker accepted an overlong subtitle")

        complete["localizations"]["en-US"]["subtitle"] = "Write and publish"
        complete["localizations"]["en-US"]["keywords"] = "x" * 101
        path.write_text(json.dumps(complete, ensure_ascii=False), encoding="utf-8")
        keyword_result = run(path)
        expect(keyword_result.returncode != 0, "checker accepted keywords over 100 bytes")

    print("app store listing metadata tests: passed")


if __name__ == "__main__":
    main()
