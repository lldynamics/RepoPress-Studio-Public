#!/usr/bin/env python3

import importlib.util
import json
from pathlib import Path
import tempfile
from typing import Optional
import unittest


MODULE_PATH = Path(__file__).with_name("sync_ui_localizations.py")
SPEC = importlib.util.spec_from_file_location("sync_ui_localizations", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class SwiftLocalizationExtractionTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
