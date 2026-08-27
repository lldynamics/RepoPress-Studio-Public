#!/usr/bin/env python3
"""Focused inventory parser tests for the Swift test process runner."""

from __future__ import annotations

import unittest

from script.run_swift_test_process import parse_inventory


class InventoryPatternTests(unittest.TestCase):
    target = "PublishingWorkbenchCoreTests"

    def test_existing_unparameterized_inventory_row(self) -> None:
        tests = parse_inventory(
            f"{self.target}.MarkdownSuite/testRenderer\n",
            [self.target],
        )
        self.assertEqual(tests[0].suite, "MarkdownSuite")
        self.assertEqual(tests[0].method, "testRenderer")
        self.assertFalse(tests[0].is_swift_testing)

    def test_parameterized_swift_testing_rows_keep_signature_in_method(self) -> None:
        rows = "\n".join(
            (
                f"{self.target}.ParameterizedSuite/testValue(value: 1, type: Int)",
                f"{self.target}.ParameterizedSuite/testNamed(foo:bar:)",
                f"{self.target}.ParameterizedSuite/testEmpty()",
            )
        )
        tests = parse_inventory(rows, [self.target])
        self.assertEqual(
            [test.method for test in tests],
            ["testEmpty", "testNamed", "testValue"],
        )
        self.assertTrue(all(test.is_swift_testing for test in tests))

    def test_colons_are_supported_in_suite_and_method_identifiers(self) -> None:
        tests = parse_inventory(
            f"{self.target}.Suite:Namespace/testCase:variant(foo: bar)\n",
            [self.target],
        )
        self.assertEqual(tests[0].suite, "Suite:Namespace")
        self.assertEqual(tests[0].method, "testCase:variant")

    def test_unrelated_logs_and_malformed_signatures_are_rejected(self) -> None:
        for row in (
            "Test run with 1 test in 1 suite passed",
            f"{self.target}.Suite/testCase(unclosed",
            f"{self.target}.Suite/testCase() trailing noise",
        ):
            with self.subTest(row=row):
                with self.assertRaisesRegex(ValueError, "unsupported"):
                    parse_inventory(row, [self.target])


if __name__ == "__main__":
    unittest.main()
