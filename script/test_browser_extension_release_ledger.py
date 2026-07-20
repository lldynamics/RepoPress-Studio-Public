#!/usr/bin/env python3
"""Behavior tests for the immutable browser-extension release ledger."""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "script"))

from browser_extension_release_ledger import (  # noqa: E402
    ReleaseLedgerError,
    load_ledger,
    record_publication,
)


SOURCE_SHA256 = "1" * 64
ARTIFACT_SHA256 = "2" * 64
CREATED_AT = "2026-07-19T00:00:00Z"
PUBLISHED_AT = "2026-07-19T01:00:00Z"


def artifact(kind: str, file_name: str) -> dict:
    return {
        "kind": kind,
        "file": file_name,
        "sha256": ARTIFACT_SHA256,
        "recordedAt": CREATED_AT,
    }


with tempfile.TemporaryDirectory(prefix="browser-extension-release-ledger-test-") as directory:
    fixture = Path(directory)
    extension = fixture / "BrowserExtension"
    extension.mkdir()
    ledger_path = extension / "release-ledger.json"
    ledger_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "releases": [
                    {
                        "version": "0.13.0",
                        "sourceSHA256": SOURCE_SHA256,
                        "createdAt": CREATED_AT,
                        "artifacts": [
                            artifact("chrome-zip", "knowledge-capture-chrome-0.13.0.zip"),
                            artifact("edge-zip", "knowledge-capture-edge-0.13.0.zip"),
                        ],
                        "publications": [],
                    }
                ],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    record_publication(fixture, "0.13.0", "chrome", PUBLISHED_AT)
    release = load_ledger(fixture, require_exists=True)["releases"][0]
    assert release["publications"] == [
        {"channel": "chrome", "publishedAt": PUBLISHED_AT}
    ]
    unchanged = ledger_path.read_bytes()
    record_publication(fixture, "0.13.0", "chrome", PUBLISHED_AT)
    assert ledger_path.read_bytes() == unchanged

    try:
        record_publication(fixture, "0.13.0", "chrome", "2026-07-19T02:00:00Z")
    except ReleaseLedgerError as error:
        assert "timestamp replacement rejected" in str(error)
    else:
        raise AssertionError("a published timestamp was silently replaced")

    try:
        record_publication(fixture, "0.13.0", "firefox", PUBLISHED_AT)
    except ReleaseLedgerError as error:
        assert "immutable artifacts are missing" in str(error)
    else:
        raise AssertionError("Firefox publication was recorded without a signed XPI")

    try:
        record_publication(fixture, "0.13.0", "firefox-amo", PUBLISHED_AT)
    except ReleaseLedgerError as error:
        assert "immutable artifacts are missing" in str(error)
    else:
        raise AssertionError("Firefox AMO publication was recorded without its upload XPI")

    try:
        record_publication(fixture, "0.12.0", "chrome", PUBLISHED_AT)
    except ReleaseLedgerError as error:
        assert "unrecorded" in str(error)
    else:
        raise AssertionError("an unrecorded release was marked as published")

print("browser extension release ledger behavior: passed")
