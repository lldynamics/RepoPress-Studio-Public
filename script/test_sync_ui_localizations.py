#!/usr/bin/env python3

import importlib.util
import copy
import contextlib
import io
import json
from pathlib import Path
import tempfile
from typing import Optional
import unittest
from unittest.mock import patch
from types import SimpleNamespace


MODULE_PATH = Path(__file__).with_name("sync_ui_localizations.py")
SPEC = importlib.util.spec_from_file_location("sync_ui_localizations", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class SwiftLocalizationExtractionTests(unittest.TestCase):
    def test_app_core_l10n_literals_join_core_resource_scope(self) -> None:
        previous_source_root = SYNC.SOURCE_ROOT
        previous_core_roots = SYNC.PUBLISHING_CORE_SOURCE_ROOTS
        with tempfile.TemporaryDirectory() as directory:
            app_root = Path(directory) / "App"
            core_root = Path(directory) / "Core"
            app_root.mkdir()
            core_root.mkdir()
            (app_root / "View.swift").write_text(
                'let label = CoreL10n.text("本次探测")', encoding="utf-8"
            )
            SYNC.SOURCE_ROOT = app_root
            SYNC.PUBLISHING_CORE_SOURCE_ROOTS = (core_root,)
            try:
                keys = SYNC.extract_core_localization_keys()
            finally:
                SYNC.SOURCE_ROOT = previous_source_root
                SYNC.PUBLISHING_CORE_SOURCE_ROOTS = previous_core_roots
        self.assertIn("本次探测", keys)

    def test_workspace_areas_do_not_become_atomic_section_keys(self) -> None:
        source = '''public enum WorkspaceSection {
  case writing
  var page: String { "workspace.writing.page" }
}
public enum WorkspaceArea {
  case writing
  case resources
  case site
}
public enum WorkspaceCenterSurface {
  case inspector
}
'''
        previous = SYNC.WORKSPACE_MODELS_PATH
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "WorkspaceModels.swift"
            path.write_text(source, encoding="utf-8")
            SYNC.WORKSPACE_MODELS_PATH = path
            try:
                keys = SYNC.extract_workspace_navigation_keys()
            finally:
                SYNC.WORKSPACE_MODELS_PATH = previous
        self.assertIn("workspace.writing.detail", keys)
        self.assertIn("workspace.writing.page", keys)
        self.assertIn("workspace.area.resources", keys)
        self.assertIn("workspace.area.site", keys)
        self.assertNotIn("workspace.resources", keys)
        self.assertNotIn("workspace.inspector", keys)

    def extracted_literal(self, source: str) -> Optional[str]:
        match = SYNC.LITERAL_LOCALIZATION_CALL_PREFIX_PATTERN.search(source)
        if match is None:
            return None
        raw_value = SYNC.swift_string_literal_content(source, match.end() - 1)
        return SYNC.normalized_swiftui_literal(raw_value)

    def test_balances_nested_function_calls(self) -> None:
        value = r"移除上下文 \(contextReferenceLabel(reference))"
        self.assertEqual(SYNC.normalized_swiftui_literal(value), "移除上下文 %@")

    def test_balances_string_literal_inside_interpolation(self) -> None:
        source = r'.accessibilityValue("引用片段：\(locator ?? "正文片段")。")'
        match = SYNC.LITERAL_LOCALIZATION_CALL_PREFIX_PATTERN.search(source)
        self.assertIsNotNone(match)
        raw_value = SYNC.swift_string_literal_content(source, match.end() - 1)
        self.assertEqual(
            SYNC.normalized_swiftui_literal(raw_value),
            "引用片段：%@。",
        )

    def test_int_interpolation_uses_integer_placeholder(self) -> None:
        value = r"\(Int(progress * 100))%"
        self.assertEqual(SYNC.normalized_swiftui_literal(value), "%lld%")

    def test_help_literal_is_in_offline_extraction_scope(self) -> None:
        source = '.help("Open details")'
        match = SYNC.LITERAL_LOCALIZATION_CALL_PREFIX_PATTERN.search(source)
        self.assertIsNotNone(match)
        raw_value = SYNC.swift_string_literal_content(source, match.end() - 1)
        self.assertEqual(SYNC.normalized_swiftui_literal(raw_value), "Open details")

    def test_help_interpolation_uses_balanced_extraction(self) -> None:
        source = r'.help("打开 \(label(item))")'
        match = SYNC.LITERAL_LOCALIZATION_CALL_PREFIX_PATTERN.search(source)
        self.assertIsNotNone(match)
        raw_value = SYNC.swift_string_literal_content(source, match.end() - 1)
        self.assertEqual(SYNC.normalized_swiftui_literal(raw_value), "打开 %@")

    def test_empty_swiftui_literals_are_not_catalog_keys(self) -> None:
        self.assertEqual(SYNC.normalized_swiftui_literal(""), "")

    def test_common_swiftui_first_argument_literals_are_extracted(self) -> None:
        calls = (
            'Text("Text title")',
            'Label("Label title", systemImage: "doc")',
            'Button("Button title") {}',
            'Toggle("Toggle title", isOn: $isOn)',
            'Picker("Picker title", selection: $selection) {}',
            'Section("Section title") {}',
            'Menu("Menu title") {}',
            'GroupBox("Group title") {}',
            'LabeledContent("Labeled content title", value: "Value")',
            'TextField("Text field title", text: $text)',
            'SecureField("Secure field title", text: $secret)',
        )
        for call in calls:
            with self.subTest(call=call):
                self.assertIsNotNone(self.extracted_literal(call))

    def test_common_title_modifiers_are_extracted(self) -> None:
        calls = (
            '.navigationTitle("Navigation title")',
            '.help("Help title")',
            '.alert("Alert title", isPresented: $isPresented) {}',
            '.confirmationDialog("Dialog title", isPresented: $isPresented) {}',
            '.accessibilityLabel("Accessibility label")',
            '.accessibilityHint("Accessibility hint")',
            '.accessibilityValue("Accessibility value")',
        )
        for call in calls:
            with self.subTest(call=call):
                self.assertIsNotNone(self.extracted_literal(call))

    def test_text_verbatim_is_not_extracted(self) -> None:
        self.assertIsNone(self.extracted_literal('Text(verbatim: "Do not localize")'))

    def test_validation_rejects_cjk_in_any_english_ui_value(self) -> None:
        catalog = {
            "strings": {
                "ordinary.key": SYNC.catalog_entry("中文", "English 中文"),
            }
        }
        self.assertIn(
            "ordinary.key: English value contains CJK text",
            SYNC.validate(catalog, {"ordinary.key": "ordinary.key"}, set()),
        )

    def test_unregistered_cjk_gate_reports_absent_ui_key(self) -> None:
        catalog = {"strings": {}}
        extracted = {
            "设置…": "设置…",
            "English only": "English only",
        }
        self.assertEqual(
            SYNC.unregistered_cjk_ui_keys(catalog, extracted),
            ["设置…"],
        )

    def test_unregistered_cjk_gate_accepts_registered_ui_key(self) -> None:
        catalog = {
            "strings": {
                "已返回文章：%@": SYNC.catalog_entry(
                    "已返回文章：%@",
                    "Returned to article: %@",
                )
            }
        }
        self.assertEqual(
            SYNC.unregistered_cjk_ui_keys(
                catalog,
                {"已返回文章：%@": "已返回文章：%@"},
            ),
            [],
        )

    def test_compiler_export_uses_native_driver_with_isolated_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_root = root / "Sources" / "PersonalSitePublisherMac"
            source_root.mkdir(parents=True)
            source = source_root / "View.swift"
            source.write_text('Text("测试")', encoding="utf-8")
            commands = []

            def compile_fixture(command, **kwargs):
                commands.append(command)
                output = Path(command[-1])
                output.mkdir(parents=True)
                (output / "View.stringsdata").write_text(json.dumps({
                    "source": str(source), "tables": {"Localizable": [{"key": "测试"}]},
                }), encoding="utf-8")
                return SimpleNamespace(returncode=0, stdout="", stderr="")

            with patch.object(SYNC, "ROOT", root), patch.object(SYNC, "SOURCE_ROOT", source_root), \
                    patch.object(SYNC.subprocess, "run", side_effect=compile_fixture):
                self.assertEqual(SYNC.extract_compiler_localizations(), {"测试": "测试"})
            self.assertEqual(commands[0][2:4], ["--build-system", "native"])
            self.assertIn("-emit-localized-strings-path", commands[0])
            self.assertTrue(Path(commands[0][-1]).is_relative_to(root / ".build" / "tmp"))

    def test_compiler_export_preserves_integer_placeholder_type(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_root = root / "App"
            source_root.mkdir()
            source = source_root / "Status.swift"
            source.write_text(r'Text("已完成 \(3) 项")', encoding="utf-8")
            export_root = root / "export"
            export_root.mkdir()
            (export_root / "Status.stringsdata").write_text(
                json.dumps({
                    "source": str(source),
                    "tables": {"Localizable": [
                        {"key": "已完成 %lld 项"}, {"key": ""},
                    ]},
                    "version": 1,
                }),
                encoding="utf-8",
            )

            extracted = SYNC.parse_compiler_localizations(export_root, source_root)

        self.assertEqual(extracted, {"已完成 %lld 项": "已完成 %lld 项"})
        catalog = {
            "strings": {
                "已完成 %lld 项": SYNC.catalog_entry("已完成 %@ 项", "Completed %@ items")
            }
        }
        self.assertIn(
            "已完成 %lld 项: en placeholders differ",
            SYNC.validate(catalog, extracted, set()),
        )
        legacy_catalog = {
            "strings": {
                "已完成 %@ 项": SYNC.catalog_entry("已完成 %@ 项", "Completed %@ items")
            }
        }
        self.assertIn(
            "已完成 %lld 项: missing zh-Hans/en value",
            SYNC.validate(legacy_catalog, extracted, set()),
        )

    def test_compiler_export_rejects_missing_source_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_root = root / "App"
            source_root.mkdir()
            (source_root / "First.swift").write_text("", encoding="utf-8")
            (source_root / "Second.swift").write_text("", encoding="utf-8")
            export_root = root / "export"
            export_root.mkdir()
            (export_root / "First.stringsdata").write_text(
                json.dumps({
                    "source": str(source_root / "First.swift"),
                    "tables": {"Localizable": []},
                    "version": 1,
                }),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(RuntimeError, "missing 1 app source"):
                SYNC.parse_compiler_localizations(export_root, source_root)

    def test_validation_rejects_literal_swift_expression_in_ui_copy(self) -> None:
        key = "定位到标题：(item.title)"
        catalog = {"strings": {key: SYNC.catalog_entry(key, "Locate heading")}}
        self.assertIn(
            f"{key}: looks like an unescaped Swift interpolation",
            SYNC.validate(catalog, {key: key}, set()),
        )

    def test_validation_accepts_normalized_swift_interpolation(self) -> None:
        key = "定位到标题：%@"
        catalog = {
            "strings": {
                key: SYNC.catalog_entry(key, "Jump to Heading: %@"),
            }
        }
        self.assertEqual(SYNC.validate(catalog, {key: key}, set()), [])

    def test_validation_requires_english_plural_variations_for_count_nouns(self) -> None:
        key = "%lld 篇文章"
        catalog = {"strings": {key: SYNC.catalog_entry(key, "%lld articles")}}
        self.assertIn(
            f"{key}: en count noun requires one/other plural variations",
            SYNC.validate(catalog, {key: key}, set()),
        )

    def test_validation_accepts_reviewed_english_plural_variations(self) -> None:
        key = "%lld 篇文章"
        catalog = {
            "strings": {
                key: SYNC.catalog_entry(
                    key,
                    {"one": "%lld article", "other": "%lld articles"},
                )
            }
        }
        self.assertEqual(SYNC.validate(catalog, {key: key}, set()), [])

    def test_validation_accepts_explicit_plural_substitution_for_multiple_counts(self) -> None:
        key = "%lld 篇文章，%lld 处引用"
        catalog = {
            "strings": {
                key: {
                    "localizations": {
                        "zh-Hans": {
                            "stringUnit": {"state": "translated", "value": key}
                        },
                        "en": {
                            "stringUnit": {
                                "state": "translated",
                                "value": "%#@articles@, %lld references",
                            },
                            "substitutions": {
                                "articles": {
                                    "argNum": 1,
                                    "formatSpecifier": "lld",
                                    "variations": {
                                        "plural": {
                                            "one": {
                                                "stringUnit": {
                                                    "state": "translated",
                                                    "value": "%arg article",
                                                }
                                            },
                                            "other": {
                                                "stringUnit": {
                                                    "state": "translated",
                                                    "value": "%arg articles",
                                                }
                                            },
                                        }
                                    },
                                }
                            },
                        },
                    }
                }
            }
        }
        self.assertEqual(
            SYNC.localized_value(catalog["strings"][key], "en"),
            "%lld articles, %lld references",
        )
        self.assertEqual(SYNC.validate(catalog, {key: key}, set()), [])

    def test_validation_rejects_literal_specifier_in_plural_substitution(self) -> None:
        # A literal %lld inside a substitution renders "(null)" at runtime.
        key = "%lld / %lld 篇"
        entry = {
            "localizations": {
                "zh-Hans": {"stringUnit": {"state": "translated", "value": key}},
                "en": {
                    "stringUnit": {"state": "translated", "value": "%lld / %#@article@"},
                    "substitutions": {
                        "article": {
                            "argNum": 2,
                            "formatSpecifier": "%lld",
                            "variations": {"plural": {
                                "one": {"stringUnit": {"state": "translated", "value": "%lld article"}},
                                "other": {"stringUnit": {"state": "translated", "value": "%lld articles"}},
                            }},
                        }
                    },
                },
            }
        }
        failures = SYNC.validate({"strings": {key: entry}}, {key: key}, set())
        self.assertTrue(any("formatSpecifier must omit %" in failure for failure in failures))
        self.assertTrue(any("must use %arg" in failure for failure in failures))

        SYNC.normalize_plural_substitutions(entry)
        self.assertEqual(SYNC.plural_substitution_format_errors(entry, "en"), [])
        self.assertEqual(
            SYNC.localized_effective_plural_values(entry, "en"),
            {"one": "%lld / %lld article", "other": "%lld / %lld articles"},
        )

    def test_synchronize_writes_reviewed_english_plural_variations(self) -> None:
        key = "%lld 篇文章"
        original_loader = SYNC.load_reviewed_translations
        try:
            SYNC.load_reviewed_translations = lambda: {
                key: {
                    "zh-Hans": key,
                    "en": {"one": "%lld article", "other": "%lld articles"},
                }
            }
            synchronized = SYNC.synchronize({"strings": {}}, {key: key})
        finally:
            SYNC.load_reviewed_translations = original_loader

        self.assertEqual(
            SYNC.localized_plural_values(synchronized["strings"][key], "en"),
            {"one": "%lld article", "other": "%lld articles"},
        )

    def test_synchronize_updates_existing_valid_value_from_master(self) -> None:
        key = "Mark as Handled"
        original_loader = SYNC.load_reviewed_translations
        try:
            SYNC.load_reviewed_translations = lambda: {key: "已处理"}
            catalog = {
                "strings": {
                    key: SYNC.catalog_entry("旧译文", "Record Processing")
                }
            }
            synchronized = SYNC.synchronize(catalog, {key: key})
        finally:
            SYNC.load_reviewed_translations = original_loader
        entry = synchronized["strings"][key]
        self.assertEqual(SYNC.localized_value(entry, "zh-Hans"), "已处理")
        self.assertEqual(SYNC.localized_value(entry, "en"), key)

    def test_check_reports_master_drift_while_ignoring_position_numbers(self) -> None:
        key = "定位到标题：%@"
        translations = {key: {"zh-Hans": key, "en": "Jump to Heading: %@"}}
        catalog = {
            "strings": {
                key: {
                    "localizations": {
                        "zh-Hans": {"stringUnit": {"state": "translated", "value": key}},
                        "en": {"stringUnit": {"state": "translated", "value": "Jump to Heading: %1$@"}},
                    }
                }
            }
        }
        self.assertEqual(
            SYNC.reviewed_translation_drift(catalog, {key: key}, translations), []
        )
        catalog["strings"][key]["localizations"]["en"]["stringUnit"]["value"] = "Other"
        self.assertEqual(
            SYNC.reviewed_translation_drift(catalog, {key: key}, translations),
            [f"{key}: en differs from reviewed translation"],
        )

    def test_synchronize_preserves_plural_substitution_metadata(self) -> None:
        key = "%lld 篇文章，%lld 处引用"
        original_loader = SYNC.load_reviewed_translations
        try:
            SYNC.load_reviewed_translations = lambda: {
                key: {"zh-Hans": key, "en": {"one": "%lld article, %lld reference", "other": "%lld articles, %lld references"}}
            }
            entry = {
                "comment": "keep this comment",
                "localizations": {
                    "zh-Hans": {"stringUnit": {"state": "translated", "value": key}},
                    "en": {
                        "stringUnit": {"state": "translated", "value": "%#@articles@, %#@references@"},
                        "substitutions": {
                            "articles": {
                                "argNum": 1,
                                "formatSpecifier": "%lld",
                                "variations": {"plural": {
                                    "one": {"stringUnit": {"state": "translated", "value": "old one"}},
                                    "other": {"stringUnit": {"state": "translated", "value": "old other"}},
                                }},
                            }
                            ,
                            "references": {
                                "argNum": 2,
                                "formatSpecifier": "%lld",
                                "variations": {"plural": {
                                    "one": {"stringUnit": {"state": "translated", "value": "old reference"}},
                                    "other": {"stringUnit": {"state": "translated", "value": "old references"}},
                                }},
                            }
                        },
                    },
                },
            }
            synchronized = SYNC.synchronize({"strings": {key: entry}}, {key: key})
        finally:
            SYNC.load_reviewed_translations = original_loader
        result = synchronized["strings"][key]
        self.assertEqual(result["comment"], "keep this comment")
        self.assertIn("substitutions", result["localizations"]["en"])
        self.assertEqual(
            SYNC.localized_plural_substitutions(result, "en")["articles"],
            {"one": "%lld article", "other": "%lld articles"},
        )
        articles = result["localizations"]["en"]["substitutions"]["articles"]
        self.assertEqual(articles["formatSpecifier"], "lld")
        self.assertEqual(
            articles["variations"]["plural"]["one"]["stringUnit"]["value"], "%arg article"
        )
        self.assertEqual(SYNC.plural_substitution_format_errors(result, "en"), [])

    def test_unmanaged_existing_translation_remains_compatible(self) -> None:
        key = "Unmanaged English key"
        catalog = {"strings": {key: SYNC.catalog_entry("自定义", "保留")}}
        original_loader = SYNC.load_reviewed_translations
        try:
            SYNC.load_reviewed_translations = lambda: {}
            synchronized = SYNC.synchronize(catalog, {key: key})
        finally:
            SYNC.load_reviewed_translations = original_loader
        self.assertEqual(SYNC.localized_value(synchronized["strings"][key], "en"), "保留")

    def test_validation_allows_parenthesized_product_acronyms(self) -> None:
        keys = [
            "API Key 使用 macOS 系统 Keychain (AES-256) 本地安全加密保存",
            "如何创建 GitHub 个人访问令牌 (PAT)？",
        ]
        catalog = {
            "strings": {
                key: SYNC.catalog_entry(key, "English")
                for key in keys
            }
        }
        self.assertEqual(
            SYNC.validate(catalog, {key: key for key in keys}, set()),
            [],
        )

    def test_reviewed_translation_loader_rejects_duplicate_json_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "translations.json"
            path.write_text(
                '{"重复": "First", "重复": "Second"}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "duplicate JSON key"):
                SYNC.load_reviewed_translation_file(path)

    def test_translation_fragment_merge_archives_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            master = root / "ui_localization_translations.json"
            fragment_a = root / "ui_feature_a_translations.json"
            fragment_b = root / "ui_feature_b_translations.json"
            archive = root / "archive"
            master.write_text('{"保留": "Keep"}', encoding="utf-8")
            fragment_a.write_text('{"新增 A": "New A"}', encoding="utf-8")
            fragment_b.write_text(
                '{"display.example": {"en": "Example", "zh-Hans": "示例"}}',
                encoding="utf-8",
            )

            fragment_count, entry_count = SYNC.merge_reviewed_translation_fragments(
                master_path=master,
                fragment_paths=(fragment_a, fragment_b),
                archive_directory=archive,
            )

            self.assertEqual((fragment_count, entry_count), (2, 3))
            self.assertEqual(
                json.loads(master.read_text(encoding="utf-8")),
                {
                    "保留": "Keep",
                    "新增 A": "New A",
                    "display.example": {"en": "Example", "zh-Hans": "示例"},
                },
            )
            self.assertFalse(fragment_a.exists())
            self.assertFalse(fragment_b.exists())
            self.assertTrue((archive / fragment_a.name).exists())
            self.assertTrue((archive / fragment_b.name).exists())

    def test_translation_fragment_merge_rejects_conflicts_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            master = root / "ui_localization_translations.json"
            fragment = root / "ui_conflict_translations.json"
            archive = root / "archive"
            master.write_text('{"相同键": "First"}', encoding="utf-8")
            fragment.write_text('{"相同键": "Second"}', encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "duplicate reviewed translation key"):
                SYNC.merge_reviewed_translation_fragments(
                    master_path=master,
                    fragment_paths=(fragment,),
                    archive_directory=archive,
                )

            self.assertEqual(
                json.loads(master.read_text(encoding="utf-8")),
                {"相同键": "First"},
            )
            self.assertTrue(fragment.exists())
            self.assertFalse(archive.exists())

    def test_translation_merge_retry_keeps_new_entries_after_identical_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            master = root / "master.json"
            fragment = root / "fragment.json"
            master.write_text('{"已归并": "Merged"}', encoding="utf-8")
            fragment.write_text(
                '{"已归并": "Merged", "尚未归并": "Pending"}',
                encoding="utf-8",
            )

            merged = SYNC.merge_reviewed_translation_entries(
                (master, fragment),
                allow_identical_duplicates=True,
            )

            self.assertEqual(
                merged,
                {"已归并": "Merged", "尚未归并": "Pending"},
            )

    def test_dynamic_allowlist_rejects_duplicate_key_across_groups(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "dynamic.json"
            path.write_text(
                '{"runtime": ["app.name"], "sourceLiterals": ["app.name"]}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "duplicate dynamic localization key"):
                SYNC.load_dynamic_key_allowlist(path)

    def test_dynamic_allowlist_requires_source_backed_key_to_remain_live(self) -> None:
        failures = SYNC.validate_dynamic_key_allowlist(
            {"runtime": {"app.name"}, "sourceLiterals": {"Removed title"}},
            set(),
            {"Current title"},
        )
        self.assertEqual(
            failures,
            ["Removed title: dynamic source literal no longer exists in Swift sources"],
        )

    def test_dynamic_allowlist_rejects_key_now_covered_by_static_extraction(self) -> None:
        failures = SYNC.validate_dynamic_key_allowlist(
            {"runtime": set(), "sourceLiterals": {"Dynamic title"}},
            {"Dynamic title"},
            {"Dynamic title"},
        )
        self.assertEqual(
            failures,
            ["Dynamic title: dynamic allowlist entry is now statically extracted"],
        )

    def test_stale_entries_are_reported_and_pruned_without_touching_managed_keys(self) -> None:
        catalog = {
            "strings": {
                "managed": SYNC.catalog_entry("保留", "Keep"),
                "stale": SYNC.catalog_entry("移除", "Remove"),
            }
        }
        self.assertEqual(SYNC.stale_catalog_keys(catalog, {"managed"}), ["stale"])
        self.assertEqual(SYNC.prune_catalog(catalog, {"managed"}), ["stale"])
        self.assertEqual(set(catalog["strings"]), {"managed"})
        self.assertEqual(
            SYNC.stale_reviewed_translation_keys(
                {"managed": "Keep", "stale": "Remove"},
                {"managed"},
            ),
            ["stale"],
        )

    def test_positional_placeholders_match_source_types(self) -> None:
        self.assertEqual(
            SYNC.placeholders("%2$@ then %1$lld"),
            ["%@", "%lld"],
        )

    def test_reviewed_pruning_preserves_core_only_translations(self) -> None:
        original_paths = SYNC.TRANSLATION_PATHS
        with tempfile.TemporaryDirectory() as directory:
            master = Path(directory) / "translations.json"
            entries = {"app": "App", "core": "Core", "obsolete": "Old"}
            master.write_text(json.dumps(entries), encoding="utf-8")
            try:
                SYNC.TRANSLATION_PATHS = (master,)
                retained, removed = SYNC.pruned_reviewed_translation_files({"app"}, {"core"})
            finally:
                SYNC.TRANSLATION_PATHS = original_paths
            self.assertEqual(retained[master], {"app": "App", "core": "Core"})
            self.assertEqual(removed[master], ["obsolete"])
            self.assertEqual(json.loads(master.read_text()), entries)

    def test_translation_comparison_preserves_explicit_argument_identity(self) -> None:
        self.assertNotEqual(
            SYNC.canonical_translation_value("%2$@ then %1$@"),
            SYNC.canonical_translation_value("%1$@ then %2$@"),
        )
        self.assertEqual(
            SYNC.canonical_translation_value("%@ then %@"),
            SYNC.canonical_translation_value("%1$@ then %2$@"),
        )

    def test_format_only_percent_lld_key_is_not_treated_as_translatable_text(self) -> None:
        self.assertIsNone(
            SYNC.reviewed_translation_expectation("%lld", "%lld", "translated")
        )

    def test_synchronize_repairs_missing_plural_category_and_stale_state(self) -> None:
        key = "%lld 篇文章"
        original_loader = SYNC.load_reviewed_translations
        try:
            SYNC.load_reviewed_translations = lambda: {
                key: {"zh-Hans": key, "en": {"one": "%lld article", "other": "%lld articles"}}
            }
            catalog = {
                "strings": {
                    key: {
                        "localizations": {
                            "zh-Hans": {"stringUnit": {"state": "needs-review", "value": "旧"}},
                            "en": {"variations": {"plural": {
                                "other": {"stringUnit": {"state": "needs-review", "value": "old"}}
                            }}},
                        }
                    }
                }
            }
            result = SYNC.synchronize(catalog, {key: key})["strings"][key]
        finally:
            SYNC.load_reviewed_translations = original_loader
        self.assertEqual(SYNC.localized_value(result, "zh-Hans"), key)
        self.assertEqual(SYNC.localized_state(result, "zh-Hans"), "translated")
        self.assertEqual(
            SYNC.localized_plural_values(result, "en"),
            {"one": "%lld article", "other": "%lld articles"},
        )
        self.assertEqual(SYNC.localized_plural_states(result, "en"), {"one": "translated", "other": "translated"})

    def test_synchronize_rejects_unmatched_plural_substitution_template(self) -> None:
        key = "%lld 篇文章"
        original_loader = SYNC.load_reviewed_translations
        try:
            SYNC.load_reviewed_translations = lambda: {
                key: {"zh-Hans": key, "en": {"one": "%lld article", "other": "%lld articles"}}
            }
            catalog = {"strings": {key: {"localizations": {"en": {
                "stringUnit": {"state": "translated", "value": "%#@count@ suffix"},
                "substitutions": {"count": {"variations": {"plural": {
                    "other": {"stringUnit": {"state": "translated", "value": "old"}}
                }}}},
            }}}}}
            with self.assertRaisesRegex(RuntimeError, "reviewed plural template mismatch"):
                SYNC.synchronize(catalog, {key: key})
        finally:
            SYNC.load_reviewed_translations = original_loader


class ShortcutLocalizationTests(unittest.TestCase):
    def fixture(self):
        localizable = {"保存网页": "保存网页"}
        phrases = {"用 ${applicationName} 保存网页": [
            "用 ${applicationName} 保存网页", "保存网页到 ${applicationName}",
        ]}
        translations = {
            "保存网页": "Save Webpage",
            "用 ${applicationName} 保存网页": "Save a webpage with ${applicationName}",
            "保存网页到 ${applicationName}": "Save a webpage to ${applicationName}",
        }
        catalogs = {table: {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.0"}
                    for table in ("Localizable", "AppShortcuts")}
        return catalogs, localizable, phrases, translations

    def extract(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "AppIntents.swift").write_text(source, encoding="utf-8")
            with patch.object(SYNC, "SHORTCUT_SOURCE_ROOT", root):
                return SYNC.extract_shortcut_localizations()

    def test_extracts_titles_descriptions_parameters_summary_dialog_and_phrase_groups(self):
        source = r'''
    static let title: LocalizedStringResource = "保存网页"
    static let description = IntentDescription("网页说明")
    @Parameter(title: "地址", description: "参数说明") var url: URL
    Summary("将 \(\.$url) 放入收件箱")
    .result(dialog: "已保存")
    let error = String(localized: "无效地址")
    AppShortcut(intent: Action(), phrases: [
      "用 \(.applicationName) 保存网页", "保存网页到 \(.applicationName)",
    ], shortTitle: "存网页", systemImageName: "safari")
    let unsupported = Metadata(title: "普通元数据")
    // IntentDescription("注释不是文案")
    /* @Parameter(title: "另一注释") */
    '''
        localizable, phrases = self.extract(source)
        self.assertEqual(set(localizable), {"保存网页", "网页说明", "地址", "参数说明",
            "将 ${url} 放入收件箱", "已保存", "无效地址", "存网页"})
        self.assertEqual(phrases, {"用 ${applicationName} 保存网页": [
            "用 ${applicationName} 保存网页", "保存网页到 ${applicationName}"]})
        self.assertNotIn("safari", localizable)

    def test_summary_retains_parameter_names_and_order(self):
        localizable, _ = self.extract(r'Summary("将 \(\.$title)：\(\.$text) 保存为笔记")')
        self.assertEqual(localizable, {"将 ${title}：${text} 保存为笔记": "将 ${title}：${text} 保存为笔记"})
        self.assertEqual(SYNC.placeholders("${title} ${text} %@"), ["%@", "${title}", "${text}"])

    def test_invalid_or_duplicate_invocation_phrase_is_rejected(self):
        for source in [
            'AppShortcut(phrases: ["保存网页"])',
            r'AppShortcut(phrases: ["用 \(.applicationName)", "用 \(.applicationName)"])',
            r'AppShortcut(phrases: ["用 \(someValue) 保存网页"])',
        ]:
            with self.subTest(source=source), self.assertRaises(RuntimeError):
                self.extract(source)

    def test_catalogs_use_apple_string_sets_and_keep_existing_comments(self):
        catalogs, localizable, phrases, translations = self.fixture()
        key = next(iter(phrases))
        catalogs["AppShortcuts"]["strings"][key] = {"comment": "Preserve reviewer context"}
        result = SYNC.synchronize_shortcut_catalogs(catalogs, localizable, phrases, translations)
        entry = result["AppShortcuts"]["strings"][key]
        self.assertEqual(entry["comment"], "Preserve reviewer context")
        self.assertEqual(entry["extractionState"], "extracted_with_value")
        self.assertEqual(entry["localizations"]["en"], {"stringSet": {
            "state": "translated", "values": [translations[phrase] for phrase in phrases[key]],
        }})
        self.assertEqual(SYNC.validate_shortcut_catalogs(result, localizable, phrases, translations), [])

    def test_extension_requires_master_even_when_catalog_values_are_valid(self):
        catalogs, localizable, phrases, translations = self.fixture()
        SYNC.synchronize_shortcut_catalogs(catalogs, localizable, phrases, translations)
        before = copy.deepcopy(catalogs)
        translations.pop("保存网页")
        with self.assertRaisesRegex(RuntimeError, "missing reviewed shortcut translation"):
            SYNC.synchronize_shortcut_catalogs(catalogs, localizable, phrases, translations)
        self.assertEqual(catalogs, before)
        self.assertTrue(any("missing reviewed shortcut translation" in error
            for error in SYNC.validate_shortcut_catalogs(catalogs, localizable, phrases, translations)))

    def test_master_wrong_named_placeholder_rejects_sync_before_mutating_catalogs(self):
        catalogs, localizable, phrases, translations = self.fixture()
        before = copy.deepcopy(catalogs)
        translations[next(iter(phrases))] = "Save a webpage with %@"
        with self.assertRaisesRegex(RuntimeError, "shortcut placeholders differ"):
            SYNC.synchronize_shortcut_catalogs(catalogs, localizable, phrases, translations)
        self.assertEqual(catalogs, before)

    def test_missing_key_wrong_placeholder_and_unreviewed_drift_are_rejected(self):
        catalogs, localizable, phrases, translations = self.fixture()
        SYNC.synchronize_shortcut_catalogs(catalogs, localizable, phrases, translations)
        catalogs["Localizable"]["strings"].pop("保存网页")
        self.assertTrue(any("missing zh-Hans/en value" in error
            for error in SYNC.validate_shortcut_catalogs(catalogs, localizable, phrases, translations)))
        SYNC.synchronize_shortcut_catalogs(catalogs, localizable, phrases, translations)
        key = next(iter(phrases))
        values = catalogs["AppShortcuts"]["strings"][key]["localizations"]["en"]["stringSet"]["values"]
        values[1] = "Save a webpage to ${wrongName}"
        failures = SYNC.validate_shortcut_catalogs(catalogs, localizable, phrases, translations)
        self.assertTrue(any("shortcut placeholders differ" in error for error in failures))
        values[1] = "A different phrase with ${applicationName}"
        failures = SYNC.validate_shortcut_catalogs(catalogs, localizable, phrases, translations)
        self.assertTrue(any("differs from reviewed shortcut translation" in error for error in failures))
        SYNC.synchronize_shortcut_catalogs(catalogs, localizable, phrases, translations)
        self.assertEqual(SYNC.validate_shortcut_catalogs(catalogs, localizable, phrases, translations), [])

    def test_shortcut_phrase_state_count_and_stale_entries_are_rejected(self):
        catalogs, localizable, phrases, translations = self.fixture()
        SYNC.synchronize_shortcut_catalogs(catalogs, localizable, phrases, translations)
        key = next(iter(phrases))
        string_set = catalogs["AppShortcuts"]["strings"][key]["localizations"]["en"]["stringSet"]
        string_set["state"] = "needs_review"
        string_set["values"].pop()
        catalogs["AppShortcuts"]["strings"]["obsolete"] = {}
        failures = SYNC.validate_shortcut_catalogs(catalogs, localizable, phrases, translations)
        for expected in ("state must be translated", "phrase count differs", "stale catalog key"):
            self.assertTrue(any(expected in error for error in failures))

    def test_same_main_entrypoint_syncs_checks_and_prunes_extension_without_second_master(self):
        catalogs, localizable, phrases, translations = self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_catalog = root / "App.xcstrings"
            app_catalog.write_text(json.dumps({"strings": {}}), encoding="utf-8")
            paths = {table: root / f"{table}.xcstrings" for table in catalogs}
            for table, path in paths.items():
                path.write_text(json.dumps(catalogs[table]), encoding="utf-8")
            master = root / "translations.json"
            master.write_text(json.dumps({**translations, "obsolete": "Old"}), encoding="utf-8")
            with patch.multiple(SYNC,
                CATALOG_PATH=app_catalog, SHORTCUT_CATALOG_PATHS=paths, TRANSLATION_PATHS=(master,),
                direct_display_name_localization_gaps=lambda: [],
                extract_compiler_localizations=lambda: {}, extract_swiftui_strings=lambda: {},
                extract_literal_localization_calls=lambda: {}, extract_component_localization_keys=lambda: {},
                extract_workspace_navigation_keys=lambda: {}, extract_display_name_semantic_keys=lambda: {},
                load_dynamic_key_allowlist=lambda: {"runtime": set(), "sourceLiterals": set()},
                extract_normalized_source_literals=lambda: set(), extract_core_localization_keys=lambda: {},
                validate_core_localizations=lambda _: [],
                extract_shortcut_localizations=lambda: (localizable, phrases)), \
                patch.object(SYNC.subprocess, "run", side_effect=AssertionError("no build allowed")), \
                contextlib.redirect_stdout(io.StringIO()):
                with patch("sys.argv", ["sync_ui_localizations.py", "--check"]):
                    self.assertEqual(SYNC.main(), 1)
                with patch("sys.argv", ["sync_ui_localizations.py", "--prune-stale"]):
                    self.assertEqual(SYNC.main(), 0)
                self.assertEqual(json.loads(master.read_text()), translations)
                with patch("sys.argv", ["sync_ui_localizations.py", "--check"]):
                    self.assertEqual(SYNC.main(), 0)
                result = json.loads(paths["AppShortcuts"].read_text())
                first = next(iter(phrases))
                result["strings"][first]["localizations"]["en"]["stringSet"]["values"][0] = "drift"
                paths["AppShortcuts"].write_text(json.dumps(result), encoding="utf-8")
                with patch("sys.argv", ["sync_ui_localizations.py", "--check"]):
                    self.assertEqual(SYNC.main(), 1)


if __name__ == "__main__":
    unittest.main()
