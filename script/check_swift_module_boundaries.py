#!/usr/bin/env python3
"""Validate the SwiftPM module graph and record deterministic boundary trends.

The checker intentionally treats the package manifest as the source of truth.  In
normal operation it asks SwiftPM for ``dump-package`` JSON; tests can provide the
same JSON through ``--dump-package-json`` without invoking Swift or the network.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
POLICY_VERSION = "swift-module-boundaries-v2"
SCHEMA_VERSION = "2"
TOOL_VERSION = "2"

GOVERNED_DEPENDENCIES: dict[str, set[str]] = {
    "PublishingCoreSupport": set(),
    "PublishingDomainContracts": set(),
    "PublishingMarkdownCore": {"PublishingCoreSupport"},
    "PublishingGitCore": {"PublishingCoreSupport", "PublishingDomainContracts"},
    "PublishingAICore": {"PublishingCoreSupport"},
    "PublishingKnowledgeCore": {"PublishingCoreSupport"},
    "PublishingWorkbenchCore": {
        "PublishingAICore",
        "PublishingCoreSupport",
        "PublishingDomainContracts",
        "PublishingGitCore",
        "PublishingKnowledgeCore",
        "PublishingMarkdownCore",
    },
    "PublishingMCPClient": {
        "PublishingAICore",
        "PublishingWorkbenchCore",
    },
    "BrowserExtensionProtocolSupport": set(),
    "PersonalSitePublisherMac": {
        "BrowserExtensionProtocolSupport",
        "PublishingGitCore",
        "PublishingMarkdownCore",
        "PublishingWorkbenchCore",
    },
}
EXPECTED_PRODUCTION_TARGET_TYPES = {
    "PublishingCoreSupport": "regular",
    "PublishingDomainContracts": "regular",
    "PublishingMarkdownCore": "regular",
    "PublishingGitCore": "regular",
    "PublishingAICore": "regular",
    "PublishingKnowledgeCore": "regular",
    "PublishingWorkbenchCore": "regular",
    "PublishingMCPClient": "regular",
    "BrowserExtensionProtocolSupport": "regular",
    "PersonalSitePublisherMac": "executable",
}
TEST_TARGET_DEPENDENCIES: dict[str, set[str]] = {
    "PublishingMarkdownCoreTests": {"PublishingCoreSupport", "PublishingMarkdownCore"},
    "PublishingGitCoreTests": {"PublishingDomainContracts", "PublishingGitCore"},
    "PublishingDomainContractsTests": {"PublishingDomainContracts"},
    "PublishingAICoreTests": {"PublishingAICore", "PublishingCoreSupport"},
    "PublishingCoreSupportTests": {"PublishingCoreSupport"},
    "PublishingKnowledgeCoreTests": {"PublishingKnowledgeCore"},
    "PublishingWorkbenchCoreTests": {
        "BrowserExtensionProtocolSupport",
        "PublishingAICore",
        "PublishingGitCore",
        "PublishingKnowledgeCore",
        "PublishingWorkbenchCore",
    },
    "PublishingMCPClientTests": {
        "PublishingAICore",
        "PublishingMCPClient",
        "PublishingWorkbenchCore",
    },
    "PersonalSitePublisherMacTests": {
        "BrowserExtensionProtocolSupport",
        "PersonalSitePublisherMac",
        "PublishingGitCore",
        "PublishingMarkdownCore",
        "PublishingWorkbenchCore",
    },
}
EXPECTED_PRODUCTS = {
    "PublishingMarkdownCore": {"type": "library", "targets": {"PublishingMarkdownCore"}},
    "PublishingGitCore": {"type": "library", "targets": {"PublishingGitCore"}},
    "PublishingAICore": {"type": "library", "targets": {"PublishingAICore"}},
    "PublishingKnowledgeCore": {"type": "library", "targets": {"PublishingKnowledgeCore"}},
    "PublishingWorkbenchCore": {"type": "library", "targets": {"PublishingWorkbenchCore"}},
    "PublishingMCPClient": {"type": "library", "targets": {"PublishingMCPClient"}},
    "PersonalSitePublisherMac": {"type": "executable", "targets": {"PersonalSitePublisherMac"}},
}
EXPECTED_EXTERNAL_PRODUCTS: dict[str, dict[str, str]] = {
    "PublishingCoreSupport": {},
    "PublishingDomainContracts": {},
    "PublishingMarkdownCore": {
        "SwiftTreeSitter": "swift-tree-sitter",
        "SwiftTreeSitterLayer": "swift-tree-sitter",
        "TreeSitterMarkdown": "tree-sitter-markdown",
    },
    "PublishingGitCore": {},
    "PublishingAICore": {},
    "PublishingKnowledgeCore": {},
    "PublishingWorkbenchCore": {},
    "PublishingMCPClient": {
        "MCP": "swift-sdk",
        "SystemPackage": "swift-system",
    },
    "BrowserExtensionProtocolSupport": {},
    "PersonalSitePublisherMac": {"Sparkle": "Sparkle"},
}
EXPECTED_EXTERNAL_PRODUCTS.update(
    {target_name: {} for target_name in TEST_TARGET_DEPENDENCIES}
)
LEAF_TARGETS = {
    "PublishingCoreSupport",
    "PublishingDomainContracts",
    "PublishingMarkdownCore",
    "PublishingGitCore",
    "PublishingAICore",
    "PublishingKnowledgeCore",
    "BrowserExtensionProtocolSupport",
}
LEAF_TEST_TARGETS = {
    f"{target_name}Tests"
    for target_name in LEAF_TARGETS
    if f"{target_name}Tests" in TEST_TARGET_DEPENDENCIES
}
CORE_SOURCE_TARGETS = (
    "PublishingCoreSupport",
    "PublishingDomainContracts",
    "PublishingMarkdownCore",
    "PublishingGitCore",
    "PublishingAICore",
    "PublishingKnowledgeCore",
    "PublishingWorkbenchCore",
    "PublishingMCPClient",
)
EXPECTED_EXPORTS = {
    "PublishingAICore",
    "PublishingCoreSupport",
    "PublishingDomainContracts",
    "PublishingGitCore",
    "PublishingKnowledgeCore",
    "PublishingMarkdownCore",
}
TARGET_TYPES = {"regular", "executable", "test"}
EXPORT_DECLARATION = re.compile(
    r"^\s*@_exported\s+import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$"
)
IMPORT_DECLARATION = re.compile(
    r"^\s*(?:(?:@testable|@_exported)\s+)*import\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)


class BoundaryError(ValueError):
    """A fail-closed package or source-boundary violation."""


def _require_object(value: Any, description: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise BoundaryError(f"{description} must be an object")
    return value


def _require_non_empty_string(value: Any, description: str) -> str:
    if not isinstance(value, str) or not value:
        raise BoundaryError(f"{description} must be a non-empty string")
    return value


def _dependency_name(value: Any, kind: str, target_name: str) -> str:
    """Read the first name from SwiftPM's dependency enum representation."""

    if isinstance(value, str):
        return _require_non_empty_string(value, f"{target_name} {kind} dependency")
    if not isinstance(value, list) or not value:
        raise BoundaryError(
            f"{target_name} dependency {kind} has an unsupported payload"
        )
    name = _require_non_empty_string(value[0], f"{target_name} {kind} dependency name")
    # The remaining fields are SwiftPM's package/condition metadata.  They are
    # intentionally ignored after validating that the JSON value is not a
    # malformed object or array with no stable first name.
    return name


