#!/usr/bin/env python3
"""Behavior tests for Chrome Web Store release packaging."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PACKAGER = ROOT / "script" / "chromium_extension_release.py"
SOURCE_FILES = (
    "background-capture.js",
    "background-queue-operations.js",
    "background-queue-storage.js",
    "background-security.js",
    "background.js",
    "browser-extension-protocol.json",
    "chromium-store-listing.json",
    "firefox-release.json",
    "manifest.json",
    "popup.css",
    "popup.html",
    "popup.js",
    "protocol.generated.js",
)


def run(
    root: Path,
    *arguments: str,
    succeeds: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, str(PACKAGER), "--root", str(root), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if succeeds and result.returncode != 0:
        raise AssertionError(result.stdout)
    if not succeeds and result.returncode == 0:
        raise AssertionError("Chromium store release tool unexpectedly accepted an invalid fixture")
    return result


with tempfile.TemporaryDirectory(prefix="chromium-store-release-test-") as directory:
    fixture = Path(directory) / "project"
    extension = fixture / "BrowserExtension"
    extension.mkdir(parents=True)
    for relative in SOURCE_FILES:
        shutil.copyfile(ROOT / "BrowserExtension" / relative, extension / relative)
    shutil.copytree(ROOT / "BrowserExtension" / "icons", extension / "icons")
    shutil.copytree(ROOT / "BrowserExtension" / "_locales", extension / "_locales")
    shutil.copytree(ROOT / "BrowserExtension" / "Firefox", extension / "Firefox")
    version = json.loads((extension / "manifest.json").read_text(encoding="utf-8"))["version"]

    run(fixture, "check")
    output_dir = fixture / "packages"
    package_result = run(fixture, "package", "--output-dir", str(output_dir))
    assert "ready for upload" in package_result.stdout

    expected_packages = {
        output_dir / f"knowledge-capture-chrome-{version}.zip",
    }
    assert set(output_dir.iterdir()) == expected_packages
    package_bytes = []
    for package in sorted(expected_packages):
        package_bytes.append(package.read_bytes())
        with zipfile.ZipFile(package) as archive:
            names = archive.namelist()
            assert names == sorted(names)
            assert "README.md" not in names
            assert "browser-extension-protocol.json" not in names
            assert "_locales/en/messages.json" in names
            assert "_locales/zh_CN/messages.json" in names
            archived_manifest = json.loads(archive.read("manifest.json"))
            assert "key" not in archived_manifest
            assert "update_url" not in archived_manifest
            assert archived_manifest["icons"]["128"] == "icons/icon128.png"
            assert archived_manifest["name"] == "__MSG_extensionName__"
            assert archived_manifest["default_locale"] == "zh_CN"
            assert archived_manifest["optional_permissions"] == ["tabs"]
            assert all(info.date_time == (1980, 1, 1, 0, 0, 0) for info in archive.infolist())
    assert len(package_bytes) == 1

    ledger_path = extension / "release-ledger.json"
    ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
    assert ledger["schemaVersion"] == 1
    assert [release["version"] for release in ledger["releases"]] == [version]
    release = ledger["releases"][0]
    assert len(release["sourceSHA256"]) == 64
    assert {artifact["kind"] for artifact in release["artifacts"]} == {
        "chrome-zip",
    }
    ledger_bytes = ledger_path.read_bytes()
    run(fixture, "package", "--output-dir", str(output_dir))
    assert ledger_path.read_bytes() == ledger_bytes

    popup_path = extension / "popup.js"
    firefox_popup_path = extension / "Firefox" / "popup.js"
    original_popup = popup_path.read_bytes()
    popup_path.write_bytes(original_popup + b"\n// same-version drift\n")
    firefox_popup_path.write_bytes(original_popup + b"\n// same-version drift\n")
    drift = run(fixture, "package", "--output-dir", str(output_dir), succeeds=False)
    assert "Same-version different-source" in drift.stdout
    popup_path.write_bytes(original_popup)
    firefox_popup_path.write_bytes(original_popup)

    conflicting_output = fixture / "conflicting-packages"
    conflicting_output.mkdir()
    conflicting_chrome = conflicting_output / f"knowledge-capture-chrome-{version}.zip"
    conflicting_chrome.write_bytes(b"different package bytes")
    replacement = run(
        fixture,
        "package",
        "--output-dir",
        str(conflicting_output),
        succeeds=False,
    )
    assert "Refusing to replace same-version release artifact" in replacement.stdout

    chromium_manifest_path = extension / "manifest.json"
    firefox_manifest_path = extension / "Firefox" / "manifest.json"
    chromium_manifest = json.loads(chromium_manifest_path.read_text(encoding="utf-8"))
    firefox_manifest = json.loads(firefox_manifest_path.read_text(encoding="utf-8"))
    chromium_manifest["version"] = "0.18.0"
    firefox_manifest["version"] = "0.18.0"
    chromium_manifest_path.write_text(json.dumps(chromium_manifest, indent=2) + "\n", encoding="utf-8")
    firefox_manifest_path.write_text(json.dumps(firefox_manifest, indent=2) + "\n", encoding="utf-8")
    downgrade = run(fixture, "check", succeeds=False)
    assert "version downgrade rejected" in downgrade.stdout
    shutil.copyfile(ROOT / "BrowserExtension" / "manifest.json", chromium_manifest_path)
    shutil.copyfile(ROOT / "BrowserExtension" / "Firefox" / "manifest.json", firefox_manifest_path)

    definition_path = extension / "browser-extension-protocol.json"
    definition = json.loads(definition_path.read_text(encoding="utf-8"))
    definition["extensions"]["safariBundleID"] = "com.example.invalid"
    definition_path.write_text(
        json.dumps(definition, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    invalid_safari_identity = run(fixture, "check", succeeds=False)
    assert "Safari Web Extension bundle ID" in invalid_safari_identity.stdout
    definition["extensions"]["safariBundleID"] = (
        "com.jinfang.PersonalSitePublisherMac.SafariExtension"
    )
    definition["activeExtensions"] = ["safari", "chrome", "edge"]
    definition_path.write_text(
        json.dumps(definition, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    unsupported_channel = run(fixture, "check", succeeds=False)
    assert "exactly Safari, Chrome, and Firefox" in unsupported_channel.stdout
    definition["activeExtensions"] = ["safari", "chrome", "firefox"]
    definition["extensions"]["chromeProductionID"] = None
    definition_path.write_text(
        json.dumps(definition, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    pending = run(fixture, "readiness", succeeds=False)
    assert "Chrome Web Store production ID is pending" in pending.stdout
    definition["extensions"]["chromeProductionID"] = "a" * 32
    definition_path.write_text(
        json.dumps(definition, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    chrome_ready = run(fixture, "readiness", "--channel", "chrome")
    assert "Chrome Web Store: " + "a" * 32 in chrome_ready.stdout
    assert "Microsoft Edge Add-ons:" not in chrome_ready.stdout
    ready = run(fixture, "readiness")
    assert "Chrome Web Store: " + "a" * 32 in ready.stdout
    metadata_path = extension / "chromium-store-listing.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["optionalPermissionJustifications"] = {}
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    missing_optional_permission_disclosure = run(fixture, "check", succeeds=False)
    assert "optional-permission justifications" in missing_optional_permission_disclosure.stdout

    metadata = json.loads(
        (ROOT / "BrowserExtension" / "chromium-store-listing.json").read_text(encoding="utf-8")
    )
    metadata["privacyPolicyURL"] = "http://example.invalid/privacy"
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    insecure_metadata = run(fixture, "check", succeeds=False)
    assert "privacyPolicyURL must be an HTTPS URL" in insecure_metadata.stdout

    shutil.copyfile(
        ROOT / "BrowserExtension" / "chromium-store-listing.json",
        metadata_path,
    )
    (extension / "icons" / "icon128.png").unlink()
    missing_icon = run(fixture, "check", succeeds=False)
    assert "Required regular Chromium source file is missing" in missing_icon.stdout

print("Chromium store release behavior: passed")
