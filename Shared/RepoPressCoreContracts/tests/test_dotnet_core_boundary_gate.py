from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from scripts import check_dotnet_core_boundaries


class DotnetCoreBoundaryGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="repopress-dotnet-boundary-")
        self.root = Path(self.temp_dir.name)
        self.source_root = self.root / "dotnet" / "src" / "RepoPress.Core"
        self.source_root.mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_source(self, name: str, source: str) -> Path:
        path = self.source_root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        return path

    def test_deterministic_bcl_passes(self) -> None:
        self.write_source(
            "Value.cs",
            """
            using System;
            using System.Collections.Generic;
            using System.Text;

            namespace RepoPress.Core;
            public sealed class Value
            {
                public IReadOnlyList<string> Items { get; } = Array.Empty<string>();
                public StringBuilder Builder { get; } = new();
            }
            """,
        )
        self.assertEqual([], check_dotnet_core_boundaries.check(self.root))

    def test_forbidden_using_roots_are_rejected(self) -> None:
        namespaces = (
            "System.Windows",
            "Microsoft.UI.Xaml",
            "Windows.Storage",
            "WinUI",
            "Microsoft.Win32",
            "System.IO",
            "System.Net.Http",
        )
        for namespace in namespaces:
            with self.subTest(namespace=namespace):
                self.write_source("Forbidden.cs", f"using {namespace};\n")
                diagnostics = check_dotnet_core_boundaries.check(self.root)
                self.assertTrue(diagnostics, namespace)
                self.assertIn("forbidden", diagnostics[0])
                (self.source_root / "Forbidden.cs").unlink()

    def test_using_alias_global_using_and_static_using_cannot_bypass(self) -> None:
        cases = (
            "global using IO = System.IO;",
            "using IO = System.IO;",
            "global using System.Windows;",
            "using static System.Net.Http.HttpClient;",
            "using Proc = System.Diagnostics.Process;",
            "global using PD = System.Security.Cryptography.ProtectedData;",
            "using static System.Security.Cryptography.ProtectedData;",
            "using Env = System.Environment;",
            "global using static System.Environment;",
        )
        for index, statement in enumerate(cases):
            with self.subTest(statement=statement):
                self.write_source(f"Alias{index}.cs", statement + "\n")
                diagnostics = check_dotnet_core_boundaries.check(self.root)
                self.assertTrue(diagnostics, statement)
                (self.source_root / f"Alias{index}.cs").unlink()

    def test_fully_qualified_side_effect_apis_are_rejected(self) -> None:
        self.write_source(
            "FullyQualified.cs",
            """
            var one = global::System.IO.File.Exists("fixture");
            var two = new System.Net.Http.HttpClient();
            var three = System.Diagnostics.Process.GetCurrentProcess();
            var four = System.Security.Cryptography.ProtectedData.Protect(data, null, scope);
            var five = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var six = Microsoft.Win32.Registry.CurrentUser;
            var seven = System.Windows.Forms.Control.ModifierKeys;
            """,
        )
        diagnostics = check_dotnet_core_boundaries.check(self.root)
        self.assertGreaterEqual(len(diagnostics), 7)
        for label in (
            "System.IO",
            "HttpClient",
            "Process",
            "ProtectedData",
            "Environment.GetFolderPath",
            "Registry",
            "Windows",
        ):
            self.assertTrue(any(label in item for item in diagnostics), label)

    def test_comments_and_string_forms_are_not_scanned(self) -> None:
        self.write_source(
            "Examples.cs",
            r'''
            // using System.IO; HttpClient; Process; ProtectedData
            /* System.Windows.Forms.Control and Environment.GetFolderPath */
            var ordinary = "using Microsoft.UI.Xaml; System.Net.Http.HttpClient";
            var verbatim = @"using Windows.Storage; System.Diagnostics.Process";
            var interpolated = $"using Microsoft.Win32; Registry {42}";
            var dollarVerbatim = $@"using System.IO; Process";
            var atDollarVerbatim = @$"using Windows.Storage; HttpClient";
            var raw = """
            using System.IO;
            System.Security.Cryptography.ProtectedData
            """;
            using System;
            ''',
        )
        self.assertEqual([], check_dotnet_core_boundaries.check(self.root))

    def test_stable_relative_diagnostics_are_sorted(self) -> None:
        self.write_source("Z.cs", "using System.IO;\n")
        self.write_source("nested/A.cs", "global using Windows.Storage;\n")
        self.assertEqual(
            [
                "dotnet/src/RepoPress.Core/Z.cs:1:7: forbidden System.IO using",
                "dotnet/src/RepoPress.Core/nested/A.cs:1:14: forbidden Windows API using",
            ],
            check_dotnet_core_boundaries.check(self.root),
        )

    def test_missing_source_directory_is_rejected(self) -> None:
        self.source_root.rmdir()
        (self.root / "dotnet" / "src").rmdir()
        self.assertEqual(
            ["dotnet/src/RepoPress.Core: source directory is missing"],
            check_dotnet_core_boundaries.check(self.root),
        )


if __name__ == "__main__":
    unittest.main()