def _parse_dependencies(
    target: dict[str, Any],
) -> tuple[set[str], dict[str, str | None]]:
    target_name = _require_non_empty_string(target.get("name"), "target name")
    raw_dependencies = target.get("dependencies")
    if not isinstance(raw_dependencies, list):
        raise BoundaryError(f"target {target_name} dependencies must be a list")

    internal: set[str] = set()
    external: dict[str, str | None] = {}
    for index, raw_dependency in enumerate(raw_dependencies):
        dependency = _require_object(
            raw_dependency, f"target {target_name} dependency {index}"
        )
        if len(dependency) != 1:
            raise BoundaryError(
                f"target {target_name} dependency {index} must have one variant"
            )
        kind, payload = next(iter(dependency.items()))
        if kind == "product":
            if not isinstance(payload, list) or not payload:
                raise BoundaryError(
                    f"target {target_name} dependency {kind} has an unsupported payload"
                )
            product_name = _require_non_empty_string(
                payload[0], f"{target_name} product dependency name"
            )
            package_name: str | None = None
            if len(payload) > 1 and payload[1] is not None:
                package_name = _require_non_empty_string(
                    payload[1], f"{target_name} product dependency package"
                )
            if product_name in external:
                raise BoundaryError(
                    f"target {target_name} declares external product more than once: "
                    f"{product_name}"
                )
            external[product_name] = package_name
            continue
        if kind in {"byName", "target"}:
            internal.add(_dependency_name(payload, kind, target_name))
            continue
        raise BoundaryError(
            f"target {target_name} dependency {index} has unknown variant {kind!r}"
        )
    return internal, external


def _swift_language_mode_is_six(value: Any, target_name: str) -> bool:
    if isinstance(value, str):
        return value == "6"
    if isinstance(value, dict):
        if set(value) != {"_0"}:
            raise BoundaryError(
                f"target {target_name} has malformed swiftLanguageMode payload"
            )
        return value["_0"] == "6"
    raise BoundaryError(f"target {target_name} has malformed swiftLanguageMode")


