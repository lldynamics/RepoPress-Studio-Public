#!/usr/bin/env python3
"""Exercise the source UI gate with real current views and intentional regressions."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class UIProductContractTests(unittest.TestCase):
    def test_publish_execution_history_keeps_pending_remote_results_reachable(self):
        history_view = (
            ROOT
            / "Sources/PersonalSitePublisherMac/Views/Publishing"
            / "ReleaseHistoryDetailView.swift"
        ).read_text()
        execution_section = (
            ROOT
            / "Sources/PersonalSitePublisherMac/Views/Publishing"
            / "PublishExecutionHistorySection.swift"
        ).read_text()
        observation_facade = (
            ROOT
            / "Sources/PublishingWorkbenchCore/Stores"
            / "FocusedStoreObservationFacades.swift"
        ).read_text()

        self.assertIn("PublishExecutionHistorySection(", history_view)
        self.assertIn("records: store.publishExecutionRecords", history_view)
        self.assertIn("$executionRecords", observation_facade)
        self.assertIn("$0.plan.target.profileID == activeProfileID", execution_section)
        self.assertIn("Array(matching.prefix(5))", execution_section)
        self.assertIn("state.needsVerification", execution_section)
        self.assertIn("await store.verifyPublishExecution(record.id)", execution_section)
        self.assertIn("本次发布的目标与文件", execution_section)
        self.assertIn("执行过程", execution_section)
        self.assertIn("record.plan.target.siteName", execution_section)
        self.assertIn("record.plan.target.apiBaseURL", execution_section)
        self.assertIn("store.isRemoteRepositoryPublishing", execution_section)
        self.assertIn("结果未知，请核对远端结果后再重试。", execution_section)

    def test_article_publish_repair_keeps_article_issues_out_of_site_navigation(self):
        core_policy = (
            ROOT
            / "Sources/PublishingWorkbenchCore/Models"
            / "ArticlePublishRepairRoutePolicy.swift"
        ).read_text()
        content_view = (
            ROOT
            / "Sources/PersonalSitePublisherMac/Views/Workspace"
            / "ContentView.swift"
        ).read_text()
        repair_bar = (
            ROOT
            / "Sources/PersonalSitePublisherMac/Views/Workspace"
            / "ArticlePublishRepairBar.swift"
        ).read_text()
        inspector_tabs = (
            ROOT
            / "Sources/PersonalSitePublisherMac/Views/Workspace"
            / "WorkspaceTaskInspectorSectionsExtra.swift"
        ).read_text()

        self.assertIn("public enum ArticlePublishRepairRoutePolicy", core_policy)
        self.assertIn("case article(PublishReadinessTarget)", core_policy)
        self.assertIn("return .writing", core_policy)
        self.assertIn("return .sync", core_policy)
        self.assertIn("case .body, .metadata, .images, .seo:", core_policy)
        self.assertIn("ArticlePublishRepairRoutePolicy.route(for: target)", content_view)
        self.assertIn("ArticlePublishRepairSession", content_view)
        self.assertIn("returnToPublishChecks(from: repairSession)", content_view)
        self.assertIn("await store.refreshPublishPreview(for: draft.id)", content_view)
        self.assertIn("section: .writing", content_view)
        self.assertIn("article-publish-repair-return", repair_bar)
        self.assertIn("重新生成当前文章的发布预览，不会自动发布", repair_bar)
        self.assertIn("return [.knowledge, .metadata, .seo, .images]", inspector_tabs)

    def test_workspace_navigation_keeps_five_direct_primary_routes(self):
        core_models = (
            ROOT / "Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift"
        ).read_text()
        descriptor = (
            ROOT
            / "Sources/PersonalSitePublisherMac/Views/Workspace"
            / "WorkspaceNavigationRouteDescriptor.swift"
        ).read_text()
        full_rail = (
            ROOT
            / "Sources/PersonalSitePublisherMac/Views/Workspace"
            / "WorkspaceRailView.swift"
        ).read_text()
        compact_rail = (
            ROOT
            / "Sources/PersonalSitePublisherMac/Views/Workspace"
            / "WorkspaceCompactNavigationRail.swift"
        ).read_text()
        localizations = json.loads(
            (ROOT / "Sources/PersonalSitePublisherMac/Resources/Localizable.xcstrings").read_text()
        )["strings"]

        self.assertIn("public enum WorkspaceSection", core_models)
        self.assertIn("WorkspaceVisibilityPolicy.commandMenuPrimarySections", descriptor)
        self.assertIn("static let primarySections", descriptor)
        self.assertIn("WorkspaceNavigationRouteDescriptor.primarySections", full_rail)
        self.assertIn("WorkspaceNavigationRouteDescriptor.primarySections", compact_rail)
        self.assertIn("Button {", compact_rail)
        self.assertIn(
            '.accessibilityIdentifier("workspace-compact-rail-\\(section.rawValue)")',
            compact_rail,
        )
        self.assertNotIn("WorkspaceArea", descriptor)
        self.assertNotIn("workspace-sidebar-area-", full_rail)

        for key in [
            "workspace.rss",
            "workspace.library",
            "workspace.sync",
            "workspace.contentHealth",
            "workspace.writing",
        ]:
            with self.subTest(localization_key=key):
                self.assertIn(key, localizations)
                self.assertIn("en", localizations[key]["localizations"])
                self.assertIn("zh-Hans", localizations[key]["localizations"])
        self.assertIn("displayNameLocalizationKey", descriptor)

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
            disclosure_style = views / "Workspace/WorkbenchDisclosureGroupStyle.swift"
            original_style = disclosure_style.read_text()
            for missing_contract in [
                '.accessibilityIdentifier(toggleIdentifier)',
                '.accessibilityValue(configuration.isExpanded',
                'configuration.isExpanded.toggle()',
            ]:
                with self.subTest(missing_disclosure_contract=missing_contract):
                    disclosure_style.write_text(original_style.replace(missing_contract, ""))
                    self.assertNotEqual(run_gate().returncode, 0)
            disclosure_style.write_text(original_style)
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
            original_history = history.read_text()
            self.assertIn("releaseActionCommandDisclosure(item)", original_history)
            self.assertIn("DisclosureGroup(", original_history)
            self.assertIn('@State private var expandedCommandActionIDs: Set<String> = []', original_history)
            self.assertIn('.accessibilityIdentifier("release-action-\\(item.id)-advanced-commands")', original_history)
            for label, mutation in {
                "missing command disclosure": original_history.replace("DisclosureGroup(", "VStack(", 1),
                "missing command accessibility identity": original_history.replace(
                    '.accessibilityIdentifier("release-action-\\(item.id)-advanced-commands")', "", 1
                ),
                "hidden main record actions": original_history.replace("releaseActionButtons(item, entry: entry)", "", 1),
                "folded main record row": original_history.replace(
                    "private func releaseActionRow(_ item: ReleaseLedgerActionItem) -> some View {\n    VStack(",
                    "private func releaseActionRow(_ item: ReleaseLedgerActionItem) -> some View {\n    DisclosureGroup {\n      VStack(",
                    1,
                ),
            }.items():
                with self.subTest(label=label):
                    history.write_text(mutation)
                    self.assertNotEqual(run_gate().returncode, 0, label)
            history.write_text(original_history)

            state = views / "Shared/WorkbenchStateView.swift"
            original_state = state.read_text()
            self.assertIn(".frame(minHeight: 120)", original_state)
            compact = original_state.split("case .compactPane:", 1)[1].split("case .inline:", 1)[0]
            self.assertNotIn("maxHeight:", compact)
            state.write_text(original_state.replace(".frame(minHeight: 120)", ".frame(minHeight: 120, maxHeight: 140)", 1))
            self.assertNotEqual(run_gate().returncode, 0, "compact pane maximum height must be rejected")
            state.write_text(original_state)


if __name__ == "__main__":
    unittest.main()
