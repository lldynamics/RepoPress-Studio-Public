#!/usr/bin/env python3
"""Validate the versioned RepoPress contract schemas and golden fixtures.

This module is intentionally a repository gate rather than a runtime library.  It
only reads the contract tree, emits deterministic diagnostics, and exits non-zero
when a contract or fixture is not self-consistent.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from urllib.parse import urljoin
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any, Iterable, Mapping, Sequence

try:
    from jsonschema import Draft202012Validator
except ImportError:  # pragma: no cover - exercised by a missing dependency, not tests
    Draft202012Validator = None  # type: ignore[assignment,misc]

try:
    from referencing import Registry, Resource
except ImportError:  # pragma: no cover - jsonschema declares this dependency
    Registry = None  # type: ignore[assignment,misc]
    Resource = None  # type: ignore[assignment,misc]


CAPABILITIES: tuple[str, ...] = (
    "repository-endpoint",
    "front-matter-document",
    "publish-conflict-diff",
)

CAPABILITY_SCHEMAS: Mapping[str, str] = {
    "repository-endpoint": "repository-endpoint.schema.json",
    "front-matter-document": "front-matter-document.schema.json",
    "publish-conflict-diff": "publish-conflict-diff.schema.json",
}

REQUIRED_SCHEMA_NAMES: tuple[str, ...] = (
    "fixture-case.schema.json",
    "fixture-manifest.schema.json",
    *CAPABILITY_SCHEMAS.values(),
)

_WINDOWS_DRIVE = re.compile(r"^[A-Za-z]:")


class _DuplicateKey(ValueError):
    """Raised when a JSON object repeats a key."""


def _pairs_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKey(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_nonfinite(value: str) -> None:
    raise ValueError(f"non-finite JSON number {value}")


def _canonical_json(value: Any) -> str:
    """Return a stable, strict JSON representation for repeatability checks."""

    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        indent=2,
        separators=(",", ": "),
    ) + "\n"


def _load_json(path: Path, errors: list[str]) -> Any | None:
    """Read one JSON file with the repository's byte-level hygiene rules."""

    label = path.as_posix()
    try:
        raw = path.read_bytes()
    except OSError as exc:
        errors.append(f"{label}: cannot read file ({exc})")
        return None

    if raw.startswith(b"\xef\xbb\xbf"):
        errors.append(f"{label}: UTF-8 BOM is not allowed")
    if b"\r" in raw:
        errors.append(f"{label}: only LF line endings are allowed")
    if not raw.endswith(b"\n"):
        errors.append(f"{label}: file must end with exactly one LF")
    elif raw.endswith(b"\n\n"):
        errors.append(f"{label}: file must end with exactly one LF")

    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        errors.append(f"{label}: file is not valid UTF-8 ({exc})")
        return None

    try:
        value = json.loads(
            text,
            object_pairs_hook=_pairs_without_duplicates,
            parse_constant=_reject_nonfinite,
        )
    except (ValueError, json.JSONDecodeError) as exc:
        errors.append(f"{label}: invalid JSON ({exc})")
        return None

    # A second parse/normalization cycle must produce the exact same canonical
    # value.  This catches duplicate keys and non-standard numeric values while
    # permitting human-readable pretty-printed fixture files.
    try:
        canonical = _canonical_json(value)
        normalized = json.loads(
            canonical,
            object_pairs_hook=_pairs_without_duplicates,
            parse_constant=_reject_nonfinite,
        )
        if _canonical_json(normalized) != canonical:
            errors.append(f"{label}: JSON normalization is not repeatable")
        canonical_bytes = canonical.encode("utf-8")
        if raw != canonical_bytes:
            errors.append(f"{label}: JSON is not in canonical form")
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        errors.append(f"{label}: JSON normalization failed ({exc})")

    return value


