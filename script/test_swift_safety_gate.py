#!/usr/bin/env python3
"""Regression tests for check_swift_safety.py."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "script" / "check_swift_safety.py"


def run_gate(root: Path, exceptions: dict[str, object]) -> subprocess.CompletedProcess[str]:
    exception_path = root / "exceptions.json"
    exception_path.write_text(json.dumps(exceptions), encoding="utf-8")
    return subprocess.run(
        ["python3", str(GATE), "--root", str(root), "--exceptions", str(exception_path)],
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="swift-safety-gate.") as temporary:
        root = Path(temporary)
        source = root / "Sources" / "Fixture.swift"
        source.parent.mkdir(parents=True)
        source.write_text(
            "final class LockedBox:\n"
            "  @unchecked Sendable {}\n"
            "func decode(_ value: Any) { _ = value as! String }\n"
            "func optional() { _ = try? loadOptional() }\n"
            "func risky() { _ = try? publisher.commit() }\n"
            "// final class CommentOnly: @unchecked Sendable {}\n"
            "let text = \"try! should not be scanned\"\n"
            "let interpolated = \"\\(try! load())\"\n"
            "let block = \"\"\"\n"
            "extension String: @unchecked Sendable\n"
            "\"\"\"\n",
            encoding="utf-8",
        )
        empty = {
            "schemaVersion": 1,
            "uncheckedSendable": [],
            "forcedOperations": [],
            "optionalOperations": [],
            "optionalOperationRules": [],
        }
        unreviewed = run_gate(root, empty)
        assert unreviewed.returncode != 0, unreviewed
        assert "unreviewed @unchecked Sendable" in unreviewed.stderr, unreviewed.stderr
        assert "unreviewed as!" in unreviewed.stderr, unreviewed.stderr
        assert "unreviewed try!" in unreviewed.stderr, unreviewed.stderr
        assert "unreviewed try?" in unreviewed.stderr, unreviewed.stderr
        assert "CommentOnly" not in unreviewed.stderr, unreviewed.stderr
        assert "extension String" not in unreviewed.stderr, unreviewed.stderr

        reviewed = {
            "schemaVersion": 1,
            "uncheckedSendable": [
                {
                    "file": "Sources/Fixture.swift",
                    "declaration": "LockedBox",
                    "rationale": "Fixture lock protects all state.",
                }
            ],
            "forcedOperations": [
                {
                    "file": "Sources/Fixture.swift",
                    "kind": "as!",
                    "contains": "value as! String",
                    "rationale": "Fixture deliberately verifies the reviewed cast path.",
                },
                {
                    "file": "Sources/Fixture.swift",
                    "kind": "try!",
                    "contains": "try! load()",
                    "rationale": "Fixture deliberately verifies interpolation scanning.",
                }
            ],
            "optionalOperations": [
                {
                    "file": "Sources/Fixture.swift",
                    "category": "parsing",
                    "contains": "try? loadOptional()",
                    "rationale": "Fixture deliberately verifies try? classification.",
                },
                {
                    "file": "Sources/Fixture.swift",
                    "category": "mainOperation",
                    "contains": "try? publisher.commit()",
                    "rationale": "Fixture deliberately verifies exact registration for a risky operation.",
                },
            ],
            "optionalOperationRules": [],
        }
        accepted = run_gate(root, reviewed)
        assert accepted.returncode == 0, accepted.stderr
        assert "1 production and 0 test audited @unchecked Sendable" in accepted.stdout, accepted.stdout
        assert "2 classified try?" in accepted.stdout, accepted.stdout

        optional_only_stale = json.loads(json.dumps(reviewed))
        optional_only_stale["optionalOperations"].append(
            {
                "file": "Sources/Fixture.swift",
                "category": "parsing",
                "contains": "try? removedOptional()",
                "rationale": "Fixture deliberately verifies optional-only stale detection.",
            }
        )
        stale_optional = run_gate(root, optional_only_stale)
        assert stale_optional.returncode != 0, stale_optional
        assert "stale try? exception" in stale_optional.stderr, stale_optional.stderr

        source.write_text("struct SafeValue: Sendable {}\n", encoding="utf-8")
        stale = run_gate(root, reviewed)
        assert stale.returncode != 0, stale
        assert "stale @unchecked Sendable exception" in stale.stderr, stale.stderr

    print("swift safety gate test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
