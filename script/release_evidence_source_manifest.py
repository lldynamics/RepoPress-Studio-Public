#!/usr/bin/env python3
"""Shared source-path expansion for release evidence scripts."""

from __future__ import annotations

import sys


DETAIL_CONTAINER = "Sources/PersonalSitePublisherMac/Views/DetailContainerView.swift"
SETTINGS_VIEW = "Sources/PersonalSitePublisherMac/Views/SettingsView.swift"
RELEASE_QUALITY_GATE_SERVICE = "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift"
AI_CHAT_WORKSPACE_VIEW = "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift"
WORKBENCH_STORE = "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift"
WORKBENCH_PROFILE_TESTS = "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift"


DETAIL_MARKER_PATHS = {
    "SiteMaintenanceDetailView": [
        DETAIL_CONTAINER,
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
    ],
    "actionQueueSection": [
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "calendarSection": [
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "taxonomySection": [
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "staleArticleSection": [
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "relationSuggestionSection": [
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "linkAuditSection": [
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "operationLogSection": [
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
        DETAIL_CONTAINER,
    ],
    ".accessibilityLabel(\"当前文章阅读量\")": [
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
        "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceContentPerformanceSection.swift",
        DETAIL_CONTAINER,
    ],
    "GeneralDraftLibraryDetailView": [
        DETAIL_CONTAINER,
        "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
    ],
    "reusePlanSection": [
        "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "sendReusePlanToAI": [
        "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "backupSection": [
        "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "librarySection": [
        "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "assetSection": [
        "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
        DETAIL_CONTAINER,
    ],
    "crossSiteMaterialPackageMarkdown": [
        "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
        "Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift",
        DETAIL_CONTAINER,
    ],
    "copyRecoveryEvidence": [
        "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift",
        "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift",
        DETAIL_CONTAINER,
    ],
}


SETTINGS_MARKER_PATHS = {
    "copyProSandboxEvidence": [
        "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsProTabFactory.swift",
        "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
        SETTINGS_VIEW,
    ],
}


WORKBENCH_STORE_MARKER_PATHS = {
    "refreshDeploymentStatus": [
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+DeploymentCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/DeploymentStore.swift",
        WORKBENCH_STORE,
    ],
    "deploymentPollingState": [
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+ForwardedState.swift",
        "Sources/PublishingWorkbenchCore/Stores/DeploymentStore.swift",
        WORKBENCH_STORE,
    ],
}


WORKBENCH_PROFILE_TEST_MARKER_PATHS = {
    "testOnlineDirectPublishBlocksRemoteSamePathConflictBeforeCallingAPI": [
        "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreRemotePublishingTests.swift",
        WORKBENCH_PROFILE_TESTS,
    ],
}


RELEASE_QUALITY_GATE_SERVICE_MARKER_PATHS = {
    "ReleaseQualityGateReport": [
        RELEASE_QUALITY_GATE_SERVICE,
        "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateReport.swift",
    ],
    "strictReadinessSummary": [
        "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateAppStoreChecklistReport.swift",
        "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateExternalVerificationReport.swift",
        "Sources/PublishingWorkbenchCore/Stores/PublishingStore+QualityActions.swift",
        RELEASE_QUALITY_GATE_SERVICE,
    ],
    "localReleaseEvidenceBundleMarkdown": [
        "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateExternalVerificationReport.swift",
        RELEASE_QUALITY_GATE_SERVICE,
    ],
}


def unique(paths: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for path in paths:
        if path not in seen:
            seen.add(path)
            result.append(path)
    return result


def expanded_source_paths(relative_path: str, marker: str) -> list[str]:
    if relative_path == DETAIL_CONTAINER:
        if marker in DETAIL_MARKER_PATHS:
            return unique(DETAIL_MARKER_PATHS[marker])
        return unique(
            [
                relative_path,
                "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift",
                "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift",
                "Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift",
                "Sources/PersonalSitePublisherMac/Views/EditorInspectorSections.swift",
                "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
                "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
                "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift",
            ]
        )

    if relative_path == SETTINGS_VIEW:
        if marker in SETTINGS_MARKER_PATHS:
            return unique(SETTINGS_MARKER_PATHS[marker])
        return unique(
            [
                relative_path,
                "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
                "Sources/PersonalSitePublisherMac/Views/ProSandboxVerificationSection.swift",
                "Sources/PersonalSitePublisherMac/Views/ProBoundaryEvidenceRow.swift",
                "Sources/PersonalSitePublisherMac/Views/ProBenefitsSection.swift",
                "Sources/PersonalSitePublisherMac/Views/ProRequirementsSection.swift",
                "Sources/PersonalSitePublisherMac/Views/TokenSettingsView.swift",
                "Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift",
                "Sources/PersonalSitePublisherMac/Views/RepositoryPermissionSettingsView.swift",
                "Sources/PersonalSitePublisherMac/Views/PrivacySettingsView.swift",
                "Sources/PersonalSitePublisherMac/Views/PrivacySettingsLockSection.swift",
                "Sources/PersonalSitePublisherMac/Views/PrivacySettingsVisibilitySection.swift",
            ]
        )

    if relative_path == RELEASE_QUALITY_GATE_SERVICE:
        return unique(RELEASE_QUALITY_GATE_SERVICE_MARKER_PATHS.get(marker, [relative_path]))

    if relative_path == AI_CHAT_WORKSPACE_VIEW:
        return unique(
            [
                relative_path,
                "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInputSection.swift",
                "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceComponents.swift",
                "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift",
                "Sources/PersonalSitePublisherMac/Views/AIChatPromptLibraryComponents.swift",
            ]
        )

    if relative_path == WORKBENCH_STORE:
        return unique(WORKBENCH_STORE_MARKER_PATHS.get(marker, [relative_path]))

    if relative_path == WORKBENCH_PROFILE_TESTS:
        return unique(WORKBENCH_PROFILE_TEST_MARKER_PATHS.get(marker, [relative_path]))

    return [relative_path]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: release_evidence_source_manifest.py <relative-path> <marker>", file=sys.stderr)
        return 2

    for path in expanded_source_paths(sys.argv[1], sys.argv[2]):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