def _target_uses_swift_six(target: dict[str, Any]) -> bool:
    target_name = _require_non_empty_string(target.get("name"), "target name")
    settings = target.get("settings")
    if not isinstance(settings, list):
        raise BoundaryError(f"target {target_name} settings must be a list")
    swift_language_modes: list[bool] = []
    for index, setting_value in enumerate(settings):
        setting = _require_object(
            setting_value, f"target {target_name} setting {index}"
        )
        kind = setting.get("kind")
        if kind is None:
            raise BoundaryError(f"target {target_name} setting {index} has no kind")
        kind_object = _require_object(
            kind, f"target {target_name} setting {index} kind"
        )
        if len(kind_object) != 1:
            raise BoundaryError(
                f"target {target_name} setting {index} kind must have one variant"
            )
        if "swiftLanguageMode" in kind_object:
            if setting.get("tool") != "swift":
                raise BoundaryError(
                    f"target {target_name} swiftLanguageMode setting must use the swift tool"
                )
            swift_language_modes.append(
                _swift_language_mode_is_six(
                    kind_object["swiftLanguageMode"], target_name
                )
            )
    if len(swift_language_modes) > 1:
        raise BoundaryError(
            f"target {target_name} declares swiftLanguageMode more than once"
        )
    return swift_language_modes == [True]


def _topological_order(target_names: list[str], edges: dict[str, set[str]]) -> list[str]:
    state: dict[str, int] = {}
    order: list[str] = []

    def visit(target_name: str) -> None:
        current_state = state.get(target_name, 0)
        if current_state == 1:
            raise BoundaryError(f"internal target dependency cycle includes {target_name}")
        if current_state == 2:
            return
        state[target_name] = 1
        for dependency in sorted(edges[target_name]):
            visit(dependency)
        state[target_name] = 2
        order.append(target_name)

    for target_name in sorted(target_names):
        visit(target_name)
    return order


def _strip_swift_comments(source: str) -> str:
    """Remove line and nested block comments while retaining line boundaries."""

    output: list[str] = []
    index = 0
    block_depth = 0
    in_line_comment = False
    while index < len(source):
        character = source[index]
        next_character = source[index + 1] if index + 1 < len(source) else ""
        if in_line_comment:
            if character == "\n":
                in_line_comment = False
                output.append(character)
            else:
                output.append(" ")
            index += 1
            continue
        if block_depth:
            if character == "/" and next_character == "*":
                block_depth += 1
                output.extend((" ", " "))
                index += 2
                continue
            if character == "*" and next_character == "/":
                block_depth -= 1
                output.extend((" ", " "))
                index += 2
                continue
            output.append("\n" if character == "\n" else " ")
            index += 1
            continue
        if character == "/" and next_character == "/":
            in_line_comment = True
            output.extend((" ", " "))
            index += 2
            continue
        if character == "/" and next_character == "*":
            block_depth = 1
            output.extend((" ", " "))
            index += 2
            continue
        output.append(character)
        index += 1
    if block_depth:
        raise BoundaryError("umbrella source contains an unterminated block comment")
    return "".join(output)


def _strip_comments_for_import_scan(source: str) -> str:
    """Mask comments and string literals without mistaking ``*/*`` for a comment."""

    output: list[str] = []
    index = 0
    block_depth = 0
    in_line_comment = False
    string_terminator: str | None = None
    while index < len(source):
        if string_terminator is not None:
            if string_terminator == '"' and source[index] == "\\":
                output.append(" ")
                if index + 1 < len(source):
                    output.append("\n" if source[index + 1] == "\n" else " ")
                    index += 2
                else:
                    index += 1
                continue
            if source.startswith(string_terminator, index):
                output.extend(" " for _ in string_terminator)
                index += len(string_terminator)
                string_terminator = None
                continue
            character = source[index]
            output.append("\n" if character == "\n" else " ")
            index += 1
            continue
        character = source[index]
        next_character = source[index + 1] if index + 1 < len(source) else ""
        if in_line_comment:
            if character == "\n":
                in_line_comment = False
                output.append(character)
            else:
                output.append(" ")
            index += 1
            continue
        if block_depth:
            if character == "/" and next_character == "*":
                block_depth += 1
                output.extend((" ", " "))
                index += 2
                continue
            if character == "*" and next_character == "/":
                block_depth -= 1
                output.extend((" ", " "))
                index += 2
                continue
            output.append("\n" if character == "\n" else " ")
            index += 1
            continue
        if character == "/" and next_character == "/":
            in_line_comment = True
            output.extend((" ", " "))
            index += 2
            continue
        if character == "/" and next_character == "*":
            block_depth = 1
            output.extend((" ", " "))
            index += 2
            continue
        if character == "#":
            hash_count = 0
            while index + hash_count < len(source) and source[index + hash_count] == "#":
                hash_count += 1
            if index + hash_count < len(source) and source[index + hash_count] == '"':
                string_terminator = '"' + ("#" * hash_count)
                output.extend(" " for _ in range(hash_count + 1))
                index += hash_count + 1
                continue
        if source.startswith('"""', index):
            string_terminator = '"""'
            output.extend((" ", " ", " "))
            index += 3
            continue
        if character == '"':
            string_terminator = '"'
            output.append(" ")
            index += 1
            continue
        output.append(character)
        index += 1
    if block_depth:
        raise BoundaryError("Swift source contains an unterminated block comment")
    return "".join(output)


