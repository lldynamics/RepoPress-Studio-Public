from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable

from scripts import check_fixture_hygiene, validate_contracts


def _canonical(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
            separators=(",", ": "),
        )
        + "\n"
    ).encode("utf-8")


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_canonical(value))


def _schema_files() -> dict[str, Any]:
    any_value: dict[str, Any] = {}
    case = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["id", "capability", "validity", "description", "input", "expected"],
        "properties": {
            "id": {"type": "string", "minLength": 1},
            "capability": {"enum": list(validate_contracts.CAPABILITIES)},
            "validity": {"enum": ["valid", "invalid"]},
            "description": {"type": "string"},
            "input": {"type": "object"},
            "expected": any_value,
        },
        "additionalProperties": False,
    }
    manifest_entry = {
        "type": "object",
        "required": ["id", "path", "sha256"],
        "properties": {
            "id": {"type": "string", "minLength": 1},
            "path": {"type": "string", "minLength": 1},
            "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        },
        "additionalProperties": False,
    }
    manifest = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["formatVersion", "minimumReaderVersion", "cases"],
        "properties": {
            "formatVersion": {"const": 1},
            "minimumReaderVersion": {"const": 1},
            "cases": {"type": "array", "items": manifest_entry, "minItems": 1},
        },
        "additionalProperties": False,
    }
    endpoint = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.test/contracts/schemas/v1/repository-endpoint.schema.json",
        "allOf": [{"$ref": "shared-primitives.schema.json"}],
        "type": "object",
        "properties": {
            "operation": {"type": "string"},
            "baseURL": {"type": "string", "format": "uri"},
            "queryItems": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["name", "value"],
                    "properties": {
                        "name": {"type": "string"},
                        "value": {"type": ["string", "null"]},
                    },
                    "additionalProperties": False,
                },
            },
        },
        "additionalProperties": False,
    }
    shared = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.test/contracts/schemas/v1/shared-primitives.schema.json",
        "type": "object",
        "required": ["baseURL"],
        "properties": {"baseURL": {"type": "string"}},
    }
    front_matter = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["title"],
        "properties": {"title": {"type": "string"}, "draft": {"type": "boolean"}},
        "additionalProperties": False,
    }
    conflict = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "required": ["base", "ours", "theirs"],
        "properties": {
            "base": {"type": "string"},
            "ours": {"type": "string"},
            "theirs": {"type": "string"},
        },
        "additionalProperties": False,
    }
    return {
        "fixture-case.schema.json": case,
        "fixture-manifest.schema.json": manifest,
        "repository-endpoint.schema.json": endpoint,
        "front-matter-document.schema.json": front_matter,
        "publish-conflict-diff.schema.json": conflict,
        "shared-primitives.schema.json": shared,
    }


class ContractGateFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="repopress-contract-gate-")
        self.root = Path(self.temp_dir.name)
        schemas = self.root / "contracts" / "schemas" / "v1"
        fixtures = self.root / "contracts" / "fixtures" / "v1"
        for name, value in _schema_files().items():
            _write_json(schemas / name, value)
        case = {
            "id": "endpoint-valid",
            "capability": "repository-endpoint",
            "validity": "valid",
            "description": "A repository endpoint fixture.",
            "input": {
                "operation": "clone",
                "baseURL": "https://example.test/repository.git",
                "queryItems": [],
            },
            "expected": {"normalized": "https://example.test/repository.git"},
        }
        self.case_path = fixtures / "repository-endpoint" / "endpoint-valid.json"
        _write_json(self.case_path, case)
        manifest = {
            "formatVersion": 1,
            "minimumReaderVersion": 1,
            "cases": [
                {
                    "id": case["id"],
                    "path": "repository-endpoint/endpoint-valid.json",
                    "sha256": hashlib.sha256(self.case_path.read_bytes()).hexdigest(),
                }
            ],
        }
        self.manifest_path = fixtures / "manifest.json"
        _write_json(self.manifest_path, manifest)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def manifest(self) -> dict[str, Any]:
        return json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def write_manifest(self, value: dict[str, Any]) -> None:
        _write_json(self.manifest_path, value)

    def assert_contracts_fail(self, mutate: Callable[[], None], text: str) -> None:
        mutate()
        errors = validate_contracts.validate(self.root)
        self.assertTrue(errors, text)

    def test_valid_minimal_repository_passes(self) -> None:
        self.assertEqual([], validate_contracts.validate(self.root))
        self.assertEqual([], check_fixture_hygiene.check(self.root))

    def test_duplicate_manifest_id_is_rejected(self) -> None:
        def mutate() -> None:
            value = self.manifest()
            value["cases"].append(
                dict(value["cases"][0], path="repository-endpoint/second.json")
            )
            _write_json(
                self.root / "contracts/fixtures/v1/repository-endpoint/second.json",
                json.loads(self.case_path.read_text()),
            )
            self.write_manifest(value)

        self.assert_contracts_fail(mutate, "duplicate ids must fail")

    def test_duplicate_manifest_path_is_rejected(self) -> None:
        def mutate() -> None:
            value = self.manifest()
            value["cases"].append(dict(value["cases"][0], id="endpoint-copy"))
            self.write_manifest(value)

        self.assert_contracts_fail(mutate, "duplicate paths must fail")

    def test_unregistered_fixture_is_rejected(self) -> None:
        def mutate() -> None:
            _write_json(
                self.root / "contracts/fixtures/v1/repository-endpoint/unregistered.json",
                {
                    "id": "unregistered",
                    "capability": "repository-endpoint",
                    "validity": "valid",
                    "description": "Not in the manifest.",
                    "input": {
                        "operation": "clone",
                        "baseURL": "https://example.test/other.git",
                    },
                    "expected": {},
                },
            )

        self.assert_contracts_fail(mutate, "unregistered fixtures must fail")

    def test_manifest_extra_path_is_rejected(self) -> None:
        def mutate() -> None:
            value = self.manifest()
            value["cases"].append(
                {
                    "id": "missing",
                    "path": "repository-endpoint/missing.json",
                    "sha256": "0" * 64,
                }
            )
            self.write_manifest(value)

        self.assert_contracts_fail(mutate, "manifest extras must fail")

    def test_sha256_mismatch_is_rejected(self) -> None:
        def mutate() -> None:
            value = self.manifest()
            value["cases"][0]["sha256"] = "0" * 64
            self.write_manifest(value)

        self.assert_contracts_fail(mutate, "sha mismatch must fail")

    def test_path_traversal_is_rejected(self) -> None:
        def mutate() -> None:
            value = self.manifest()
            value["cases"][0]["path"] = "../endpoint-valid.json"
            self.write_manifest(value)

        self.assert_contracts_fail(mutate, "path traversal must fail")

    def test_bom_is_rejected(self) -> None:
        def mutate() -> None:
            path = self.root / "contracts/schemas/v1/fixture-case.schema.json"
            path.write_bytes(b"\xef\xbb\xbf" + path.read_bytes())

        self.assert_contracts_fail(mutate, "BOM must fail")

    def test_crlf_is_rejected(self) -> None:
        def mutate() -> None:
            self.case_path.write_bytes(self.case_path.read_bytes().replace(b"\n", b"\r\n"))

        self.assert_contracts_fail(mutate, "CRLF must fail")

    def test_unsupported_capability_is_rejected(self) -> None:
        def mutate() -> None:
            case = json.loads(self.case_path.read_text(encoding="utf-8"))
            case["capability"] = "unsupported"
            _write_json(self.case_path, case)
            # Keep the manifest digest synchronized so the capability error is
            # isolated from the byte-hash check.
            value = self.manifest()
            value["cases"][0]["sha256"] = hashlib.sha256(self.case_path.read_bytes()).hexdigest()
            self.write_manifest(value)

        self.assert_contracts_fail(mutate, "unsupported capability must fail")

    def test_cross_file_schema_ref_is_resolved(self) -> None:
        def mutate() -> None:
            case = json.loads(self.case_path.read_text(encoding="utf-8"))
            case["input"].pop("baseURL")
            _write_json(self.case_path, case)
            value = self.manifest()
            value["cases"][0]["sha256"] = hashlib.sha256(self.case_path.read_bytes()).hexdigest()
            self.write_manifest(value)

        errors = validate_contracts.validate(self.root)
        self.assertEqual([], errors, "the valid baseline must resolve its external schema")
        mutate()
        errors = validate_contracts.validate(self.root)
        self.assertTrue(any("input" in error for error in errors), errors)

    def test_invalid_case_does_not_require_valid_input_shape(self) -> None:
        case = json.loads(self.case_path.read_text(encoding="utf-8"))
        case["validity"] = "invalid"
        case["input"] = {"operation": "clone", "baseURL": 42}
        _write_json(self.case_path, case)
        manifest = self.manifest()
        manifest["cases"][0]["sha256"] = hashlib.sha256(self.case_path.read_bytes()).hexdigest()
        self.write_manifest(manifest)
        self.assertEqual([], validate_contracts.validate(self.root))


class FixtureHygieneTests(ContractGateFixture):
    def test_expected_field_names_do_not_trigger_false_positive(self) -> None:
        case = json.loads(self.case_path.read_text(encoding="utf-8"))
        case["expected"] = {"token": "placeholder", "privateKey": None}
        _write_json(self.case_path, case)
        manifest = self.manifest()
        manifest["cases"][0]["sha256"] = hashlib.sha256(self.case_path.read_bytes()).hexdigest()
        self.write_manifest(manifest)
        self.assertEqual([], check_fixture_hygiene.check(self.root))

    def test_common_token_is_rejected(self) -> None:
        case = json.loads(self.case_path.read_text(encoding="utf-8"))
        case["expected"] = {"accessToken": "ghp_" + "a" * 32}
        _write_json(self.case_path, case)
        self.assertTrue(check_fixture_hygiene.check(self.root))

    def test_local_path_is_rejected(self) -> None:
        case = json.loads(self.case_path.read_text(encoding="utf-8"))
        case["expected"] = {"path": "/Users/example/fixture.md"}
        _write_json(self.case_path, case)
        self.assertTrue(check_fixture_hygiene.check(self.root))

    def test_non_example_test_host_is_rejected(self) -> None:
        case = json.loads(self.case_path.read_text(encoding="utf-8"))
        case["expected"] = {"url": "http://localhost:8080/repository.git"}
        _write_json(self.case_path, case)
        self.assertTrue(check_fixture_hygiene.check(self.root))

    def test_symlink_is_rejected(self) -> None:
        link = self.root / "contracts/fixtures/v1/link.json"
        try:
            link.symlink_to(self.case_path)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlink creation unavailable: {exc}")
        self.assertTrue(check_fixture_hygiene.check(self.root))


if __name__ == "__main__":
    unittest.main()
