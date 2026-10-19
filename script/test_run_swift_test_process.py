#!/usr/bin/env python3
"""Focused inventory and partition tests for the Swift test process runner."""

from __future__ import annotations

import re
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from script.run_swift_test_process import (
    ProcessResult,
    SwiftTestCachePolicyError,
    build_shards,
    ensure_swift_test_cache_workspace,
    parse_inventory,
    run_all,
)


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
        self.assertEqual([len(shard.tests) for shard in repository_shards], [10, 10, 10, 10, 1, 10])
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
        _, shards = self.shards_for({"RepositoryAlphaTests": 6, "RepositoryBetaTests": 5})
        self.assertEqual([len(shard.tests) for shard in shards], [6, 5])

    def test_oversized_repository_suite_uses_exact_methods_without_dropping_tail(self) -> None:
        tests, shards = self.shards_for({"RepositoryLargeTests": 26})
        self.assertEqual([len(shard.tests) for shard in shards], [10, 10, 6])
        self.assertEqual([test for shard in shards for test in shard.tests], tests)
        self.assertTrue(all(shard.filter_pattern.endswith("$") for shard in shards))

    def test_partition_is_independent_of_inventory_row_order(self) -> None:
        tests, shards = self.shards_for({
            "RepositoryZetaTests": 3,
            "RepositoryAlphaTests": 2,
            "CoreMemoryTests": 5,
        })
        self.assertEqual(build_shards(list(reversed(tests)), [self.target]), shards)


class SwiftTestCacheWorkspaceTests(unittest.TestCase):
    def make_cache(self, root: Path, recorded_root: str | None = None) -> Path:
        cache = root / ".build" / "swift-test-shards"
        cache.mkdir(parents=True)
        if recorded_root is not None:
            (cache / "workspace-provenance.json").write_text(
                json.dumps({"schemaVersion": 1, "workspaceRoot": recorded_root}) + "\n",
                encoding="utf-8",
            )
        (cache / "old.log").write_text("legacy", encoding="utf-8")
        return cache

    def test_same_workspace_retains_cache_and_refreshes_marker_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = self.make_cache(root, str(root.resolve()))
            ensure_swift_test_cache_workspace(root, cache)
            self.assertTrue((cache / "old.log").exists())
            marker = (cache / "workspace-provenance.json").read_text(encoding="utf-8")
            self.assertIn(str(root.resolve()), marker)

    def test_changed_workspace_is_cleaned_by_allow_list_manager(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = self.make_cache(root, "/previous/checkout")
            ensure_swift_test_cache_workspace(root, cache)
            self.assertFalse((cache / "old.log").exists())
            self.assertTrue((cache / "workspace-provenance.json").exists())

    def test_legacy_cache_is_migrated_by_removing_before_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = self.make_cache(root)
            (cache / "SwiftShims").mkdir()
            (cache / "SwiftShims" / "absolute-path.txt").write_text(
                "/old/checkout", encoding="utf-8"
            )
            ensure_swift_test_cache_workspace(root, cache)
            self.assertFalse((cache / "SwiftShims").exists())
            self.assertTrue((cache / "workspace-provenance.json").exists())

    def test_symlink_cache_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            cache = root / ".build" / "swift-test-shards"
            cache.parent.mkdir()
            cache.symlink_to(outside, target_is_directory=True)
            with self.assertRaises(SwiftTestCachePolicyError):
                ensure_swift_test_cache_workspace(root, cache)
            self.assertFalse((outside / "workspace-provenance.json").exists())

    def test_symlink_build_root_fails_closed_even_without_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            (root / ".build").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(SwiftTestCachePolicyError):
                ensure_swift_test_cache_workspace(
                    root, root / ".build" / "swift-test-shards"
                )

    def test_cleanup_failure_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = self.make_cache(root, "/previous/checkout")
            failed = mock.Mock(returncode=1, stderr="refusing cleanup", stdout="")
            with mock.patch("script.run_swift_test_process.subprocess.run", return_value=failed):
                with self.assertRaisesRegex(SwiftTestCachePolicyError, "cleanup failed"):
                    ensure_swift_test_cache_workspace(root, cache)
            self.assertTrue((cache / "old.log").exists())
            self.assertIn("/previous/checkout", (cache / "workspace-provenance.json").read_text(encoding="utf-8"))

    def test_malformed_marker_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = self.make_cache(root)
            (cache / "workspace-provenance.json").write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(SwiftTestCachePolicyError, "provenance marker"):
                ensure_swift_test_cache_workspace(root, cache)

    def test_run_all_cleans_stale_cache_before_swift_environment_and_preserves_external_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "Package.swift"
            package.write_text(
                'let package = Package(name: "Fixture", targets: '
                '[.testTarget(name: "PersonalSitePublisherMacTests")])\n',
                encoding="utf-8",
            )
            (root / "script").mkdir()
            (root / "script" / "quality_baselines.json").write_text(
                '{"swiftTestMinimumCountsByTarget":{"PersonalSitePublisherMacTests":1}}',
                encoding="utf-8",
            )
            cache = root / ".build" / "swift-test-shards"
            cache.mkdir(parents=True)
            (cache / "workspace-provenance.json").write_text(
                json.dumps({"schemaVersion": 1, "workspaceRoot": "/old/checkout"}),
                encoding="utf-8",
            )
            (cache / "stale.log").write_text("stale", encoding="utf-8")
            external = root / "external-cache"
            external.mkdir()
            (external / "sentinel").write_text("keep", encoding="utf-8")
            inventory = "PersonalSitePublisherMacTests.Suite/testCase\n"
            calls: list[list[str]] = []
            preflight_state: list[tuple[bool, bool]] = []

            def fake_child(command: list[str], **_kwargs: object) -> ProcessResult:
                calls.append(command)
                preflight_state.append(
                    ((cache / "stale.log").exists(), (cache / "workspace-provenance.json").exists())
                )
                log_path = _kwargs.get("log_path")
                if isinstance(log_path, Path):
                    log_path.parent.mkdir(parents=True, exist_ok=True)
                    log_path.write_text(
                        "Executed 1 test, with 0 failures (0 unexpected)\n",
                        encoding="utf-8",
                    )
                if command[-1] == "list":
                    return ProcessResult(0, False, 0.0, inventory)
                return ProcessResult(
                    0,
                    False,
                    0.0,
                    "Executed 1 test, with 0 failures (0 unexpected)\n",
                )

            with mock.patch.dict(
                os.environ,
                {
                    "SWIFT_TEST_HOME": str(external),
                    "SWIFT_BIN": "fixture-swift",
                },
                clear=False,
            ), mock.patch("script.run_swift_test_process.run_child", side_effect=fake_child):
                self.assertEqual(run_all(root), 0)
            self.assertFalse((cache / "stale.log").exists())
            self.assertTrue((external / "sentinel").exists())
            self.assertTrue(calls)
            self.assertTrue(preflight_state)
            self.assertTrue(all(not stale and marker for stale, marker in preflight_state))


if __name__ == "__main__":
    unittest.main()
