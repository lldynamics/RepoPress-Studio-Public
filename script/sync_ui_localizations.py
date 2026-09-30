#!/usr/bin/env python3
"""Synchronize app UI localization and validate Core presentation resources.

This extracts compiler-checked app-target localization keys, supplements them
with literal and semantic keys, and validates explicit CoreL10n calls used by
the app and Publishing Core services.
"""

from __future__ import annotations

import argparse
import json
import os
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
TRANSLATION_PATH = ROOT / "script" / "ui_localization_translations.json"
TRANSLATION_PATHS = (
    TRANSLATION_PATH,
    *tuple(
        sorted(
            path
            for path in (ROOT / "script").glob("ui_*translations*.json")
            if path != TRANSLATION_PATH
        )
    ),
)
TRANSLATION_ARCHIVE_PATH = ROOT / "script" / "archive" / "ui-translations"
DYNAMIC_KEYS_PATH = ROOT / "script" / "ui_localization_dynamic_keys.json"
DYNAMIC_KEY_GROUPS = ("runtime", "sourceLiterals")
FORMAT_PATTERN = re.compile(
    r"%(?:\d+\$)?(?:@|[-+0-9.#]*(?:hh|h|ll|l|z|t|j)?[a-zA-Z])"
)
INTEGER_FORMAT_PATTERN = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|i|u|f|g|e)")
ENGLISH_PLURAL_COUNT_NOUN_PATTERN = re.compile(
    r"\b(?:"
    r"annotations|archives|articles|assets|attachments|backlinks|backups|blockers|"
    r"branches|candidates|captions|changes|characters|choices|commands|completions|"
    r"conflicts|conversations|copies|credentials|days|deletions|diagnostics|"
    r"dimensions|documents|drafts|entries|errors|excerpts|feeds|fields|files|filters|"
    r"hunks|identifiers|images|issues|items|lines|mappings|markers|matches|messages|"
    r"minutes|models|notes|occurrences|passages|paths|points|records|redirects|"
    r"references|replacements|requests|resources|rules|settings|snippets|"
    r"subscriptions|updates|vectors|versions|warnings|words"
    r")\b",
    re.IGNORECASE,
)
CJK_PATTERN = re.compile(r"[\u3400-\u9fff]")
SUSPICIOUS_LITERAL_EXPRESSION_PATTERN = re.compile(
    r"\([a-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*"
    r"(?:\s*[-+*/]\s*\d+)?\)"
)
WORKSPACE_SECTION_PATTERN = re.compile(
    r"public enum WorkspaceSection\b.*?^\}",
    re.DOTALL | re.MULTILINE,
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
    r"\b(?:MetricTile|InspectorStatRow|"
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
    """Keep genstrings coverage for source patterns outside compiler inference."""
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


def parse_compiler_localizations(export_directory: Path, source_root: Path) -> dict[str, str]:
    """Read Swift's per-source stringsdata and require every app source to be present."""
    expected_sources = {path.resolve() for path in source_root.rglob("*.swift")}
    seen_sources: set[Path] = set()
    extracted: dict[str, str] = {}
    for export_path in sorted(export_directory.glob("*.stringsdata")):
        payload = json.loads(export_path.read_text(encoding="utf-8"))
        raw_source = payload.get("source")
        if not isinstance(raw_source, str):
            raise RuntimeError(f"compiler localization export lacks source: {export_path}")
        source = Path(raw_source)
        if not source.is_absolute():
            source = ROOT / source
        source = source.resolve()
        if source not in expected_sources:
            continue
        if source in seen_sources:
            raise RuntimeError(f"duplicate compiler localization export: {source}")
        seen_sources.add(source)
        tables = payload.get("tables")
        if not isinstance(tables, dict):
            raise RuntimeError(f"compiler localization export lacks tables: {export_path}")
        entries = tables.get("Localizable", [])
        if not isinstance(entries, list):
            raise RuntimeError(f"invalid Localizable compiler export: {export_path}")
        for entry in entries:
            key = entry.get("key") if isinstance(entry, dict) else None
            if not isinstance(key, str):
                raise RuntimeError(f"invalid localization key in {export_path}")
            if key:
                extracted[key] = key

    missing_sources = sorted(expected_sources.difference(seen_sources))
    if missing_sources:
        examples = ", ".join(str(path) for path in missing_sources[:5])
        raise RuntimeError(
            f"compiler localization export missing {len(missing_sources)} app source(s): {examples}"
        )
    return extracted


def extract_compiler_localizations() -> dict[str, str]:
    """Compile the app target so Swift determines interpolation placeholder types."""
    temporary_root = ROOT / ".build" / "tmp"
    temporary_root.mkdir(parents=True, exist_ok=True)
    cache_root = temporary_root / "ui-localization-compiler-cache"
    cache_root.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.setdefault("CLANG_MODULE_CACHE_PATH", str(cache_root / "clang"))
    environment.setdefault("SWIFT_MODULE_CACHE_PATH", str(cache_root / "swift"))
    environment.setdefault("XDG_CACHE_HOME", str(cache_root / "xdg"))
    with tempfile.TemporaryDirectory(
        prefix="ui-localization-export-", dir=temporary_root
    ) as temporary_directory:
        export_directory = Path(temporary_directory) / "stringsdata"
        command = [
            # The native driver honors this per-invocation export directory.
            # Swift Build instead redirects stringsdata to its intermediates.
            "swift", "build", "--build-system", "native", "--disable-sandbox",
            "--target", "PersonalSitePublisherMac",
            "-Xswiftc", "-emit-localized-strings",
            "-Xswiftc", "-emit-localized-strings-path",
            "-Xswiftc", str(export_directory),
        ]
        result = subprocess.run(
            command, cwd=ROOT, env=environment, capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            details = "\n".join((result.stdout + result.stderr).splitlines()[-40:])
            raise RuntimeError(f"Swift compiler localization export failed:\n{details}")
        return parse_compiler_localizations(export_directory, SOURCE_ROOT)


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
    keys = {
        key: key
        for section in sections
        for key in (f"workspace.{section}", f"workspace.{section}.detail")
    }
    keys.update({key: key for key in re.findall(r'"(workspace\.[a-zA-Z.]+)"', section_source)})
    area_match = re.search(r"public enum WorkspaceArea\b.*?^\}", source, re.DOTALL | re.MULTILINE)
    if area_match:
        for area in WORKSPACE_SECTION_CASE_PATTERN.findall(area_match.group(0)):
            key = f"workspace.area.{area}"
            keys[key] = key
    return keys


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
    # CoreL10n is also used by the Mac presentation layer. Keep those calls in
    # the same resource check so a new app-side Core key cannot silently fall
    # back to its Chinese source text in English UI.
    for source_root in (*PUBLISHING_CORE_SOURCE_ROOTS, SOURCE_ROOT):
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
    direct_value = (
        entry.get("localizations", {})
        .get(language, {})
        .get("stringUnit", {})
        .get("value")
    )
    if isinstance(direct_value, str):
        substitutions = localized_plural_substitutions(entry, language)
        for name, values in substitutions.items():
            other = values.get("other")
            if isinstance(other, str):
                direct_value = direct_value.replace(f"%#@{name}@", other)
        return direct_value
    plural_values = localized_plural_values(entry, language)
    return plural_values.get("other") if plural_values else None


def localized_state(entry: dict, language: str) -> str | None:
    direct_state = (
        entry.get("localizations", {})
        .get(language, {})
        .get("stringUnit", {})
        .get("state")
    )
    if isinstance(direct_state, str):
        return direct_state
    return localized_plural_states(entry, language).get("other")


def localized_plural_values(entry: dict, language: str) -> dict[str, str]:
    plural = (
        entry.get("localizations", {})
        .get(language, {})
        .get("variations", {})
        .get("plural", {})
    )
    values: dict[str, str] = {}
    if not isinstance(plural, dict):
        return values
    for category, variation in plural.items():
        value = variation.get("stringUnit", {}).get("value") if isinstance(variation, dict) else None
        if isinstance(value, str):
            values[category] = value
    return values


def localized_plural_states(entry: dict, language: str) -> dict[str, str]:
    plural = (
        entry.get("localizations", {})
        .get(language, {})
        .get("variations", {})
        .get("plural", {})
    )
    states: dict[str, str] = {}
    if not isinstance(plural, dict):
        return states
    for category, variation in plural.items():
        state = variation.get("stringUnit", {}).get("state") if isinstance(variation, dict) else None
        if isinstance(state, str):
            states[category] = state
    return states


def substitution_format_specifier(substitution: dict) -> str:
    """Return the catalog specifier without its `%`, e.g. `lld`."""
    specifier = substitution.get("formatSpecifier") if isinstance(substitution, dict) else None
    return specifier.lstrip("%") if isinstance(specifier, str) else ""


def catalog_substitution_value(value: str, specifier: str) -> str:
    """Store a displayed plural fragment in String Catalog form.

    String Catalog substitutions refer to their own argument as `%arg`; a
    literal `%lld` inside the variation is read as an extra argument and
    renders `(null)` at runtime.
    """
    if not specifier or "%arg" in value:
        return value
    return re.sub(rf"%(?:\d+\$)?{re.escape(specifier)}", "%arg", value, count=1)


def localized_plural_substitutions(entry: dict, language: str) -> dict[str, dict[str, str]]:
    """Return plural fragments as displayed text, with `%arg` expanded."""
    substitutions = (
        entry.get("localizations", {})
        .get(language, {})
        .get("substitutions", {})
    )
    values: dict[str, dict[str, str]] = {}
    if not isinstance(substitutions, dict):
        return values
    for name, substitution in substitutions.items():
        plural = substitution.get("variations", {}).get("plural", {}) if isinstance(substitution, dict) else {}
        if not isinstance(plural, dict):
            continue
        specifier = substitution_format_specifier(substitution)
        categories = {
            category: variation["stringUnit"]["value"].replace("%arg", f"%{specifier}")
            for category, variation in plural.items()
            if isinstance(variation, dict)
            and isinstance(variation.get("stringUnit", {}).get("value"), str)
        }
        if categories:
            values[name] = categories
    return values


def plural_substitution_format_errors(entry: dict, language: str) -> list[str]:
    """Catalog substitutions must use a bare specifier and `%arg` fragments."""
    substitutions = (
        entry.get("localizations", {}).get(language, {}).get("substitutions", {})
    )
    errors: list[str] = []
    if not isinstance(substitutions, dict):
        return errors
    for name, substitution in substitutions.items():
        if not isinstance(substitution, dict):
            continue
        specifier = substitution.get("formatSpecifier")
        if not isinstance(specifier, str) or not specifier or specifier.startswith("%"):
            errors.append(f"{name}: formatSpecifier must omit %")
        plural = substitution.get("variations", {}).get("plural", {})
        for category, variation in (plural.items() if isinstance(plural, dict) else []):
            value = variation.get("stringUnit", {}).get("value") if isinstance(variation, dict) else None
            if isinstance(value, str) and "%arg" not in value:
                errors.append(f"{name}.{category}: variation must use %arg")
    return errors


def normalize_plural_substitutions(entry: dict) -> None:
    for localization in entry.get("localizations", {}).values():
        substitutions = localization.get("substitutions") if isinstance(localization, dict) else None
        if not isinstance(substitutions, dict):
            continue
        for substitution in substitutions.values():
            if not isinstance(substitution, dict):
                continue
            specifier = substitution_format_specifier(substitution)
            if not specifier:
                continue
            substitution["formatSpecifier"] = specifier
            plural = substitution.get("variations", {}).get("plural", {})
            for variation in (plural.values() if isinstance(plural, dict) else []):
                unit = variation.get("stringUnit") if isinstance(variation, dict) else None
                if isinstance(unit, dict) and isinstance(unit.get("value"), str):
                    unit["value"] = catalog_substitution_value(unit["value"], specifier)


def localized_effective_plural_values(entry: dict, language: str) -> dict[str, str]:
    """Expand catalog plural substitutions into the displayed one/other text."""
    localization = entry.get("localizations", {}).get(language, {})
    direct = localization.get("stringUnit", {}).get("value")
    substitutions = localized_plural_substitutions(entry, language)
    if not isinstance(direct, str) or not substitutions:
        return localized_plural_values(entry, language)
    categories = set().union(*(values.keys() for values in substitutions.values()))
    effective: dict[str, str] = {}
    for category in categories:
        value = direct
        for name, values in substitutions.items():
            replacement = values.get(category)
            if isinstance(replacement, str):
                value = value.replace(f"%#@{name}@", replacement)
        effective[category] = value
    return effective


def requires_english_plural_variation(value: str) -> bool:
    return bool(
        INTEGER_FORMAT_PATTERN.search(value)
        and ENGLISH_PLURAL_COUNT_NOUN_PATTERN.search(value)
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
        for error in plural_substitution_format_errors(entry, "en"):
            missing.append(f"{key}: en plural substitution {error}")
        if requires_english_plural_variation(en_value):
            substitution_values = localized_plural_substitutions(entry, "en")
            if substitution_values:
                if not all({"one", "other"}.issubset(values) for values in substitution_values.values()):
                    missing.append(f"{key}: en plural substitutions require one/other variations")
                continue
            plural_values = localized_plural_values(entry, "en")
            plural_states = localized_plural_states(entry, "en")
            required_categories = {"one", "other"}
            if set(plural_values).intersection(required_categories) != required_categories:
                missing.append(f"{key}: en count noun requires one/other plural variations")
            else:
                for category in sorted(required_categories):
                    plural_value = plural_values[category]
                    if plural_states.get(category) != "translated":
                        missing.append(f"{key}: en plural {category} state must be translated")
                    if sorted(placeholders(plural_value)) != source_placeholders:
                        missing.append(f"{key}: en plural {category} placeholders differ")
                    if CJK_PATTERN.search(plural_value):
                        missing.append(f"{key}: English plural {category} value contains CJK text")
    return missing


def unregistered_cjk_ui_keys(catalog: dict, extracted: dict[str, str]) -> list[str]:
    """Return every extracted Chinese UI key that is absent from the catalog."""
    registered_keys = set(catalog.get("strings", {}))
    return sorted(
        key
        for key in extracted
        if CJK_PATTERN.search(key) and key not in registered_keys
    )


def merge_reviewed_translation_entries(
    paths: tuple[Path, ...],
    *,
    allow_identical_duplicates: bool = False,
) -> dict:
    translations: dict = {}
    for translations_path in paths:
        if not translations_path.exists():
            continue
        entries = load_reviewed_translation_file(translations_path)
        duplicates = sorted(set(translations).intersection(entries))
        if duplicates:
            conflicting_duplicates = [
                key
                for key in duplicates
                if translations[key] != entries[key]
            ]
            if not (allow_identical_duplicates and not conflicting_duplicates):
                duplicate = (
                    conflicting_duplicates[0]
                    if conflicting_duplicates
                    else duplicates[0]
                )
                raise RuntimeError(
                    f"duplicate reviewed translation key in {translations_path.name}: {duplicate}"
                )
        translations.update(entries)
    return translations


def load_reviewed_translations() -> dict:
    return merge_reviewed_translation_entries(TRANSLATION_PATHS)


def write_json_atomically(path: Path, value: dict) -> None:
    """Replace one JSON dictionary without exposing a partially written file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary_file:
            temporary_file.write(
                json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
            )
            temporary_path = Path(temporary_file.name)
        temporary_path.chmod(
            path.stat().st_mode & 0o777 if path.exists() else 0o644
        )
        temporary_path.replace(path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def merge_reviewed_translation_fragments(
    *,
    master_path: Path = TRANSLATION_PATH,
    fragment_paths: tuple[Path, ...] | None = None,
    archive_directory: Path = TRANSLATION_ARCHIVE_PATH,
) -> tuple[int, int]:
    """Merge root-level increments into the master and archive their source files."""
    fragments = tuple(
        path
        for path in (
            fragment_paths
            if fragment_paths is not None
            else TRANSLATION_PATHS
        )
        if path != master_path and path.exists()
    )
    if not fragments:
        entries = load_reviewed_translation_file(master_path)
        return 0, len(entries)

    duplicate_names = sorted(
        name
        for name in {path.name for path in fragments}
        if sum(path.name == name for path in fragments) > 1
    )
    if duplicate_names:
        raise RuntimeError(f"duplicate translation fragment filename: {duplicate_names[0]}")

    archive_targets = {
        path: archive_directory / path.name
        for path in fragments
    }
    collisions = sorted(
        target.name
        for target in archive_targets.values()
        if target.exists()
    )
    if collisions:
        raise RuntimeError(f"translation archive already contains: {collisions[0]}")

    merged_entries = merge_reviewed_translation_entries(
        (master_path, *fragments),
        allow_identical_duplicates=True,
    )
    archive_directory.mkdir(parents=True, exist_ok=True)
    write_json_atomically(master_path, merged_entries)
    for source, target in archive_targets.items():
        source.replace(target)
    return len(fragments), len(merged_entries)


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


def reviewed_translation_expectation(
    key: str, source_value: str, reviewed_translation: object
) -> tuple[str, str | dict[str, str]] | None:
    """Return the reviewed zh-Hans/en values for one managed key."""
    # Format-only keys (for example "%@ · %@。%@") carry compiler-owned
    # punctuation and argument semantics; a legacy string master value is not
    # enough evidence to reinterpret either language.
    format_free_key = FORMAT_PATTERN.sub("", key)
    if not re.search(r"[A-Za-z\u3400-\u9fff]", format_free_key):
        return None
    if isinstance(reviewed_translation, dict):
        chinese_value = reviewed_translation.get("zh-Hans")
        english_value = reviewed_translation.get("en")
        if not isinstance(chinese_value, str) or not chinese_value.strip():
            raise RuntimeError(f"missing reviewed zh-Hans translation: {key}")
        if isinstance(english_value, dict):
            plural = {
                category: value
                for category, value in english_value.items()
                if category in {"one", "other"}
                and isinstance(value, str)
                and value.strip()
            }
            if set(plural) != {"one", "other"}:
                raise RuntimeError(f"missing reviewed en plural translation: {key}")
            return chinese_value, plural
        if not isinstance(english_value, str) or not english_value.strip():
            raise RuntimeError(f"missing reviewed en translation: {key}")
        return chinese_value, english_value
    if isinstance(reviewed_translation, str) and reviewed_translation.strip():
        if key.startswith("display."):
            raise RuntimeError(
                f"semantic display-name key requires reviewed zh-Hans/en values: {key}"
            )
        if CJK_PATTERN.search(source_value):
            return source_value, reviewed_translation
        return reviewed_translation, source_value
    return None


def canonical_translation_value(value: str) -> str:
    """Normalize implicit arguments without discarding explicit argument identity."""
    next_implicit = 1

    def normalize(match: re.Match[str]) -> str:
        nonlocal next_implicit
        token = match.group(0)
        position = match.group(1)
        if position is None:
            position = str(next_implicit)
            next_implicit += 1
        return f"%{position}${match.group(2)}"

    return re.sub(
        r"%(?:(\d+)\$)?([-+0-9.#]*(?:hh|h|ll|l|z|t|j)?[a-zA-Z@])",
        normalize,
        value,
    )


def translation_value_matches(actual: str | None, expected: str) -> bool:
    return (
        isinstance(actual, str)
        and canonical_translation_value(actual) == canonical_translation_value(expected)
    )


def reviewed_translation_drift(
    catalog: dict, extracted: dict[str, str], translations: dict | None = None
) -> list[str]:
    """Report managed catalog values that differ from the reviewed master mapping."""
    translations = load_reviewed_translations() if translations is None else translations
    failures: list[str] = []
    strings = catalog.get("strings", {})
    for key, source_value in extracted.items():
        reviewed = translations.get(key)
        expectation = reviewed_translation_expectation(key, source_value, reviewed)
        if expectation is None:
            continue
        chinese_value, english_value = expectation
        entry = strings.get(key, {})
        if not translation_value_matches(localized_value(entry, "zh-Hans"), chinese_value):
            failures.append(f"{key}: zh-Hans differs from reviewed translation")
        if isinstance(english_value, dict):
            actual = localized_effective_plural_values(entry, "en")
            for category, expected in sorted(english_value.items()):
                if not translation_value_matches(actual.get(category), expected):
                    failures.append(f"{key}: en {category} differs from reviewed translation")
        elif not translation_value_matches(localized_value(entry, "en"), english_value):
            failures.append(f"{key}: en differs from reviewed translation")
    return failures


def _localization(entry: dict, language: str) -> dict:
    localizations = entry.setdefault("localizations", {})
    value = localizations.setdefault(language, {})
    if not isinstance(value, dict):
        value = {}
        localizations[language] = value
    return value


def update_localization_string(entry: dict, language: str, value: str) -> None:
    """Update a direct value while retaining surrounding catalog metadata."""
    localization = _localization(entry, language)
    unit = localization.get("stringUnit")
    if isinstance(unit, dict):
        unit["value"] = value
        unit["state"] = "translated"
        return
    plural = localization.get("variations", {}).get("plural", {})
    if isinstance(plural, dict) and plural:
        for variation in plural.values():
            if isinstance(variation, dict):
                variation.setdefault("stringUnit", {})["value"] = value
                variation["stringUnit"]["state"] = "translated"
        return
    localization["stringUnit"] = {"state": "translated", "value": value}


def update_localization_plural(
    entry: dict, language: str, values: dict[str, str], *, key: str = ""
) -> None:
    """Update plural text in-place, retaining comments, substitutions and states."""
    localization = _localization(entry, language)
    substitutions = localization.get("substitutions")
    if isinstance(substitutions, dict) and substitutions:
        direct_unit = localization.get("stringUnit")
        direct = direct_unit.get("value") if isinstance(direct_unit, dict) else None
        if isinstance(direct_unit, dict):
            direct_unit["state"] = "translated"
        names = list(substitutions)
        updates: list[tuple[dict, str]] = []
        if isinstance(direct, str) and names:
            parts = re.split(r"(%#@[A-Za-z0-9_.-]+@)", direct)
            markers = [part[3:-1] for part in parts if part.startswith("%#@")]
            static = [part for part in parts if not part.startswith("%#@")]
            for category, expected in values.items():
                pattern = "^" + "(.*?)".join(re.escape(part) for part in static) + "$"
                match = re.match(pattern, expected)
                if not match or len(markers) != len(match.groups()):
                    raise RuntimeError(
                        f"reviewed plural template mismatch: {key or language}"
                    )
                captures = dict(zip(markers, match.groups()))
                for name, substitution in substitutions.items():
                    replacement = captures.get(name)
                    plural = substitution.get("variations", {}).get("plural", {})
                    if not isinstance(plural, dict) or not isinstance(replacement, str):
                        raise RuntimeError(
                            f"reviewed plural substitution mismatch: {key or language}"
                        )
                    variation = plural.get(category)
                    if not isinstance(variation, dict):
                        variation = {
                            "stringUnit": {"state": "translated", "value": replacement}
                        }
                        plural[category] = variation
                    updates.append((variation, replacement))
            for variation, replacement in updates:
                unit = variation.setdefault("stringUnit", {})
                unit["value"] = replacement
                unit["state"] = "translated"
            normalize_plural_substitutions(entry)
        elif not isinstance(direct, str):
            raise RuntimeError(f"reviewed plural template mismatch: {key or language}")
        return
    plural = localization.get("variations", {}).get("plural")
    if isinstance(plural, dict) and plural:
        for category, variation in plural.items():
            if category in values and isinstance(variation, dict):
                unit = variation.setdefault("stringUnit", {})
                unit["value"] = values[category]
                unit["state"] = "translated"
        for category, value in values.items():
            if category not in plural:
                plural[category] = {
                    "stringUnit": {"state": "translated", "value": value}
                }
        return
    localization.pop("stringUnit", None)
    localization.setdefault("variations", {}).setdefault("plural", {})
    for category, value in values.items():
        localization["variations"]["plural"][category] = {
            "stringUnit": {"state": "translated", "value": value}
        }


def prune_catalog(catalog: dict, managed_keys: set[str]) -> list[str]:
    strings = catalog.setdefault("strings", {})
    removed = sorted(set(strings).difference(managed_keys))
    for key in removed:
        del strings[key]
    return removed


def pruned_reviewed_translation_files(
    managed_keys: set[str],
    core_keys: set[str] | None = None,
) -> tuple[dict[Path, dict], dict[Path, list[str]]]:
    managed_keys = managed_keys | (core_keys or set())
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
        reviewed_translation = translations.get(key)
        expectation = reviewed_translation_expectation(
            key, source_value, reviewed_translation
        )
        if expectation is not None:
            chinese_value, english_value = expectation
            update_localization_string(entry, "zh-Hans", chinese_value)
            if isinstance(english_value, dict):
                update_localization_plural(entry, "en", english_value, key=key)
            else:
                update_localization_string(entry, "en", english_value)
            strings[key] = entry
            continue
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
        if expectation is None:
            raise RuntimeError(f"missing reviewed offline translation: {key}")
    for entry in strings.values():
        if isinstance(entry, dict):
            normalize_plural_substitutions(entry)
    return catalog


def catalog_entry(chinese_value: str, english_value: str | dict[str, str]) -> dict:
    english_localization: dict
    if isinstance(english_value, dict):
        english_localization = {
            "variations": {
                "plural": {
                    category: {
                        "stringUnit": {"state": "translated", "value": value}
                    }
                    for category, value in sorted(english_value.items())
                }
            }
        }
    else:
        english_localization = {
            "stringUnit": {"state": "translated", "value": english_value}
        }
    return {
        "localizations": {
            "en": english_localization,
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
    mode.add_argument(
        "--merge-reviewed-translations",
        action="store_true",
        help="Merge root-level reviewed translation fragments into the master dictionary and archive them.",
    )
    arguments = parser.parse_args()
    if arguments.merge_reviewed_translations:
        fragment_count, entry_count = merge_reviewed_translation_fragments()
        print(
            f"reviewed translations: merged and archived {fragment_count} fragment(s); "
            f"master dictionary contains {entry_count} entries"
        )
        return 0
    display_name_gaps = direct_display_name_localization_gaps()
    if display_name_gaps:
        print(
            f"ui-scoped localization catalog: {len(display_name_gaps)} "
            "direct displayName use(s) bypass semantic localization"
        )
        for gap in display_name_gaps[:20]:
            print(f"- {gap}")
        return 1
    compiler_extracted = extract_compiler_localizations()
    statically_extracted = dict(compiler_extracted)
    statically_extracted.update(extract_swiftui_strings())
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
    reviewed_translation_keys = set(extracted) | set(core_extracted)

    if arguments.check:
        translations = load_reviewed_translations()
        stale_catalog = stale_catalog_keys(catalog, set(extracted))
        stale_translations = stale_reviewed_translation_keys(translations, reviewed_translation_keys)
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
        failures += reviewed_translation_drift(
            catalog, registered_or_non_cjk, translations
        )
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
            f"ui-scoped localization catalog: {len(compiler_extracted)} compiler-extracted keys, "
            f"{len(statically_extracted)} combined static keys, "
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
            set(extracted), set(core_extracted)
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
        f"localization catalog: synchronized {len(compiler_extracted)} compiler-extracted keys "
        f"and {len(statically_extracted)} combined static keys "
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
