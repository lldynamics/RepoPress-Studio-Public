from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from scripts import check_swift_core_boundaries


class SwiftCoreBoundaryGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="repopress-swift-boundary-")
        self.root = Path(self.temp_dir.name)
        self.source_root = self.root / "swift" / "Sources" / "RepoPressCore"
        self.source_root.mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_source(self, name: str, source: str) -> Path:
        path = self.source_root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        return path

    def test_foundation_and_url_primitives_pass(self) -> None:
        self.write_source(
            "Endpoint.swift",
            """
            import Foundation

            struct Endpoint {
              let url: URL
              let components: URLComponents
              let request: URLRequest
            }
            """,
        )
        self.assertEqual([], check_swift_core_boundaries.check(self.root))

    def test_forbidden_imports_are_rejected(self) -> None:
        for module in check_swift_core_boundaries.FORBIDDEN_IMPORTS:
            with self.subTest(module=module):
                self.write_source("Forbidden.swift", f"import {module}\n")
                diagnostics = check_swift_core_boundaries.check(self.root)
                self.assertTrue(any(f"forbidden import {module}" in item for item in diagnostics))
                (self.source_root / "Forbidden.swift").unlink()

    def test_import_attributes_cannot_bypass_boundary(self) -> None:
        for attribute in ("@preconcurrency", "@_implementationOnly"):
            with self.subTest(attribute=attribute):
                self.write_source("Attributed.swift", f"{attribute} import UIKit\n")
                diagnostics = check_swift_core_boundaries.check(self.root)
                module_column = len(f"{attribute} import ") + 1
                self.assertEqual(
                    [
                        "swift/Sources/RepoPressCore/Attributed.swift:1:"
                        f"{module_column}: forbidden import UIKit"
                    ],
                    diagnostics,
                )
                (self.source_root / "Attributed.swift").unlink()

    def test_forbidden_side_effect_apis_are_rejected(self) -> None:
        self.write_source(
            "SideEffects.swift",
            """
            let process = Process()
            let local = FileManager.default
            let session = URLSession.shared
            """,
        )
        diagnostics = check_swift_core_boundaries.check(self.root)
        self.assertEqual(3, len(diagnostics))
        self.assertIn("forbidden Process API", diagnostics[0])
        self.assertIn("forbidden FileManager.default API", diagnostics[1])
        self.assertIn("forbidden URLSession.shared API", diagnostics[2])

    def test_comments_and_strings_are_not_scanned(self) -> None:
        self.write_source(
            "Examples.swift",
            r'''
            // import UIKit and FileManager.default
            /* Process() and URLSession.shared are only documentation. */
            let text = "import SwiftUI; Process(); FileManager.default; URLSession.shared"
            let raw = #"import Security; URLSession.shared"#
            let multiline = """
            import AppKit
            Process()
            """
            import Foundation
            ''',
        )
        self.assertEqual([], check_swift_core_boundaries.check(self.root))

    def test_nested_block_comments_are_not_scanned(self) -> None:
        self.write_source(
            "Comments.swift",
            """
            /* outer /* import UIKit */ Process() */
            import Foundation
            """,
        )
        self.assertEqual([], check_swift_core_boundaries.check(self.root))

    def test_diagnostics_are_stable_and_include_relative_paths(self) -> None:
        self.write_source("Z.swift", "import UIKit\n")
        self.write_source("A.swift", "import AppKit\n")
        expected = [
            "swift/Sources/RepoPressCore/A.swift:1:8: forbidden import AppKit",
            "swift/Sources/RepoPressCore/Z.swift:1:8: forbidden import UIKit",
        ]
        self.assertEqual(expected, check_swift_core_boundaries.check(self.root))

    def test_missing_source_directory_is_rejected(self) -> None:
        self.source_root.rmdir()
        (self.root / "swift" / "Sources").rmdir()
        self.assertEqual(
            ["swift/Sources/RepoPressCore: source directory is missing"],
            check_swift_core_boundaries.check(self.root),
        )


if __name__ == "__main__":
    unittest.main()