def _display_path(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def _schema_errors(schema: Any, schema_path: Path) -> list[str]:
    errors: list[str] = []
    if not isinstance(schema, dict):
        return [f"{schema_path.as_posix()}: schema root must be an object"]
    if Draft202012Validator is None:
        return ["jsonschema is required; install requirements-contracts.txt"]
    try:
        Draft202012Validator.check_schema(schema)
    except Exception as exc:  # jsonschema uses several concrete SchemaError classes
        errors.append(f"{schema_path.as_posix()}: invalid Draft 2020-12 schema ({exc})")
    return errors


def _format_jsonschema_error(error: Any, label: str) -> str:
    path = ".".join(str(part) for part in error.absolute_path)
    suffix = f" at {path}" if path else ""
    return f"{label}: schema validation failed{suffix}: {error.message}"


def _validate_with_schema(
    value: Any,
    schema: Any,
    label: str,
    registry: Any = None,
    base_uri: str | None = None,
) -> list[str]:
    if Draft202012Validator is None:
        return ["jsonschema is required; install requirements-contracts.txt"]
    try:
        schema_for_validation = schema
        if registry is not None and base_uri and isinstance(schema, dict) and "$id" not in schema:
            # A schema without an $id has no base for a relative $ref.  Give the
            # in-memory validation copy the source file URI without changing the
            # repository file itself.
            schema_for_validation = dict(schema)
            schema_for_validation["$id"] = base_uri
        if registry is not None:
            validator = Draft202012Validator(schema_for_validation, registry=registry)
        else:
            validator = Draft202012Validator(schema)
    except Exception as exc:
        return [f"{label}: schema validator setup failed: {exc}"]
    try:
        validation_errors = list(validator.iter_errors(value))
    except Exception as exc:
        return [f"{label}: schema validation could not resolve a reference: {exc}"]
    return [
        _format_jsonschema_error(error, label)
        for error in sorted(
            validation_errors,
            key=lambda item: (tuple(str(part) for part in item.absolute_path), item.message),
        )
    ]


def _build_schema_registry(schemas: Mapping[str, Any], schemas_root: Path) -> tuple[Any, dict[str, Any]]:
    """Register every schema by file URI and declared ``$id`` for cross-file refs."""

    store: dict[str, Any] = {}
    if Registry is None or Resource is None:
        return None, store
    registry = Registry()
    for name, schema in sorted(schemas.items()):
        path_uri = (schemas_root / name).resolve().as_uri()
        try:
            resource = Resource.from_contents(schema)
        except Exception:
            continue
        for uri in (path_uri,):
            registry = registry.with_resource(uri, resource)
            store[uri] = schema
        schema_id = schema.get("$id") if isinstance(schema, dict) else None
        if isinstance(schema_id, str) and schema_id:
            declared_uri = urljoin(path_uri, schema_id)
            registry = registry.with_resource(declared_uri, resource)
            store[declared_uri] = schema
    return registry, store


def _manifest_entries(manifest: Any) -> tuple[list[Any], str | None]:
    """Extract the fixed M1 ``cases`` entry list."""

    if not isinstance(manifest, dict):
        return [], "manifest root must be an object"
    value = manifest.get("cases")
    if isinstance(value, list):
        return value, None
    return [], "manifest must contain an array named cases"


def _path_from_manifest(raw_path: Any, fixture_root: Path, repo_root: Path) -> tuple[Path | None, str | None]:
    if not isinstance(raw_path, str) or not raw_path:
        return None, "path must be a non-empty string"
    if "\\" in raw_path:
        return None, "path must use forward slashes"
    posix = PurePosixPath(raw_path)
    windows = PureWindowsPath(raw_path)
    if posix.is_absolute() or windows.is_absolute() or _WINDOWS_DRIVE.match(raw_path):
        return None, "path must be relative"
    parts = raw_path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return None, "path must not contain empty, '.' or '..' components"

    # Canonical published paths are relative to contracts/fixtures (v1/foo.json).
    # Accept a path relative to v1 as a convenience for local fixture authors,
    # while still resolving and checking it inside that directory.
    if parts[:3] == ["contracts", "fixtures", "v1"]:
        candidate = repo_root.joinpath(*parts)
    elif parts[:2] == ["fixtures", "v1"]:
        candidate = repo_root.joinpath("contracts", *parts)
    elif parts[:1] == ["v1"]:
        candidate = fixture_root.parent.joinpath(*parts)
    else:
        candidate = fixture_root.joinpath(*parts)

    try:
        resolved = candidate.resolve(strict=False)
        v1_root = fixture_root.resolve(strict=False)
        resolved.relative_to(v1_root)
    except ValueError:
        return None, "path must remain inside contracts/fixtures/v1"
    return resolved, None


def _iter_fixture_json(fixture_root: Path) -> Iterable[Path]:
    if not fixture_root.exists():
        return ()
    return sorted(
        (
            path
            for path in fixture_root.rglob("*.json")
            if path.is_file() and path.name != "manifest.json"
        ),
        key=lambda path: path.as_posix(),
    )


def _check_symlinks(root: Path, errors: list[str]) -> None:
    contracts = root / "contracts"
    if not contracts.exists():
        return
    for path in sorted(contracts.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            errors.append(f"{_display_path(path, root)}: symlinks are not allowed")


def validate(root: Path) -> list[str]:
    """Return sorted validation diagnostics for ``root``."""

    errors: list[str] = []
    root = root.resolve()
    _check_symlinks(root, errors)

    schemas_root = root / "contracts" / "schemas" / "v1"
    fixtures_root = root / "contracts" / "fixtures" / "v1"
    manifest_path = fixtures_root / "manifest.json"
    if not schemas_root.is_dir():
        errors.append("contracts/schemas/v1: directory is missing")
    if not fixtures_root.is_dir():
        errors.append("contracts/fixtures/v1: directory is missing")

    schemas: dict[str, Any] = {}
    for name in REQUIRED_SCHEMA_NAMES:
        path = schemas_root / name
        if not path.is_file():
            errors.append(f"contracts/schemas/v1/{name}: required schema is missing")
            continue
        value = _load_json(path, errors)
        if value is not None:
            schemas[name] = value
            errors.extend(_schema_errors(value, path))

    # Self-validate any additional schema files as well; this keeps the gate
    # useful if a later M1 revision adds a shared definitions schema.
    if schemas_root.is_dir():
        for path in sorted(schemas_root.glob("*.schema.json"), key=lambda item: item.name):
            if path.name in schemas:
                continue
            value = _load_json(path, errors)
            if value is not None:
                schemas[path.name] = value
                errors.extend(_schema_errors(value, path))

    schema_registry, _ = _build_schema_registry(schemas, schemas_root)

    manifest = _load_json(manifest_path, errors) if manifest_path.is_file() else None
    manifest_schema = schemas.get("fixture-manifest.schema.json")
    if manifest is not None and manifest_schema is not None:
        errors.extend(
            _validate_with_schema(
                manifest,
                manifest_schema,
                "contracts/fixtures/v1/manifest.json",
                registry=schema_registry,
                base_uri=(schemas_root / "fixture-manifest.schema.json").resolve().as_uri(),
            )
        )

    entries, manifest_shape_error = _manifest_entries(manifest)
    if manifest_shape_error:
        errors.append(f"contracts/fixtures/v1/manifest.json: {manifest_shape_error}")

    registered_paths: dict[str, int] = {}
    registered_ids: dict[str, int] = {}
    for index, entry in enumerate(entries):
        label = f"contracts/fixtures/v1/manifest.json[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{label}: entry must be an object")
            continue
        entry_id = entry.get("id")
        raw_path = entry.get("path")
        digest = entry.get("sha256")
        if not isinstance(entry_id, str):
            errors.append(f"{label}: id must be a string")
        elif entry_id in registered_ids:
            errors.append(f"{label}: duplicate id {entry_id!r}")
        else:
            registered_ids[entry_id] = index

        resolved, path_error = _path_from_manifest(raw_path, fixtures_root, root)
        canonical_path: str | None = None
        if path_error:
            errors.append(f"{label}: {path_error}")
        elif resolved is not None:
            canonical_path = resolved.relative_to(fixtures_root.resolve()).as_posix()
            if canonical_path in registered_paths:
                errors.append(f"{label}: duplicate path {canonical_path!r}")
            else:
                registered_paths[canonical_path] = index
            if not resolved.is_file():
                errors.append(f"{label}: fixture path does not exist: {canonical_path}")
            elif resolved.is_symlink():
                errors.append(f"{label}: fixture path is a symlink: {canonical_path}")
            elif isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest):
                actual_digest = hashlib.sha256(resolved.read_bytes()).hexdigest()
                if actual_digest != digest.lower():
                    errors.append(
                        f"{label}: sha256 mismatch for {canonical_path} "
                        f"(expected {digest.lower()}, got {actual_digest})"
                    )
            elif digest is not None:
                errors.append(f"{label}: sha256 must be a 64-character lowercase hex digest")

            case = _load_json(resolved, errors) if resolved.is_file() else None
            case_schema = schemas.get("fixture-case.schema.json")
            if case is not None and case_schema is not None:
                errors.extend(
                    _validate_with_schema(
                        case,
                        case_schema,
                        canonical_path,
                        registry=schema_registry,
                        base_uri=(schemas_root / "fixture-case.schema.json").resolve().as_uri(),
                    )
                )
            if isinstance(case, dict):
                if isinstance(entry_id, str) and case.get("id") != entry_id:
                    errors.append(
                        f"{canonical_path}: case id {case.get('id')!r} does not match manifest id {entry_id!r}"
                    )
                capability = case.get("capability")
                if capability not in CAPABILITIES:
                    errors.append(f"{canonical_path}: unsupported capability {capability!r}")
                else:
                    capability_schema = schemas.get(CAPABILITY_SCHEMAS[capability])
                    if capability_schema is not None and case.get("validity") == "valid" and "input" in case:
                        errors.extend(
                            _validate_with_schema(
                                case["input"],
                                capability_schema,
                                f"{canonical_path}: input",
                                registry=schema_registry,
                                base_uri=(schemas_root / CAPABILITY_SCHEMAS[capability]).resolve().as_uri(),
                            )
                        )

        if digest is None:
            errors.append(f"{label}: sha256 is required")

    actual_paths = {
        path.relative_to(fixtures_root.resolve()).as_posix() for path in _iter_fixture_json(fixtures_root)
    }
    registered_path_set = set(registered_paths)
    for missing in sorted(actual_paths - registered_path_set):
        errors.append(f"contracts/fixtures/v1/{missing}: fixture is not registered in manifest")
    for extra in sorted(registered_path_set - actual_paths):
        errors.append(f"contracts/fixtures/v1/manifest.json: registered path is not a fixture: {extra}")

    # Ensure every fixture file gets byte-level checks even when it was omitted
    # from the manifest; omission should not hide malformed JSON diagnostics.
    for path in _iter_fixture_json(fixtures_root):
        if path.relative_to(fixtures_root.resolve()).as_posix() not in registered_path_set:
            _load_json(path, errors)

    return sorted(set(errors))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the parent of scripts/)",
    )
    args = parser.parse_args(argv)
    errors = validate(args.root)
    if errors:
        print("contracts validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("contracts validation passed")
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised by the workflow command
    raise SystemExit(main())
