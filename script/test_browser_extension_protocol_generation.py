#!/usr/bin/env python3
"""Behavior tests for the browser extension protocol generator."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GENERATOR = ROOT / "script" / "generate_browser_extension_protocol.py"


def run(root: Path, *arguments: str, succeeds: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, str(GENERATOR), "--root", str(root), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if succeeds and result.returncode != 0:
        raise AssertionError(result.stdout)
    if not succeeds and result.returncode == 0:
        raise AssertionError("protocol generator unexpectedly accepted an invalid fixture")
    return result


with tempfile.TemporaryDirectory(prefix="browser-extension-protocol-") as directory:
    fixture = Path(directory)
    extension = fixture / "BrowserExtension"
    firefox = extension / "Firefox"
    swift = fixture / "Sources" / "BrowserExtensionProtocolSupport"
    firefox.mkdir(parents=True)
    swift.mkdir(parents=True)
    for relative in (
        "browser-extension-protocol.json",
        "manifest.json",
        "firefox-release.json",
    ):
        shutil.copyfile(ROOT / "BrowserExtension" / relative, extension / relative)
    shutil.copyfile(
        ROOT / "BrowserExtension" / "Firefox" / "manifest.json",
        firefox / "manifest.json",
    )

    run(fixture, "--write")
    run(fixture, "--check")

    generated_javascript = extension / "protocol.generated.js"
    generated_javascript.write_text(
        generated_javascript.read_text(encoding="utf-8") + "// stale\n",
        encoding="utf-8",
    )
    stale = run(fixture, "--check", succeeds=False)
    assert "protocol.generated.js" in stale.stdout
    run(fixture, "--write")

    firefox_manifest_path = firefox / "manifest.json"
    firefox_manifest = json.loads(firefox_manifest_path.read_text(encoding="utf-8"))
    firefox_manifest["browser_specific_settings"]["gecko"]["id"] = "wrong@example.invalid"
    firefox_manifest_path.write_text(
        json.dumps(firefox_manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    wrong_firefox = run(fixture, "--check", succeeds=False)
    assert "gecko.id" in wrong_firefox.stdout
    run(fixture, "--write")

    definition_path = extension / "browser-extension-protocol.json"
    definition = json.loads(definition_path.read_text(encoding="utf-8"))
    definition["extensions"]["chromiumDevelopmentID"] = "a" * 32
    definition_path.write_text(
        json.dumps(definition, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    wrong_chromium = run(fixture, "--check", succeeds=False)
    assert "Chromium manifest key derives extension ID" in wrong_chromium.stdout

    definition["extensions"]["chromiumDevelopmentID"] = json.loads(
        (ROOT / "BrowserExtension" / "browser-extension-protocol.json").read_text(encoding="utf-8")
    )["extensions"]["chromiumDevelopmentID"]
    definition["extensions"]["chromeProductionID"] = "a" * 32
    definition["extensions"]["edgeProductionID"] = "b" * 32
    definition_path.write_text(
        json.dumps(definition, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    run(fixture, "--write")
    run(fixture, "--check")
    generated_swift = (
        fixture
        / "Sources"
        / "BrowserExtensionProtocolSupport"
        / "BrowserExtensionProtocolGenerated.swift"
    ).read_text(encoding="utf-8")
    assert 'chromeProductionExtensionID: String? =\n    "' + "a" * 32 in generated_swift
    assert "edgeProductionExtensionID" not in generated_swift
    assert "firefoxExtensionID" not in generated_swift

    definition["extensions"]["chromeProductionID"] = "q" * 32
    definition_path.write_text(
        json.dumps(definition, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    invalid_production = run(fixture, "--check", succeeds=False)
    assert "chromeProductionID must be null or a Chromium ID" in invalid_production.stdout

print("browser extension protocol generation: passed")