def _product_type(value: Any, product_name: str) -> str:
    product_type = _require_object(value, f"product {product_name} type")
    if len(product_type) != 1:
        raise BoundaryError(f"product {product_name} type must have one variant")
    kind = next(iter(product_type))
    if kind not in {"library", "executable"}:
        raise BoundaryError(f"product {product_name} has unknown type {kind!r}")
    return kind


def _validate_products(
    package_payload: dict[str, Any],
    target_names: set[str],
) -> list[dict[str, Any]]:
    raw_products = package_payload.get("products")
    if not isinstance(raw_products, list):
        raise BoundaryError("dump-package products must be a list")
    products_by_name: dict[str, dict[str, Any]] = {}
    for index, raw_product in enumerate(raw_products):
        product = _require_object(raw_product, f"product {index}")
        product_name = _require_non_empty_string(
            product.get("name"), f"product {index} name"
        )
        if product_name in products_by_name:
            raise BoundaryError(f"duplicate product name: {product_name}")
        product_targets = product.get("targets")
        if not isinstance(product_targets, list) or not product_targets:
            raise BoundaryError(f"product {product_name} targets must be a non-empty list")
        normalized_targets: list[str] = []
        for target_name in product_targets:
            normalized_targets.append(
                _require_non_empty_string(
                    target_name, f"product {product_name} target"
                )
            )
        if len(normalized_targets) != len(set(normalized_targets)):
            raise BoundaryError(f"product {product_name} targets contain duplicates")
        products_by_name[product_name] = {
            "type": _product_type(product.get("type"), product_name),
            "targets": set(normalized_targets),
        }

    expected_names = set(EXPECTED_PRODUCTS)
    actual_names = set(products_by_name)
    missing = sorted(expected_names - actual_names)
    extra = sorted(actual_names - expected_names)
    if missing or extra:
        details: list[str] = []
        if missing:
            details.append(f"missing={missing}")
        if extra:
            details.append(f"extra={extra}")
        raise BoundaryError("products violate exact allowlist: " + ", ".join(details))

    normalized: list[dict[str, Any]] = []
    for product_name in sorted(EXPECTED_PRODUCTS):
        expected = EXPECTED_PRODUCTS[product_name]
        actual = products_by_name[product_name]
        if actual["type"] != expected["type"] or actual["targets"] != expected["targets"]:
            raise BoundaryError(
                f"product {product_name} mapping differs from policy: "
                f"expected={{'type': {expected['type']!r}, 'targets': {sorted(expected['targets'])!r}}}, "
                f"actual={{'type': {actual['type']!r}, 'targets': {sorted(actual['targets'])!r}}}"
            )
        unknown_targets = sorted(actual["targets"] - target_names)
        if unknown_targets:
            raise BoundaryError(
                f"product {product_name} references unknown target(s): {unknown_targets}"
            )
        normalized.append(
            {
                "name": product_name,
                "type": actual["type"],
                "targets": sorted(actual["targets"]),
            }
        )
    return normalized


def _source_imports(source: str) -> list[str]:
    stripped = _strip_comments_for_import_scan(source)
    imports: list[str] = []
    for line in stripped.splitlines():
        match = IMPORT_DECLARATION.match(line)
        if match is not None:
            imports.append(match.group(1))
    return imports


def _read_swift_imports(path: Path) -> list[str]:
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise BoundaryError(f"cannot read Swift source {path}: {error}") from error
    return _source_imports(source)


