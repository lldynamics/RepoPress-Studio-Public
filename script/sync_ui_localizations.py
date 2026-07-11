#!/usr/bin/env python3
"""Extract SwiftUI localization keys and synchronize reviewed zh-Hans/en values."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE_ROOT = ROOT / "Sources" / "PersonalSitePublisherMac"
WORKSPACE_MODELS_PATH = ROOT / "Sources" / "PublishingWorkbenchCore" / "Models" / "WorkspaceModels.swift"
CATALOG_PATH = SOURCE_ROOT / "Resources" / "Localizable.xcstrings"
TRANSLATIONS_PATH = ROOT / "script" / "ui_localization_translations.json"
FORMAT_PATTERN = re.compile(r"%(?:\d+\$)?(?:@|[-+0-9.]*[a-zA-Z])")
CJK_PATTERN = re.compile(r"[\u3400-\u9fff]")
WORKSPACE_SECTION_PATTERN = re.compile(
    r"public enum WorkspaceSection.*?(?=public enum WorkspaceNavigationSurface)",
    re.DOTALL,
)
WORKSPACE_SECTION_CASE_PATTERN = re.compile(r"^\s*case\s+([A-Za-z][A-Za-z0-9_]*)\s*$", re.MULTILINE)


def extract_swiftui_strings() -> dict[str, str]:
    swift_files = sorted(str(path) for path in SOURCE_ROOT.rglob("*.swift"))
    with tempfile.TemporaryDirectory(prefix="psp-localization-") as temporary_directory:
        output_directory = Path(temporary_directory) / "genstrings"
        output_directory.mkdir()
        result = subprocess.run(
            ["genstrings", "-SwiftUI", "-u", "-o", str(output_directory), *swift_files],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        # genstrings reports dynamic non-literal calls as diagnostics but still
        # returns a complete file for every literal SwiftUI key it supports.
        strings_path = output_directory / "Localizable.strings"
        if not strings_path.exists():
            raise RuntimeError(result.stderr.strip() or "genstrings produced no Localizable.strings")
        json_path = Path(temporary_directory) / "Localizable.json"
        subprocess.run(
            ["plutil", "-convert", "json", "-o", str(json_path), str(strings_path)],
            check=True,
        )
        return json.loads(json_path.read_text(encoding="utf-8"))


def extract_workspace_navigation_keys() -> dict[str, str]:
    """Collect model-driven navigation keys that genstrings cannot see."""
    source = WORKSPACE_MODELS_PATH.read_text(encoding="utf-8")
    section_match = WORKSPACE_SECTION_PATTERN.search(source)
    if not section_match:
        raise RuntimeError("could not find WorkspaceSection model")
    section_source = section_match.group(0)
    if CJK_PATTERN.search(section_source):
        raise RuntimeError("WorkspaceSection must expose localization keys, not CJK display text")

    sections = WORKSPACE_SECTION_CASE_PATTERN.findall(section_source)
    if not sections:
        raise RuntimeError("WorkspaceSection has no cases to localize")
    return {
        key: key
        for section in sections
        for key in (f"workspace.{section}", f"workspace.{section}.detail")
    }


def placeholders(value: str) -> list[str]:
    return FORMAT_PATTERN.findall(value)


def localized_value(entry: dict, language: str) -> str | None:
    return (
        entry.get("localizations", {})
        .get(language, {})
        .get("stringUnit", {})
        .get("value")
    )


def validate(catalog: dict, extracted: dict[str, str], model_keys: set[str]) -> list[str]:
    missing: list[str] = []
    strings = catalog.get("strings", {})
    for key, source_value in extracted.items():
        entry = strings.get(key, {})
        zh_value = localized_value(entry, "zh-Hans")
        en_value = localized_value(entry, "en")
        if not zh_value or not en_value:
            missing.append(f"{key}: missing zh-Hans/en value")
            continue
        source_placeholders = sorted(placeholders(source_value))
        if sorted(placeholders(zh_value)) != source_placeholders:
            missing.append(f"{key}: zh-Hans placeholders differ")
        if sorted(placeholders(en_value)) != source_placeholders:
            missing.append(f"{key}: en placeholders differ")
        if key in model_keys and CJK_PATTERN.search(en_value):
            missing.append(f"{key}: English value contains CJK text")
    return missing


def synchronize(catalog: dict, extracted: dict[str, str]) -> dict:
    strings = catalog.setdefault("strings", {})
    translations = json.loads(TRANSLATIONS_PATH.read_text(encoding="utf-8"))

    for key, source_value in extracted.items():
        entry = strings.get(key, {})
        if localized_value(entry, "zh-Hans") and localized_value(entry, "en"):
            continue
        translated_value = translations.get(key)
        if not isinstance(translated_value, str) or not translated_value.strip():
            raise RuntimeError(f"missing reviewed offline translation: {key}")
        if CJK_PATTERN.search(source_value):
            strings[key] = catalog_entry(source_value, translated_value)
        else:
            strings[key] = catalog_entry(translated_value, source_value)
    return catalog


def catalog_entry(chinese_value: str, english_value: str) -> dict:
    return {
        "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": english_value}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": chinese_value}},
        }
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate catalog coverage without file changes.",
    )
    arguments = parser.parse_args()
    extracted = extract_swiftui_strings()
    workspace_navigation_keys = extract_workspace_navigation_keys()
    extracted.update(workspace_navigation_keys)
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))

    if arguments.check:
        failures = validate(catalog, extracted, set(workspace_navigation_keys))
        if failures:
            print(f"ui localization catalog: {len(failures)} coverage issue(s)")
            for failure in failures[:20]:
                print(f"- {failure}")
            return 1
        print(f"ui localization catalog: {len(extracted)} SwiftUI/model keys have valid zh-Hans/en values")
        return 0

    synchronized = synchronize(catalog, extracted)
    failures = validate(synchronized, extracted, set(workspace_navigation_keys))
    if failures:
        raise RuntimeError("; ".join(failures[:10]))
    CATALOG_PATH.write_text(
        json.dumps(synchronized, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"ui localization catalog: synchronized {len(extracted)} SwiftUI keys")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
