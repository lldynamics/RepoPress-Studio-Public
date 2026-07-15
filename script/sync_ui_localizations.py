#!/usr/bin/env python3
"""Synchronize the declared app-UI localization scope.

This extracts app-target SwiftUI literals, literal localization API calls,
workspace navigation keys, and semantic display-name keys. It intentionally
does not claim coverage of presentation strings assembled by
PublishingWorkbenchCore services.
"""

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
TRANSLATION_PATHS = (
    ROOT / "script" / "ui_localization_translations.json",
    ROOT / "script" / "ui_display_name_translations_configuration.json",
    ROOT / "script" / "ui_display_name_translations_publishing.json",
    ROOT / "script" / "ui_display_name_translations_ai_maintenance.json",
    ROOT / "script" / "ui_display_name_translations_additional.json",
)
FORMAT_PATTERN = re.compile(r"%(?:\d+\$)?(?:@|[-+0-9.]*[a-zA-Z])")
CJK_PATTERN = re.compile(r"[\u3400-\u9fff]")
WORKSPACE_SECTION_PATTERN = re.compile(
    r"public enum WorkspaceSection.*?(?=public enum WorkspaceArea|public enum WorkspaceNavigationSurface)",
    re.DOTALL,
)
WORKSPACE_SECTION_CASE_PATTERN = re.compile(r"^\s*case\s+([A-Za-z][A-Za-z0-9_]*)\s*$", re.MULTILINE)
LITERAL_LOCALIZATION_CALL_PATTERN = re.compile(
    r'(?:String\s*\(\s*localized:\s*|\.accessibility(?:Label|Hint)\s*\(\s*)'
    r'"((?:\\.|[^"\\])*)"'
)
DISPLAY_NAME_SEMANTIC_KEY_PATTERN = re.compile(r'"(display\.[a-z0-9.-]+)"')
DIRECT_DISPLAY_NAME_PATTERN = re.compile(r"\.displayName\b")


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


def extract_literal_localization_calls() -> dict[str, str]:
    """Collect literal APIs that genstrings -SwiftUI does not discover."""
    extracted: dict[str, str] = {}
    for source_path in sorted(SOURCE_ROOT.rglob("*.swift")):
        source = source_path.read_text(encoding="utf-8")
        for match in LITERAL_LOCALIZATION_CALL_PATTERN.finditer(source):
            raw_value = match.group(1)
            if "\\(" in raw_value:
                continue
            value = (
                raw_value
                .replace(r'\"', '"')
                .replace(r"\n", "\n")
                .replace(r"\t", "\t")
                .replace(r"\\", "\\")
            )
            extracted[value] = value
    return extracted


def extract_display_name_semantic_keys() -> dict[str, str]:
    extracted: dict[str, str] = {}
    support_root = SOURCE_ROOT / "Support"
    for source_path in sorted(support_root.glob("WorkbenchDisplayNameLocalization*.swift")):
        source = source_path.read_text(encoding="utf-8")
        for key in DISPLAY_NAME_SEMANTIC_KEY_PATTERN.findall(source):
            extracted[key] = key
    return extracted


def direct_display_name_localization_gaps() -> list[str]:
    gaps: list[str] = []
    for source_path in sorted(SOURCE_ROOT.rglob("*.swift")):
        if source_path.name.startswith("WorkbenchDisplayNameLocalization"):
            continue
        source = source_path.read_text(encoding="utf-8")
        for match in DIRECT_DISPLAY_NAME_PATTERN.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            gaps.append(f"{source_path.relative_to(ROOT)}:{line}")
    return gaps


def placeholders(value: str) -> list[str]:
    return FORMAT_PATTERN.findall(value)


def localized_value(entry: dict, language: str) -> str | None:
    return (
        entry.get("localizations", {})
        .get(language, {})
        .get("stringUnit", {})
        .get("value")
    )


