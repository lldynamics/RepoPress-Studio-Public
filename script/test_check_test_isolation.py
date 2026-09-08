#!/usr/bin/env python3
"""Tests for the workbench test-isolation source gate."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_test_isolation import strip_swift_comments_and_strings, violations


class TestCheckTestIsolation(unittest.TestCase):
    def test_single_line_bare_calls_are_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Tests").mkdir()
            (root / "Tests" / "Fixture.swift").write_text(
                "let store = WorkbenchStore()\nlet persistence = WorkbenchPersistence()\n",
                encoding="utf-8",
            )
            self.assertEqual(len(violations(root)), 2)

    def test_multiline_bare_call_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Tests").mkdir()
            (root / "Tests" / "Fixture.swift").write_text(
                "let store = WorkbenchStore(\n  \n)\n", encoding="utf-8"
            )
            self.assertEqual(len(violations(root)), 1)

    def test_comments_and_strings_are_ignored(self) -> None:
        source = """
        // WorkbenchStore()
        /* WorkbenchPersistence() */
        let text = \"WorkbenchStore()\"
        """
        self.assertNotIn("WorkbenchStore()", strip_swift_comments_and_strings(source))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Tests").mkdir()
            (root / "Tests" / "Fixture.swift").write_text(source, encoding="utf-8")
            self.assertEqual(violations(root), [])

    def test_raw_and_multiline_literals_preserve_following_code(self) -> None:
        source = '\n'.join([
            'let raw = #"quoted "WorkbenchStore()" text"#',
            'let multi = """',
            'quoted "WorkbenchPersistence()" text',
            '"""',
            'WorkbenchStore()',
        ])
        masked = strip_swift_comments_and_strings(source)
        self.assertEqual(masked.count('WorkbenchStore()'), 1)
        self.assertNotIn('WorkbenchPersistence()', masked)
        self.assertEqual(masked.count('\n'), source.count('\n'))

    def test_executable_interpolation_is_checked(self) -> None:
        masked = strip_swift_comments_and_strings(r'let message = "value \(WorkbenchStore())"')
        self.assertIn('WorkbenchStore()', masked)

    def test_explicit_arguments_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Tests").mkdir()
            (root / "Tests" / "Fixture.swift").write_text(
                """
                WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
                WorkbenchPersistence(fileURL: url)
                """,
                encoding="utf-8",
            )
            self.assertEqual(violations(root), [])


if __name__ == "__main__":
    unittest.main()
