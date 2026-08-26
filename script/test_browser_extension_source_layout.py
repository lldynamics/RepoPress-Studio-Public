#!/usr/bin/env python3
"""Regression tests for the shared browser-extension source layout."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BUILDER = ROOT / "script" / "build_browser_extension_source.py"
SHARED_FILES = {
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
}


def run(*arguments: str) -> None:
    result = subprocess.run(
        [sys.executable, str(BUILDER), *arguments],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result.stdout)


for browser in ("chrome", "firefox"):
    run("--browser", browser, "--check")

with tempfile.TemporaryDirectory(prefix="browser-extension-source-layout-") as directory:
    output_root = Path(directory)
    for browser in ("chrome", "firefox"):
        output = output_root / browser
        run("--browser", browser, "--output-dir", str(output))
        actual_files = {
            path.relative_to(output).as_posix()
            for path in output.rglob("*")
            if path.is_file()
        }
        assert actual_files == SHARED_FILES | {"manifest.json"}
        manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
        source_manifest = json.loads(
            (ROOT / "BrowserExtension" / browser.capitalize() / "manifest.json")
            .read_text(encoding="utf-8")
        )
        assert manifest == source_manifest

print("browser extension source layout: passed")
