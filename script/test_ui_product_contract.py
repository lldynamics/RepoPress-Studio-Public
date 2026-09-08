#!/usr/bin/env python3
"""Exercise the source UI gate with real current views and intentional regressions."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class UIProductContractTests(unittest.TestCase):
    def test_primary_actions_and_secondary_disclosure_contract(self):
        with tempfile.TemporaryDirectory(prefix="repopress-ui-contract-") as directory:
            fixture = Path(directory)
            views = fixture / "Sources/PersonalSitePublisherMac/Views"
            shutil.copytree(ROOT / "Sources/PersonalSitePublisherMac/Views", views)
            scripts = fixture / "script"
            scripts.mkdir()
            gate = scripts / "check_ui_product_contract.sh"
            shutil.copy2(ROOT / "script/check_ui_product_contract.sh", gate)
            overview = views / "Repository/RepositoryWorkspaceOverviewSections.swift"
            original = overview.read_text()

            def run_gate():
                return subprocess.run(["bash", str(gate)], capture_output=True, text=True)

            self.assertEqual(run_gate().returncode, 0, "Current secondary disclosure must be permitted")
            prefix, primary = original.split("  private var repositoryOverviewPrimaryColumn", 1)

            def mutate_primary(old, new):
                return prefix + "  private var repositoryOverviewPrimaryColumn" + primary.replace(old, new, 1)

            mutations = {
                "folded primary": mutate_primary(
                    "      repositoryScanProgress\n", "      DisclosureGroup { repositoryScanProgress } label: { Text(\"Hidden\") }\n"
                ),
                "missing direct publish": mutate_primary("      onlinePublishCenterSection\n", ""),
                "missing disclosure identity": original.replace('"repository-section-more-tools"', '"lost-more-tools"'),
            }
            for label, source in mutations.items():
                with self.subTest(label=label):
                    self.assertNotEqual(source, original, "Fixture mutation must actually modify the source")
                    overview.write_text(source)
                    result = run_gate()
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            overview.write_text(original)
            history = views / "Publishing/ReleaseHistoryDetailView.swift"
            history.write_text(history.read_text() + '\n// DisclosureGroup regression fixture\n')
            self.assertNotEqual(run_gate().returncode, 0, "Release history visibility must remain enforced")


if __name__ == "__main__":
    unittest.main()
