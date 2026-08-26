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
PUBLISHING_CORE_SOURCE_ROOTS = tuple(
    sorted(
        source_root
        for source_root in (ROOT / "Sources").glob("Publishing*")
        if source_root.is_dir()
        and (
            source_root.name.endswith("Core")
            or source_root.name == "PublishingCoreSupport"
        )
    )
)
SCREENSHOT_SUPPORT_SOURCE_ROOT = CORE_SOURCE_ROOT / "DebugSupport"
UI_SOURCE_ROOTS = (SOURCE_ROOT, SCREENSHOT_SUPPORT_SOURCE_ROOT)
CORE_RESOURCE_ROOT = ROOT / "Sources" / "PublishingCoreSupport" / "Resources"
WORKSPACE_MODELS_PATH = ROOT / "Sources" / "PublishingWorkbenchCore" / "Models" / "WorkspaceModels.swift"
CATALOG_PATH = SOURCE_ROOT / "Resources" / "Localizable.xcstrings"
TRANSLATION_PATHS = tuple(sorted((ROOT / "script").glob("ui_*translations*.json")))
DYNAMIC_KEYS_PATH = ROOT / "script" / "ui_localization_dynamic_keys.json"
DYNAMIC_KEY_GROUPS = ("runtime", "sourceLiterals")
FORMAT_PATTERN = re.compile(
    r"%(?:\d+\$)?(?:@|[-+0-9.#]*(?:hh|h|ll|l|z|t|j)?[a-zA-Z])"
)
CJK_PATTERN = re.compile(r"[\u3400-\u9fff]")
SUSPICIOUS_LITERAL_EXPRESSION_PATTERN = re.compile(
    r"\([a-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*"
    r"(?:\s*[-+*/]\s*\d+)?\)"
)
WORKSPACE_SECTION_PATTERN = re.compile(
    r"public enum WorkspaceSection.*?(?=public enum WorkspaceCenterSurface)",
    re.DOTALL,
)
WORKSPACE_SECTION_CASE_PATTERN = re.compile(r"^\s*case\s+([A-Za-z][A-Za-z0-9_]*)\s*$", re.MULTILINE)
LITERAL_LOCALIZATION_CALL_PREFIX_PATTERN = re.compile(
    r'(?:String\s*\(\s*localized:\s*|LocalizedStringKey\s*\(\s*|'
    r'(?:Text|Label|Button|Toggle|Picker|Section|Menu|GroupBox|LabeledContent|TextField|SecureField)\s*\(\s*|'
    r'\.(?:navigationTitle|help|alert|confirmationDialog)\s*\(\s*|'
    r'\.accessibility(?:Label|Hint|Value)\s*\(\s*)'
    r'"'
)
DISPLAY_NAME_SEMANTIC_KEY_PATTERN = re.compile(r'"(display\.[a-z0-9.-]+)"')
DIRECT_DISPLAY_NAME_PATTERN = re.compile(r"\.displayName\b")
NAMED_COMPONENT_TITLE_PATTERN = re.compile(
    r"\b(?:MetricTile|InspectorScaffold|InspectorStatRow|"
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


def swift_interpolation_end(value: str, expression_start: int) -> int:
    """Return the balanced closing parenthesis for a Swift interpolation."""
    depth = 1
    index = expression_start
    in_string = False
    while index < len(value):
        character = value[index]
        if in_string:
            if character == "\\":
                index += 2
                continue
            if character == '"':
                in_string = False
            index += 1
            continue
        if character == '"':
            in_string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise ValueError("unterminated Swift string interpolation")


def swift_string_literal_content(source: str, opening_quote: int) -> str:
    """Read one ordinary Swift string literal, including balanced interpolations."""
    if opening_quote >= len(source) or source[opening_quote] != '"':
        raise ValueError("Swift string literal must start with a quote")
    index = opening_quote + 1
    while index < len(source):
        if source.startswith(r"\(", index):
            index = swift_interpolation_end(source, index + 2) + 1
            continue
        character = source[index]
        if character == "\\":
            index += 2
            continue
        if character == '"':
            return source[opening_quote + 1:index]
        index += 1
    raise ValueError("unterminated Swift string literal")


def normalized_swiftui_literal(raw_value: str) -> str:
    """Decode a Swift literal and normalize balanced LocalizedStringKey interpolation."""
    normalized: list[str] = []
    index = 0
    while index < len(raw_value):
        interpolation_start = raw_value.find(r"\(", index)
        if interpolation_start < 0:
            normalized.append(raw_value[index:])
            break
        normalized.append(raw_value[index:interpolation_start])
        expression_start = interpolation_start + 2
        interpolation_end = swift_interpolation_end(raw_value, expression_start)
        expression = raw_value[expression_start:interpolation_end]
        if re.search(r"(?:count|Count)\b", expression) or re.search(r"\bInt\s*\(", expression):
            normalized.append("%lld")
        else:
            normalized.append("%@")
        index = interpolation_end + 1

    return (
        "".join(normalized)
        .replace(r'\"', '"')
        .replace(r"\n", "\n")
        .replace(r"\t", "\t")
        .replace(r"\\", "\\")
    )


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
        for match in LITERAL_LOCALIZATION_CALL_PREFIX_PATTERN.finditer(source):
            raw_value = swift_string_literal_content(source, match.end() - 1)
            value = normalized_swiftui_literal(raw_value)
            if value:
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
    for source_root in PUBLISHING_CORE_SOURCE_ROOTS:
        for source_path in sorted(source_root.rglob("*.swift")):
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


def extract_normalized_source_literals() -> set[str]:
    """Collect ordinary Swift literals used to verify explicitly dynamic UI keys."""
    extracted: set[str] = set()
    source_paths = {
        path
        for source_root in (SOURCE_ROOT, CORE_SOURCE_ROOT)
        for path in source_root.rglob("*.swift")
    }
    for source_path in sorted(source_paths):
        source = source_path.read_text(encoding="utf-8")
        for quote_match in re.finditer(r'"', source):
            try:
                raw_value = swift_string_literal_content(source, quote_match.start())
                value = normalized_swiftui_literal(raw_value)
            except ValueError:
                continue
            if value:
                extracted.add(value)
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
    return [
        re.sub(r"^%\d+\$", "%", placeholder)
        for placeholder in FORMAT_PATTERN.findall(value)
    ]


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
        if CJK_PATTERN.search(key) and SUSPICIOUS_LITERAL_EXPRESSION_PATTERN.search(key):
            missing.append(f"{key}: looks like an unescaped Swift interpolation")
            continue
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
        if CJK_PATTERN.search(en_value):
            missing.append(f"{key}: English value contains CJK text")
    return missing


def unregistered_cjk_ui_keys(catalog: dict, extracted: dict[str, str]) -> list[str]:
    """Return every extracted Chinese UI key that is absent from the catalog."""
    registered_keys = set(catalog.get("strings", {}))
    return sorted(
        key
        for key in extracted
        if CJK_PATTERN.search(key) and key not in registered_keys
    )


def load_reviewed_translations() -> dict:
    translations: dict = {}
    for translations_path in TRANSLATION_PATHS:
        if not translations_path.exists():
            continue
        entries = load_reviewed_translation_file(translations_path)
        duplicates = sorted(set(translations).intersection(entries))
        if duplicates:
            raise RuntimeError(
                f"duplicate reviewed translation key in {translations_path.name}: {duplicates[0]}"
            )
        translations.update(entries)
    return translations


def load_reviewed_translation_file(path: Path) -> dict:
    """Load one reviewed translation file without silently collapsing JSON keys."""
    duplicate_keys: list[str] = []

    def unique_object(pairs: list[tuple[str, object]]) -> dict:
        value: dict = {}
        for key, item in pairs:
            if key in value:
                duplicate_keys.append(key)
            value[key] = item
        return value

    entries = json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=unique_object,
    )
    if duplicate_keys:
        raise RuntimeError(
            f"duplicate JSON key in {path.name}: {sorted(set(duplicate_keys))[0]}"
        )
    if not isinstance(entries, dict):
        raise RuntimeError(f"{path.name} must contain a JSON object")
    return entries


