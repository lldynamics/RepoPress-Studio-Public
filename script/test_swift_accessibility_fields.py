#!/usr/bin/env python3
"""Regression fixtures for check_swift_accessibility_fields.py."""

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("check_swift_accessibility_fields.py")
SPEC = importlib.util.spec_from_file_location("accessibility_fields", SCRIPT)
assert SPEC and SPEC.loader
ACCESSIBILITY_FIELDS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ACCESSIBILITY_FIELDS
SPEC.loader.exec_module(ACCESSIBILITY_FIELDS)


class SwiftAccessibilityFieldTests(unittest.TestCase):
    def missing(self, source: str) -> list[tuple[str, int]]:
        return ACCESSIBILITY_FIELDS.missing_accessibility_labels(source)

    def test_accepts_a_direct_multiline_modifier_chain(self) -> None:
        source = """\
TextField(
  \"Search\",
  text: $query
)
.onChange(of: query) { _, _ in
  refresh()
}
.accessibilityLabel(
  \"Search articles\"
)
TextEditor(text: $body)
  .overlay {
    RoundedRectangle()
  }
  .accessibilityLabel(\"Body\")
"""
        self.assertEqual(self.missing(source), [])

    def test_rejects_a_label_belonging_to_the_next_control(self) -> None:
        source = """\
TextField(\"First\", text: $first)
  .textFieldStyle(.roundedBorder)
TextField(\"Second\", text: $second)
  .accessibilityLabel(\"Second field\")
"""
        self.assertEqual(self.missing(source), [("TextField", 1)])

    def test_ignores_comments_and_strings(self) -> None:
        source = """\
let example = \"TextField(\\\"not a field\\\").accessibilityLabel(\\\"not a label\\\")\"
// TextEditor(text: $ignored).accessibilityLabel(\"Ignored\")
/* TextField(\"Ignored\", text: $ignored).accessibilityLabel(\"Ignored\") */
TextEditor(text: $body)
"""
        self.assertEqual(self.missing(source), [("TextEditor", 4)])

    def test_ignores_raw_multiline_and_interpolated_strings(self) -> None:
        source = r'''let ordinary = "prefix \(String(describing: "nested quote")) TextEditor(text: $fake).accessibilityLabel("fake")"
let raw = #"TextField("fake", text: $fake) \#" escaped quote"#
let multiline = #"""
TextField("fake", text: $fake)
\#(TextEditor(text: $fake))
"""#
TextField("Real", text: $real)
  .accessibilityLabel("Real")
'''
        self.assertEqual(self.missing(source), [])

    def test_ignores_nested_block_comments(self) -> None:
        source = (
            '/* TextField("outer fake", text: $fake)\n'
            '  /* TextEditor(text: $alsoFake) */\n'
            '*/\n'
            'TextEditor(text: $real)\n'
        )
        self.assertEqual(self.missing(source), [("TextEditor", 4)])

    def test_handles_trailing_closure_and_reports_the_control_start_line(self) -> None:
        source = """\
TextField(\"Search\", text: $query)
  .onChange(of: query) { _, _ in
    update()
  } initial: {
    prepare()
  }
  .accessibilityLabel(\"Search articles\")

TextEditor(text: $notes)
  .frame(height: 120)
"""
        self.assertEqual(self.missing(source), [("TextEditor", 9)])

    def test_does_not_accept_an_overlay_or_neighbor_label_for_an_outer_field(self) -> None:
        source = (
            'TextField("Outer", text: $outer)\n'
            '  .overlay {\n'
            '    TextField("Overlay", text: $overlay)\n'
            '      .accessibilityLabel("Overlay field")\n'
            '  }\n'
            'TextField("Neighbor", text: $neighbor)\n'
            '  .accessibilityLabel("Neighbor field")\n'
        )
        self.assertEqual(self.missing(source), [("TextField", 1)])

    def test_accepts_a_label_after_a_long_modifier_chain(self) -> None:
        modifiers = "\n".join(f"  .padding({value})" for value in range(20))
        source = 'TextField("Search", text: $query)\n' + modifiers + '\n  .accessibilityLabel("Search")'
        self.assertEqual(self.missing(source), [])

    def test_rejects_unclosed_constructs_instead_of_guessing(self) -> None:
        for source in [
            'let value = "TextField(\\\"fake\\\")',
            '/* TextEditor(text: $fake)',
            'TextField("Search", text: $query',
        ]:
            with self.subTest(source=source):
                with self.assertRaises(ACCESSIBILITY_FIELDS.LexingError):
                    self.missing(source)

    def test_ignores_appkit_text_fields(self) -> None:
        source = """\
NSTextField(string: \"Not SwiftUI\")
TextField(\"Name\", text: $name)
  .accessibilityLabel(\"Name\")
"""
        self.assertEqual(self.missing(source), [])


if __name__ == "__main__":
    unittest.main()
