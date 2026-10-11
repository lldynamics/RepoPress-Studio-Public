#!/usr/bin/env python3
"""Focused inventory and partition tests for the Swift test process runner."""

from __future__ import annotations

import re
import unittest

from script.run_swift_test_process import build_shards, parse_inventory


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


class RepositoryPartitionTests(unittest.TestCase):
    target = "PublishingWorkbenchCoreTests"

    def shards_for(self, suites: dict[str, int]):
        rows = [
            f"{self.target}.{suite}/testValue{index:03d}"
            for suite, count in suites.items()
            for index in range(count)
        ]
        tests = parse_inventory("\n".join(rows), [self.target])
        shards = build_shards(tests, [self.target])
        # Verify filters, not just the declared test lists: SwiftPM executes
        # these patterns, so cross-category overlap would run a case twice.
        for test in tests:
            matches = [shard for shard in shards if re.search(shard.filter_pattern, test.raw)]
            self.assertEqual(len(matches), 1, test.raw)
            self.assertIn(test, matches[0].tests)
        return tests, shards

    def test_real_git_category_is_bounded_and_kept_out_of_general_core_batches(self) -> None:
        _, shards = self.shards_for({
            "RepositoryAlphaTests": 20,
            "RepositoryBetaTests": 20,
            "RepositoryFutureTests": 1,
            "RepositoryGammaTests": 10,
            "CoreMemoryTests": 30,
            "NotRepositoryTests": 2,
        })
        repository_shards = [shard for shard in shards if shard.slug.startswith("core-repository-")]
        self.assertEqual([len(shard.tests) for shard in repository_shards], [40, 11])
        self.assertTrue(all(len({test.suite for test in shard.tests}) <= 2 for shard in repository_shards))
        general_shards = [shard for shard in shards if not shard.slug.startswith("core-repository-")]
        self.assertEqual({test.suite for shard in general_shards for test in shard.tests},
                         {"CoreMemoryTests", "NotRepositoryTests"})

    def test_repository_suite_limit_splits_even_when_cases_would_fit(self) -> None:
        _, shards = self.shards_for({
            "RepositoryAlphaTests": 1,
            "RepositoryBetaTests": 1,
            "RepositoryGammaTests": 1,
        })
        self.assertEqual([len(shard.tests) for shard in shards], [2, 1])

    def test_repository_test_count_limit_splits_suites_that_would_fit_by_suite_count(self) -> None:
        _, shards = self.shards_for({"RepositoryAlphaTests": 25, "RepositoryBetaTests": 20})
        self.assertEqual([len(shard.tests) for shard in shards], [25, 20])

    def test_oversized_repository_suite_uses_exact_methods_without_dropping_tail(self) -> None:
        tests, shards = self.shards_for({"RepositoryLargeTests": 41})
        self.assertEqual([len(shard.tests) for shard in shards], [40, 1])
        self.assertEqual([test for shard in shards for test in shard.tests], tests)
        self.assertTrue(all(shard.filter_pattern.endswith("$") for shard in shards))

    def test_partition_is_independent_of_inventory_row_order(self) -> None:
        tests, shards = self.shards_for({
            "RepositoryZetaTests": 3,
            "RepositoryAlphaTests": 2,
            "CoreMemoryTests": 5,
        })
        self.assertEqual(build_shards(list(reversed(tests)), [self.target]), shards)


if __name__ == "__main__":
    unittest.main()