def load_dynamic_key_allowlist(path: Path = DYNAMIC_KEYS_PATH) -> dict[str, set[str]]:
    """Load runtime and source-backed keys that static extraction cannot discover."""
    entries = load_reviewed_translation_file(path)
    unknown_groups = sorted(set(entries).difference(DYNAMIC_KEY_GROUPS))
    if unknown_groups:
        raise RuntimeError(
            f"unknown dynamic localization key group in {path.name}: {unknown_groups[0]}"
        )

    groups: dict[str, set[str]] = {}
    seen: set[str] = set()
    for group in DYNAMIC_KEY_GROUPS:
        values = entries.get(group, [])
        if not isinstance(values, list) or not all(
            isinstance(value, str) and value.strip()
            for value in values
        ):
            raise RuntimeError(f"{path.name} {group} must be an array of non-empty strings")
        duplicates = sorted(seen.intersection(values))
        if len(set(values)) != len(values):
            duplicates = sorted(
                value for value in set(values) if values.count(value) > 1
            )
        if duplicates:
            raise RuntimeError(
                f"duplicate dynamic localization key in {path.name}: {duplicates[0]}"
            )
        groups[group] = set(values)
        seen.update(values)
    return groups


def validate_dynamic_key_allowlist(
    groups: dict[str, set[str]],
    statically_extracted_keys: set[str],
    source_literals: set[str],
) -> list[str]:
    failures: list[str] = []
    dynamic_keys = set().union(*groups.values())
    for key in sorted(dynamic_keys.intersection(statically_extracted_keys)):
        failures.append(f"{key}: dynamic allowlist entry is now statically extracted")
    for key in sorted(groups.get("sourceLiterals", set()).difference(source_literals)):
        failures.append(f"{key}: dynamic source literal no longer exists in Swift sources")
    return failures