def localized_state(entry: dict, language: str) -> str | None:
    return (
        entry.get("localizations", {})
        .get(language, {})
        .get("stringUnit", {})
        .get("state")
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
        if localized_state(entry, "zh-Hans") != "translated" or localized_state(entry, "en") != "translated":
            missing.append(f"{key}: zh-Hans/en state must be translated")
        source_placeholders = sorted(placeholders(source_value))
        if sorted(placeholders(zh_value)) != source_placeholders:
            missing.append(f"{key}: zh-Hans placeholders differ")
        if sorted(placeholders(en_value)) != source_placeholders:
            missing.append(f"{key}: en placeholders differ")
        if key in model_keys and CJK_PATTERN.search(en_value):
            missing.append(f"{key}: English value contains CJK text")
    return missing


def load_reviewed_translations() -> dict:
    translations: dict = {}
    for translations_path in TRANSLATION_PATHS:
        if not translations_path.exists():
            continue
        entries = json.loads(translations_path.read_text(encoding="utf-8"))
        duplicates = sorted(set(translations).intersection(entries))
        if duplicates:
            raise RuntimeError(
                f"duplicate reviewed translation key in {translations_path.name}: {duplicates[0]}"
            )
        translations.update(entries)
    return translations


def synchronize(catalog: dict, extracted: dict[str, str]) -> dict:
    strings = catalog.setdefault("strings", {})
    translations = load_reviewed_translations()

    for key, source_value in extracted.items():
        entry = strings.get(key, {})
        if localized_value(entry, "zh-Hans") and localized_value(entry, "en"):
            continue
        reviewed_translation = translations.get(key)
        if isinstance(reviewed_translation, dict):
            chinese_value = reviewed_translation.get("zh-Hans")
            english_value = reviewed_translation.get("en")
            if not isinstance(chinese_value, str) or not chinese_value.strip():
                raise RuntimeError(f"missing reviewed zh-Hans translation: {key}")
            if not isinstance(english_value, str) or not english_value.strip():
                raise RuntimeError(f"missing reviewed en translation: {key}")
            strings[key] = catalog_entry(chinese_value, english_value)
        elif isinstance(reviewed_translation, str) and reviewed_translation.strip():
            if key.startswith("display."):
                raise RuntimeError(f"semantic display-name key requires reviewed zh-Hans/en values: {key}")
            if CJK_PATTERN.search(source_value):
                strings[key] = catalog_entry(source_value, reviewed_translation)
            else:
                strings[key] = catalog_entry(reviewed_translation, source_value)
        else:
            raise RuntimeError(f"missing reviewed offline translation: {key}")
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
        help="Validate the declared app-UI catalog scope without file changes.",
    )
    arguments = parser.parse_args()
    display_name_gaps = direct_display_name_localization_gaps()
    if display_name_gaps:
        print(
            f"ui-scoped localization catalog: {len(display_name_gaps)} "
            "direct displayName use(s) bypass semantic localization"
        )
        for gap in display_name_gaps[:20]:
            print(f"- {gap}")
        return 1
    extracted = extract_swiftui_strings()
    extracted.update(extract_literal_localization_calls())
    workspace_navigation_keys = extract_workspace_navigation_keys()
    display_name_semantic_keys = extract_display_name_semantic_keys()
    extracted.update(workspace_navigation_keys)
    extracted.update(display_name_semantic_keys)
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    model_keys = set(workspace_navigation_keys) | set(display_name_semantic_keys)

    if arguments.check:
        failures = validate(catalog, extracted, model_keys)
        if failures:
            print(f"ui-scoped localization catalog: {len(failures)} coverage issue(s)")
            for failure in failures[:20]:
                print(f"- {failure}")
            return 1
        print(
            f"ui-scoped localization catalog: {len(extracted)} SwiftUI/selected-model keys "
            "have valid zh-Hans/en values; Core service presentation strings are outside this check"
        )
        return 0

    synchronized = synchronize(catalog, extracted)
    failures = validate(synchronized, extracted, model_keys)
    if failures:
        raise RuntimeError("; ".join(failures[:10]))
    CATALOG_PATH.write_text(
        json.dumps(synchronized, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"ui-scoped localization catalog: synchronized {len(extracted)} SwiftUI/selected-model keys; "
        "Core service presentation strings are outside this operation"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
