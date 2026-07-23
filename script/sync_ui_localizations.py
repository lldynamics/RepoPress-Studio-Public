#!/usr/bin/env python3
"""Synchronize app UI localization and validate Core presentation resources.

This extracts app-target SwiftUI literals, literal localization API calls,
workspace navigation keys, semantic display-name keys, and explicit CoreL10n
calls used by PublishingWorkbenchCore services.
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
CORE_SOURCE_ROOT = ROOT / "Sources" / "PublishingWorkbenchCore"
SCREENSHOT_SUPPORT_SOURCE_ROOT = CORE_SOURCE_ROOT / "DebugSupport"
UI_SOURCE_ROOTS = (SOURCE_ROOT, SCREENSHOT_SUPPORT_SOURCE_ROOT)
CORE_RESOURCE_ROOT = CORE_SOURCE_ROOT / "Resources"
WORKSPACE_MODELS_PATH = ROOT / "Sources" / "PublishingWorkbenchCore" / "Models" / "WorkspaceModels.swift"
CATALOG_PATH = SOURCE_ROOT / "Resources" / "Localizable.xcstrings"
TRANSLATION_PATHS = tuple(sorted((ROOT / "script").glob("ui_*translations*.json")))
FORMAT_PATTERN = re.compile(r"%(?:\d+\$)?(?:@|[-+0-9.]*[a-zA-Z])")
CJK_PATTERN = re.compile(r"[\u3400-\u9fff]")
SWIFT_INTERPOLATION_PATTERN = re.compile(r"\\\((.*?)\)")
WORKSPACE_SECTION_PATTERN = re.compile(
    r"public enum WorkspaceSection.*?(?=public enum WorkspaceCenterSurface)",
    re.DOTALL,
)
WORKSPACE_SECTION_CASE_PATTERN = re.compile(r"^\s*case\s+([A-Za-z][A-Za-z0-9_]*)\s*$", re.MULTILINE)
LITERAL_LOCALIZATION_CALL_PATTERN = re.compile(
    r'(?:String\s*\(\s*localized:\s*|LocalizedStringKey\s*\(\s*|\.accessibility(?:Label|Hint)\s*\(\s*)'
    r'"((?:\\.|[^"\\])*)"'
)
DISPLAY_NAME_SEMANTIC_KEY_PATTERN = re.compile(r'"(display\.[a-z0-9.-]+)"')
DIRECT_DISPLAY_NAME_PATTERN = re.compile(r"\.displayName\b")
NAMED_COMPONENT_TITLE_PATTERN = re.compile(
    r"\b(?:MetricTile|InspectorScaffold|InspectorStatRow|AIChatInspectorStatRow|"
    r"PublishDrawerCard|PublishDrawerStat|PublishDrawerInfoRow|SettingsConfigurationHealthItem|EmptyStateView)"
    r"\s*\([\s\S]{0,240}?\btitle:\s*\"((?:\\.|[^\"\\])*)\""
)
POSITIONAL_COMPONENT_TITLE_PATTERN = re.compile(
    r"\b(?:InspectorSection|AIChatInspectorSection|releaseRecordActionLabel)\s*\(\s*\"((?:\\.|[^\"\\])*)\""
)
EMPTY_STATE_MESSAGE_PATTERN = re.compile(
    r"\bEmptyStateView\s*\([\s\S]{0,320}?\bmessage:\s*\"((?:\\.|[^\"\\])*)\""
)
EMPTY_STATE_ACTION_TITLE_PATTERN = re.compile(
    r"\bEmptyStateView\s*\([\s\S]{0,520}?\bactionTitle:\s*\"((?:\\.|[^\"\\])*)\""
)
LOCALIZED_STRING_KEY_PROPERTY_PATTERN = re.compile(
    r"\b(?:var|let)\s+[A-Za-z][A-Za-z0-9_]*\s*:\s*LocalizedStringKey\s*\{([\s\S]{0,4000}?)\n\s{2}\}",
    re.MULTILINE,
)
LOCALIZED_STRING_KEY_RETURN_PATTERN = re.compile(r'\breturn\s+"((?:\\.|[^"\\])*)"')
LOCALIZED_HELPER_NAMES = (
    "repositoryUnavailableToolCard",
    "workflowBanner",
    "repositoryOnboardingStep",
    "repositoryPathRule",
    "releaseHistoryMetadataRow",
)
LOCALIZED_HELPER_ARGUMENT_PATTERNS = tuple(
    re.compile(
        rf'(?=\b(?:{"|".join(LOCALIZED_HELPER_NAMES)})\s*\([\s\S]{{0,1200}}?\b{argument}:\s*"((?:\\.|[^"\\])*)")'
    )
    for argument in ("title", "detail", "actionTitle")
)
CORE_LOCALIZATION_CALL_PATTERN = re.compile(
    r'\bCoreL10n\.(?:text|format)\s*\(\s*"((?:\\.|[^"\\])*)"'
)


def normalized_swiftui_literal(raw_value: str) -> str:
    """Decode a Swift literal and normalize simple LocalizedStringKey interpolation."""
    value = (
        raw_value
        .replace(r'\"', '"')
        .replace(r"\n", "\n")
        .replace(r"\t", "\t")
        .replace(r"\\", "\\")
    )

    def placeholder(match: re.Match[str]) -> str:
        expression = match.group(1)
        if re.search(r"(?:count|Count)\b", expression):
            return "%lld"
        return "%@"

    return SWIFT_INTERPOLATION_PATTERN.sub(placeholder, value)


def extract_swiftui_strings() -> dict[str, str]:
    swift_files = sorted(
        str(path)
        for source_root in UI_SOURCE_ROOTS
        for path in source_root.rglob("*.swift")
    )
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
    for source_path in sorted(
        path
        for source_root in UI_SOURCE_ROOTS
        for path in source_root.rglob("*.swift")
    ):
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


def extract_component_localization_keys() -> dict[str, str]:
    """Collect static titles rendered by reusable components through LocalizedStringKey."""
    extracted: dict[str, str] = {}
    for source_path in sorted(
        path
        for source_root in UI_SOURCE_ROOTS
        for path in source_root.rglob("*.swift")
    ):
        source = source_path.read_text(encoding="utf-8")
        for pattern in (
            NAMED_COMPONENT_TITLE_PATTERN,
            POSITIONAL_COMPONENT_TITLE_PATTERN,
            EMPTY_STATE_MESSAGE_PATTERN,
            EMPTY_STATE_ACTION_TITLE_PATTERN,
            *LOCALIZED_HELPER_ARGUMENT_PATTERNS,
        ):
            for match in pattern.finditer(source):
                raw_value = match.group(1)
                value = normalized_swiftui_literal(raw_value)
                extracted[value] = value
        for property_match in LOCALIZED_STRING_KEY_PROPERTY_PATTERN.finditer(source):
            for raw_value in LOCALIZED_STRING_KEY_RETURN_PATTERN.findall(property_match.group(1)):
                if "\\(" in raw_value:
                    continue
                value = normalized_swiftui_literal(raw_value)
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


def extract_core_localization_keys() -> dict[str, str]:
    extracted: dict[str, str] = {}
    for source_path in sorted(CORE_SOURCE_ROOT.rglob("*.swift")):
        source = source_path.read_text(encoding="utf-8")
        for raw_value in CORE_LOCALIZATION_CALL_PATTERN.findall(source):
            value = (
                raw_value
                .replace(r'\"', '"')
                .replace(r"\n", "\n")
                .replace(r"\t", "\t")
                .replace(r"\\", "\\")
            )
            extracted[value] = value
    return extracted


def load_strings_file(path: Path) -> dict[str, str]:
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"could not parse {path}")
    values = json.loads(result.stdout)
    if not isinstance(values, dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in values.items()):
        raise RuntimeError(f"{path} must contain string-to-string entries")
    return values


def validate_core_localizations(extracted: dict[str, str]) -> list[str]:
    localized_values = {
        language: load_strings_file(CORE_RESOURCE_ROOT / f"{language}.lproj" / "Localizable.strings")
        for language in ("zh-Hans", "en")
    }
    failures: list[str] = []
    for key, source_value in extracted.items():
        for language, values in localized_values.items():
            value = values.get(key, "")
            if not value.strip():
                failures.append(f"{key}: missing Core {language} value")
                continue
            if sorted(placeholders(value)) != sorted(placeholders(source_value)):
                failures.append(f"{key}: Core {language} placeholders differ")
            if language == "en" and CJK_PATTERN.search(value):
                failures.append(f"{key}: Core English value contains CJK text")
    return failures


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
    extracted.update(extract_component_localization_keys())
    workspace_navigation_keys = extract_workspace_navigation_keys()
    display_name_semantic_keys = extract_display_name_semantic_keys()
    extracted.update(workspace_navigation_keys)
    extracted.update(display_name_semantic_keys)
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    model_keys = set(workspace_navigation_keys) | set(display_name_semantic_keys)
    core_extracted = extract_core_localization_keys()
    core_failures = validate_core_localizations(core_extracted)

    if arguments.check:
        failures = validate(catalog, extracted, model_keys) + core_failures
        if failures:
            print(f"ui-scoped localization catalog: {len(failures)} coverage issue(s)")
            for failure in failures:
                print(f"- {failure}")
            return 1
        print(
            f"ui-scoped localization catalog: {len(extracted)} SwiftUI/selected-model keys "
            f"and {len(core_extracted)} migrated Core presentation keys have valid zh-Hans/en values"
        )
        return 0

    synchronized = synchronize(catalog, extracted)
    failures = validate(synchronized, extracted, model_keys) + core_failures
    if failures:
        raise RuntimeError("; ".join(failures))
    CATALOG_PATH.write_text(
        json.dumps(synchronized, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"localization catalog: synchronized {len(extracted)} SwiftUI/selected-model keys; "
        f"validated {len(core_extracted)} migrated Core presentation keys"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