def stale_catalog_keys(catalog: dict, managed_keys: set[str]) -> list[str]:
    return sorted(set(catalog.get("strings", {})).difference(managed_keys))


def stale_reviewed_translation_keys(
    translations: dict,
    managed_keys: set[str],
) -> list[str]:
    return sorted(set(translations).difference(managed_keys))


def prune_catalog(catalog: dict, managed_keys: set[str]) -> list[str]:
    strings = catalog.setdefault("strings", {})
    removed = sorted(set(strings).difference(managed_keys))
    for key in removed:
        del strings[key]
    return removed


def pruned_reviewed_translation_files(
    managed_keys: set[str],
) -> tuple[dict[Path, dict], dict[Path, list[str]]]:
    pruned_files: dict[Path, dict] = {}
    removed_by_path: dict[Path, list[str]] = {}
    for path in TRANSLATION_PATHS:
        entries = load_reviewed_translation_file(path)
        removed = sorted(set(entries).difference(managed_keys))
        pruned_files[path] = {
            key: value for key, value in entries.items() if key in managed_keys
        }
        removed_by_path[path] = removed
    return pruned_files, removed_by_path


def synchronize(catalog: dict, extracted: dict[str, str]) -> dict:
    strings = catalog.setdefault("strings", {})
    translations = load_reviewed_translations()

    for key, source_value in extracted.items():
        entry = strings.get(key, {})
        source_placeholders = sorted(placeholders(source_value))
        existing_values_are_valid = (
            localized_value(entry, "zh-Hans")
            and localized_value(entry, "en")
            and localized_state(entry, "zh-Hans") == "translated"
            and localized_state(entry, "en") == "translated"
            and sorted(placeholders(localized_value(entry, "zh-Hans") or "")) == source_placeholders
            and sorted(placeholders(localized_value(entry, "en") or "")) == source_placeholders
        )
        if existing_values_are_valid:
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
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="Validate the declared app-UI catalog scope without file changes.",
    )
    mode.add_argument(
        "--prune-stale",
        action="store_true",
        help="Synchronize managed keys and remove unreferenced catalog/translation entries.",
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
    statically_extracted = extract_swiftui_strings()
    statically_extracted.update(extract_literal_localization_calls())
    statically_extracted.update(extract_component_localization_keys())
    workspace_navigation_keys = extract_workspace_navigation_keys()
    display_name_semantic_keys = extract_display_name_semantic_keys()
    statically_extracted.update(workspace_navigation_keys)
    statically_extracted.update(display_name_semantic_keys)
    dynamic_key_groups = load_dynamic_key_allowlist()
    dynamic_failures = validate_dynamic_key_allowlist(
        dynamic_key_groups,
        set(statically_extracted),
        extract_normalized_source_literals(),
    )
    if dynamic_failures:
        print(
            f"ui-scoped localization catalog: {len(dynamic_failures)} dynamic allowlist issue(s)"
        )
        for failure in dynamic_failures:
            print(f"- {failure}")
        return 1
    dynamic_keys = set().union(*dynamic_key_groups.values())
    extracted = dict(statically_extracted)
    extracted.update({key: key for key in dynamic_keys})
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    model_keys = set(workspace_navigation_keys) | set(display_name_semantic_keys)
    core_extracted = extract_core_localization_keys()
    core_failures = validate_core_localizations(core_extracted)

    if arguments.check:
        translations = load_reviewed_translations()
        stale_catalog = stale_catalog_keys(catalog, set(extracted))
        stale_translations = stale_reviewed_translation_keys(translations, set(extracted))
        unregistered_cjk_keys = unregistered_cjk_ui_keys(catalog, extracted)
        unregistered_cjk_key_set = set(unregistered_cjk_keys)
        registered_or_non_cjk = {
            key: value
            for key, value in extracted.items()
            if key not in unregistered_cjk_key_set
        }
        failures = [
            f"{key}: unregistered CJK UI key"
            for key in unregistered_cjk_keys
        ]
        failures += validate(catalog, registered_or_non_cjk, model_keys) + core_failures
        failures += [f"{key}: stale catalog key" for key in stale_catalog]
        failures += [f"{key}: stale reviewed translation key" for key in stale_translations]
        if failures:
            print(
                "ui-scoped localization catalog: "
                f"{len(unregistered_cjk_keys)} unregistered CJK UI key(s); "
                f"{len(failures)} total coverage issue(s)"
            )
            for failure in failures[:100]:
                print(f"- {failure}")
            if len(failures) > 100:
                print(f"- ... {len(failures) - 100} more issue(s)")
            return 1
        print(
            f"ui-scoped localization catalog: {len(statically_extracted)} statically extracted keys, "
            f"{len(dynamic_keys)} reviewed dynamic keys, "
            f"and {len(core_extracted)} migrated Core presentation keys have valid zh-Hans/en values; "
            "no extracted CJK UI key or stale managed entry remains"
        )
        return 0

    synchronized = synchronize(catalog, extracted)
    removed_catalog_keys: list[str] = []
    pruned_translation_files: dict[Path, dict] = {}
    removed_translation_keys: dict[Path, list[str]] = {}
    if arguments.prune_stale:
        removed_catalog_keys = prune_catalog(synchronized, set(extracted))
        pruned_translation_files, removed_translation_keys = pruned_reviewed_translation_files(
            set(extracted)
        )
    failures = validate(synchronized, extracted, model_keys) + core_failures
    if failures:
        raise RuntimeError("; ".join(failures))
    CATALOG_PATH.write_text(
        json.dumps(synchronized, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    for path, entries in pruned_translation_files.items():
        path.write_text(
            json.dumps(entries, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    print(
        f"localization catalog: synchronized {len(statically_extracted)} statically extracted keys "
        f"and {len(dynamic_keys)} reviewed dynamic keys; "
        f"validated {len(core_extracted)} migrated Core presentation keys"
    )
    if arguments.prune_stale:
        removed_translation_count = sum(
            len(keys) for keys in removed_translation_keys.values()
        )
        print(
            f"localization catalog: pruned {len(removed_catalog_keys)} stale catalog keys "
            f"and {removed_translation_count} stale reviewed translation entries"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