def _consumer_metrics(
    package_root: Path,
    target_names: set[str],
    edges: dict[str, set[str]],
    *,
    enforce_umbrella_retirement: bool,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Validate source imports and emit deterministic umbrella-consumer trends."""

    leaf_api_names = set(EXPECTED_EXPORTS)
    edge_counts: dict[tuple[str, str, str], dict[str, int]] = {}
    metrics: dict[str, dict[str, Any]] = {}
    for scope in ("Sources", "Tests"):
        scope_root = package_root / scope
        scope_file_count = 0
        workbench_file_count = 0
        workbench_import_count = 0
        leaf_file_count = 0
        leaf_import_count = 0
        target_metrics: list[dict[str, Any]] = []
        if scope_root.is_dir():
            for target_name in sorted(target_names):
                target_root = scope_root / target_name
                if not target_root.is_dir():
                    continue
                target_file_count = 0
                target_workbench_file_count = 0
                target_leaf_file_count = 0
                for path in sorted(target_root.rglob("*.swift")):
                    if not path.is_file():
                        continue
                    target_file_count += 1
                    scope_file_count += 1
                    imports = _read_swift_imports(path)
                    imported_internal = set(imports) & target_names
                    missing_dependencies = sorted(
                        imported
                        for imported in imported_internal
                        if imported != target_name and imported not in edges[target_name]
                    )
                    if missing_dependencies:
                        relative_path = path.relative_to(package_root).as_posix()
                        raise BoundaryError(
                            f"{relative_path} imports internal module(s) without direct "
                            f"target dependency for {target_name}: {missing_dependencies}"
                        )
                    workbench_occurrences = imports.count("PublishingWorkbenchCore")
                    leaf_occurrences = sum(
                        1 for imported in imports if imported in leaf_api_names
                    )
                    if workbench_occurrences:
                        target_workbench_file_count += 1
                        workbench_file_count += 1
                        workbench_import_count += workbench_occurrences
                    if leaf_occurrences:
                        target_leaf_file_count += 1
                        leaf_file_count += 1
                        leaf_import_count += leaf_occurrences
                    for imported in sorted(imported_internal):
                        key = (scope, target_name, imported)
                        counts = edge_counts.setdefault(
                            key, {"fileCount": 0, "importCount": 0}
                        )
                        counts["fileCount"] += 1
                        counts["importCount"] += imports.count(imported)
                target_metrics.append(
                    {
                        "target": target_name,
                        "swiftFileCount": target_file_count,
                        "workbenchImportFileCount": target_workbench_file_count,
                        "leafAPIImportFileCount": target_leaf_file_count,
                    }
                )
        metrics[scope] = {
            "swiftFileCount": scope_file_count,
            "workbenchImportFileCount": workbench_file_count,
            "workbenchImportCount": workbench_import_count,
            "leafAPIImportFileCount": leaf_file_count,
            "leafAPIImportCount": leaf_import_count,
            "targetMetrics": target_metrics,
        }

    if enforce_umbrella_retirement:
        total_workbench_imports = sum(
            value["workbenchImportCount"] for value in metrics.values()
        )
        if total_workbench_imports:
            raise BoundaryError(
                "umbrella retirement enforcement failed: "
                f"{total_workbench_imports} PublishingWorkbenchCore import(s) remain"
            )

    import_edges = [
        {
            "scope": scope,
            "from": target_name,
            "to": imported,
            "fileCount": counts["fileCount"],
            "importCount": counts["importCount"],
        }
        for (scope, target_name, imported), counts in sorted(edge_counts.items())
    ]
    return metrics, import_edges


def _validate_umbrella_exports(package_root: Path) -> list[str]:
    path = (
        package_root
        / "Sources"
        / "PublishingWorkbenchCore"
        / "Support"
        / "PublishingCoreModuleExports.swift"
    )
    if not path.is_file():
        raise BoundaryError(f"missing compatibility umbrella source: {path}")
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise BoundaryError(f"cannot read compatibility umbrella source: {error}") from error
    source_without_comments = _strip_swift_comments(source)
    exports: list[str] = []
    for line_number, line in enumerate(source_without_comments.splitlines(), start=1):
        if "@_exported" not in line:
            continue
        match = EXPORT_DECLARATION.fullmatch(line)
        if match is None:
            raise BoundaryError(
                f"malformed compatibility umbrella export on line {line_number}"
            )
        exports.append(match.group(1))
    counts: dict[str, int] = {}
    for export in exports:
        counts[export] = counts.get(export, 0) + 1
    missing = sorted(EXPECTED_EXPORTS - counts.keys())
    extras = sorted(set(counts) - EXPECTED_EXPORTS)
    duplicates = sorted(name for name, count in counts.items() if count != 1)
    if missing or extras or duplicates or len(exports) != len(EXPECTED_EXPORTS):
        details: list[str] = []
        if missing:
            details.append(f"missing={missing}")
        if extras:
            details.append(f"extra={extras}")
        if duplicates:
            details.append(f"duplicate={duplicates}")
        raise BoundaryError("compatibility umbrella exports violate exact allowlist: " + ", ".join(details))
    return sorted(exports)


def _sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _source_metrics(package_root: Path, target_name: str) -> dict[str, Any]:
    source_directory = package_root / "Sources" / target_name
    if not source_directory.is_dir():
        raise BoundaryError(f"missing governed source directory: {source_directory}")
    swift_files = sorted(
        path for path in source_directory.rglob("*.swift") if path.is_file()
    )
    physical_lines = 0
    nonblank_lines = 0
    digest = hashlib.sha256()
    for path in swift_files:
        try:
            data = path.read_bytes()
            text = data.decode("utf-8")
        except (OSError, UnicodeError) as error:
            raise BoundaryError(f"cannot read Swift source {path}: {error}") from error
        relative_path = path.relative_to(source_directory).as_posix()
        digest.update(relative_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(data)
        digest.update(b"\0")
        physical_lines += 0 if not text else text.count("\n") + (0 if text.endswith("\n") else 1)
        nonblank_lines += sum(1 for line in text.splitlines() if line.strip())
    return {
        "swiftFileCount": len(swift_files),
        "physicalLineCount": physical_lines,
        "nonblankLineCount": nonblank_lines,
        "sourceDigest": digest.hexdigest(),
    }


def analyze_package(
    package_payload: dict[str, Any],
    package_root: Path,
    *,
    enforce_umbrella_retirement: bool = False,
) -> dict[str, Any]:
    payload = _require_object(package_payload, "dump-package payload")
    raw_targets = payload.get("targets")
    if not isinstance(raw_targets, list) or not raw_targets:
        raise BoundaryError("dump-package payload targets must be a non-empty list")

    targets_by_name: dict[str, dict[str, Any]] = {}
    target_types: dict[str, str] = {}
    swift_six_targets: set[str] = set()
    edges: dict[str, set[str]] = {}
    external_edges: dict[str, dict[str, str | None]] = {}
    for index, raw_target in enumerate(raw_targets):
        target = _require_object(raw_target, f"target {index}")
        target_name = _require_non_empty_string(target.get("name"), f"target {index} name")
        if target_name in targets_by_name:
            raise BoundaryError(f"duplicate target name: {target_name}")
        target_type = _require_non_empty_string(
            target.get("type"), f"target {target_name} type"
        )
        if target_type not in TARGET_TYPES:
            raise BoundaryError(f"target {target_name} has unknown type {target_type!r}")
        targets_by_name[target_name] = target
        target_types[target_name] = target_type
        swift_six_targets.add(target_name) if _target_uses_swift_six(target) else None
        edges[target_name], external_edges[target_name] = _parse_dependencies(target)

    target_names = sorted(targets_by_name)
    for target_name in target_names:
        unknown = sorted(edges[target_name] - targets_by_name.keys())
        if unknown:
            raise BoundaryError(
                f"target {target_name} references unknown internal target(s): {unknown}"
            )
        if target_name not in swift_six_targets:
            raise BoundaryError(f"target {target_name} is not explicitly Swift language mode 6")
    topological_order = _topological_order(target_names, edges)

    expected_production_names = set(EXPECTED_PRODUCTION_TARGET_TYPES)
    actual_production_names = {
        name for name, target_type in target_types.items() if target_type != "test"
    }
    missing_production = sorted(expected_production_names - actual_production_names)
    extra_production = sorted(actual_production_names - expected_production_names)
    if missing_production or extra_production:
        details: list[str] = []
        if missing_production:
            details.append(f"missing={missing_production}")
        if extra_production:
            details.append(f"extra={extra_production}")
        raise BoundaryError("production targets violate exact allowlist: " + ", ".join(details))
    for target_name, expected_type in EXPECTED_PRODUCTION_TARGET_TYPES.items():
        actual_type = target_types[target_name]
        if actual_type != expected_type:
            raise BoundaryError(
                f"target {target_name} type differs from policy: "
                f"expected={expected_type}, actual={actual_type}"
            )

    expected_test_names = set(TEST_TARGET_DEPENDENCIES)
    actual_test_names = {
        name for name, target_type in target_types.items() if target_type == "test"
    }
    missing_tests = sorted(expected_test_names - actual_test_names)
    extra_tests = sorted(actual_test_names - expected_test_names)
    if missing_tests or extra_tests:
        details = []
        if missing_tests:
            details.append(f"missing={missing_tests}")
        if extra_tests:
            details.append(f"extra={extra_tests}")
        raise BoundaryError("test targets violate exact allowlist: " + ", ".join(details))

    reverse_leaf_edges = sorted(
        target_name
        for target_name in LEAF_TARGETS | LEAF_TEST_TARGETS
        if "PublishingWorkbenchCore" in edges[target_name]
    )
    if reverse_leaf_edges:
        raise BoundaryError(
            f"leaf target(s) must not depend on PublishingWorkbenchCore: {reverse_leaf_edges}"
        )

    for target_name, expected_dependencies in GOVERNED_DEPENDENCIES.items():
        actual_dependencies = edges[target_name]
        if actual_dependencies != expected_dependencies:
            raise BoundaryError(
                f"target {target_name} dependencies differ from policy: "
                f"expected={sorted(expected_dependencies)}, actual={sorted(actual_dependencies)}"
            )
    for target_name, expected_dependencies in TEST_TARGET_DEPENDENCIES.items():
        actual_dependencies = edges[target_name]
        if actual_dependencies != expected_dependencies:
            raise BoundaryError(
                f"test target {target_name} dependencies differ from policy: "
                f"expected={sorted(expected_dependencies)}, actual={sorted(actual_dependencies)}"
            )

    expected_external_targets = set(EXPECTED_EXTERNAL_PRODUCTS)
    actual_external_targets = set(external_edges)
    if actual_external_targets != expected_external_targets:
        raise BoundaryError(
            "external product policy missing target coverage: "
            f"missing={sorted(expected_external_targets - actual_external_targets)}, "
            f"extra={sorted(actual_external_targets - expected_external_targets)}"
        )
    for target_name, expected_products in EXPECTED_EXTERNAL_PRODUCTS.items():
        actual_products = external_edges[target_name]
        if actual_products != expected_products:
            raise BoundaryError(
                f"target {target_name} external products differ from policy: "
                f"expected={sorted(expected_products.items())}, "
                f"actual={sorted(actual_products.items())}"
            )
    products = _validate_products(package_payload, set(target_names))
    exports = _validate_umbrella_exports(package_root)
    source_metrics = {
        target_name: _source_metrics(package_root, target_name)
        for target_name in CORE_SOURCE_TARGETS
    }
    umbrella_metrics, source_import_edges = _consumer_metrics(
        package_root,
        set(target_names),
        edges,
        enforce_umbrella_retirement=enforce_umbrella_retirement,
    )
    internal_edges = [
        {"from": target_name, "to": dependency}
        for target_name in target_names
        for dependency in sorted(edges[target_name])
    ]
    external_product_edges = [
        {
            "from": target_name,
            "product": product_name,
            "package": package_name,
        }
        for target_name in target_names
        for product_name, package_name in sorted(external_edges[target_name].items())
    ]
    type_counts: dict[str, int] = {}
    for target_type in target_types.values():
        type_counts[target_type] = type_counts.get(target_type, 0) + 1
    package_name = payload.get("name")
    if not isinstance(package_name, str) or not package_name:
        package_name = package_root.name
    return {
        "status": "passed",
        "schemaVersion": SCHEMA_VERSION,
        "policyVersion": POLICY_VERSION,
        "tool": {"name": "check_swift_module_boundaries.py", "version": TOOL_VERSION},
        "package": {
            "name": package_name,
            "toolsVersion": payload.get("toolsVersion"),
            "manifest": "Package.swift",
        },
        "targetTypeCounts": {key: type_counts[key] for key in sorted(type_counts)},
        "products": products,
        "targets": target_names,
        "swiftLanguageMode6Targets": sorted(swift_six_targets),
        "internalEdges": internal_edges,
        "externalProductEdges": external_product_edges,
        "topologicalOrder": topological_order,
        "compatibilityUmbrellaExports": exports,
        "compatibilityUmbrellaConsumerMetrics": umbrella_metrics,
        "sourceImportEdges": source_import_edges,
        "umbrellaRetirement": {
            "enforced": enforce_umbrella_retirement,
            "remainingWorkbenchImportCount": sum(
                metric["workbenchImportCount"] for metric in umbrella_metrics.values()
            ),
        },
        "manifestDigests": {
            "Package.swift": _sha256_file(package_root / "Package.swift"),
            "Package.resolved": _sha256_file(package_root / "Package.resolved"),
        },
        "coreSourceMetrics": source_metrics,
    }


def _run_dump_package(package_root: Path) -> dict[str, Any]:
    swift = os.environ.get("SWIFT_BIN", "swift")
    with tempfile.TemporaryDirectory(prefix="swift-module-boundaries-") as temporary:
        isolated_root = Path(temporary)
        cache_root = isolated_root / "cache"
        xdg_cache = isolated_root / "xdg-cache"
        clang_cache = isolated_root / "clang-module-cache"
        swift_cache = isolated_root / "swift-module-cache"
        config_path = isolated_root / "swiftpm-configuration"
        security_path = isolated_root / "swiftpm-security"
        scratch_path = isolated_root / "scratch"
        for directory in (
            cache_root,
            xdg_cache,
            clang_cache,
            swift_cache,
            config_path,
            security_path,
            scratch_path,
        ):
            directory.mkdir(parents=True, exist_ok=True)
        environment = os.environ.copy()
        environment["XDG_CACHE_HOME"] = str(xdg_cache)
        environment["CLANG_MODULE_CACHE_PATH"] = str(clang_cache)
        environment["SWIFT_MODULE_CACHE_PATH"] = str(swift_cache)
        command = [
            swift,
            "package",
            "--disable-sandbox",
            "--package-path",
            str(package_root),
            "--scratch-path",
            str(scratch_path),
            "--cache-path",
            str(cache_root),
            "--config-path",
            str(config_path),
            "--security-path",
            str(security_path),
            "dump-package",
        ]
        completed = subprocess.run(
            command,
            cwd=package_root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        if completed.returncode != 0:
            details = completed.stderr.strip() or completed.stdout.strip()
            if len(details) > 1200:
                details = details[-1200:]
            raise BoundaryError(
                f"swift package dump-package failed with status {completed.returncode}: {details}"
            )
        try:
            decoded = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise BoundaryError(f"swift package dump-package returned invalid JSON: {error}") from error
        return _require_object(decoded, "swift package dump-package JSON")


def _write_report(report_path: Path, report: dict[str, Any]) -> None:
    try:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=report_path.parent,
                prefix=f".{report_path.name}.",
                suffix=".tmp",
                delete=False,
            ) as temporary:
                temporary_path = Path(temporary.name)
                json.dump(report, temporary, ensure_ascii=False, indent=2, sort_keys=True)
                temporary.write("\n")
            os.replace(temporary_path, report_path)
            temporary_path = None
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
    except OSError as error:
        raise BoundaryError(f"cannot write boundary report {report_path}: {error}") from error


def _load_workbench_import_maximums(path: Path) -> dict[str, int]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BoundaryError(f"cannot read quality baseline {path}: {error}") from error
    module_maximums = payload.get("swiftModuleBoundaryMaximums")
    if not isinstance(module_maximums, dict):
        raise BoundaryError("quality baseline must define swiftModuleBoundaryMaximums")
    imports = module_maximums.get("publishingWorkbenchCoreImportsByScope")
    if not isinstance(imports, dict) or set(imports) != {"Sources", "Tests"}:
        raise BoundaryError(
            "quality baseline PublishingWorkbenchCore import maximums must define Sources and Tests"
        )
    result: dict[str, int] = {}
    for scope in ("Sources", "Tests"):
        value = imports.get(scope)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise BoundaryError(
                f"quality baseline PublishingWorkbenchCore import maximum for {scope} must be non-negative"
            )
        result[scope] = value
    return result


def _enforce_workbench_import_maximums(
    report: dict[str, Any],
    maximums: dict[str, int],
) -> None:
    metrics = report["compatibilityUmbrellaConsumerMetrics"]
    violations: list[str] = []
    for scope in ("Sources", "Tests"):
        actual = metrics[scope]["workbenchImportCount"]
        maximum = maximums[scope]
        if actual > maximum:
            violations.append(f"{scope} {actual}>{maximum}")
    if violations:
        raise BoundaryError(
            "PublishingWorkbenchCore compatibility-import maximum exceeded: "
            + "; ".join(violations)
        )
    report["umbrellaRetirement"]["maximumsEnforced"] = dict(maximums)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path, default=ROOT)
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--dump-package-json", type=Path, default=None)
    parser.add_argument(
        "--quality-baseline",
        type=Path,
        default=None,
        help="enforce progressive PublishingWorkbenchCore import maximums from this baseline",
    )
    parser.add_argument(
        "--enforce-umbrella-retirement",
        action="store_true",
        help="fail while any source or test still imports PublishingWorkbenchCore",
    )
    args = parser.parse_args(argv)
    package_root = args.package_root.resolve()
    report_path = (
        args.report.resolve()
        if args.report is not None
        else package_root / ".build" / "swift-module-boundaries.json"
    )
    try:
        if not package_root.is_dir():
            raise BoundaryError(f"package root is not a directory: {package_root}")
        if args.dump_package_json is None:
            package_payload = _run_dump_package(package_root)
        else:
            dump_path = args.dump_package_json.resolve()
            try:
                package_payload = json.loads(dump_path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as error:
                raise BoundaryError(f"cannot read dump-package fixture {dump_path}: {error}") from error
        report = analyze_package(
            package_payload,
            package_root,
            enforce_umbrella_retirement=args.enforce_umbrella_retirement,
        )
        if args.quality_baseline is not None:
            baseline_path = (
                args.quality_baseline.resolve()
                if args.quality_baseline.is_absolute()
                else (package_root / args.quality_baseline).resolve()
            )
            _enforce_workbench_import_maximums(
                report,
                _load_workbench_import_maximums(baseline_path),
            )
        _write_report(report_path, report)
    except (BoundaryError, OSError) as error:
        print(f"swift module boundaries: {error}", file=sys.stderr)
        return 1
    print(
        "swift module boundaries: passed "
        f"({len(report['targets'])} targets, {len(report['internalEdges'])} internal edges; "
        f"report {report_path})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
