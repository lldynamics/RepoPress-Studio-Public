#!/usr/bin/env python3
"""Shared source-path expansion for release evidence scripts."""

from __future__ import annotations

import sys


DETAIL_CONTAINER = "Sources/PersonalSitePublisherMac/Views/DetailContainerView.swift"
SETTINGS_VIEW = "Sources/PersonalSitePublisherMac/Views/SettingsView.swift"
AI_CHAT_INSPECTOR_VIEW = "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift"
REPOSITORY_WORKSPACE_VIEW = "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift"
WORKSPACE_LAYOUT_VIEWS = "Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift"
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
}


SETTINGS_MARKER_PATHS = {}


REPOSITORY_WORKSPACE_MARKER_PATHS = {
    "onlinePublishCenterSection": [
        "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift",
        REPOSITORY_WORKSPACE_VIEW,
    ],
    "remoteConflictPreview": [
        "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift",
        REPOSITORY_WORKSPACE_VIEW,
    ],
    "PR/MR": [
        "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift",
        REPOSITORY_WORKSPACE_VIEW,
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
                "Sources/PersonalSitePublisherMac/Views/MetadataColumn.swift",
                "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift",
                "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSections.swift",
                "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSectionsExtra.swift",
                "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
                "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
            ]
        )

    if relative_path == SETTINGS_VIEW:
        if marker in SETTINGS_MARKER_PATHS:
            return unique(SETTINGS_MARKER_PATHS[marker])
        return unique(
            [
                relative_path,
                "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
                "Sources/PersonalSitePublisherMac/Views/ProBenefitsSection.swift",
                "Sources/PersonalSitePublisherMac/Views/TokenSettingsView.swift",
                "Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift",
                "Sources/PersonalSitePublisherMac/Views/RepositoryPermissionSettingsView.swift",
                "Sources/PersonalSitePublisherMac/Views/PrivacySettingsView.swift",
                "Sources/PersonalSitePublisherMac/Views/PrivacySettingsVisibilitySection.swift",
            ]
        )

    if relative_path == AI_CHAT_INSPECTOR_VIEW:
        return unique(
            [
                relative_path,
                "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorModels.swift",
                "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorSections.swift",
                "Sources/PublishingWorkbenchCore/Stores/WorkbenchAIStore.swift",
            ]
        )

    if relative_path == REPOSITORY_WORKSPACE_VIEW:
        if marker in REPOSITORY_WORKSPACE_MARKER_PATHS:
            return unique(REPOSITORY_WORKSPACE_MARKER_PATHS[marker])
        return unique(
            [
                relative_path,
                "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift",
                "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift",
            ]
        )

    if relative_path == WORKSPACE_LAYOUT_VIEWS:
        return unique(
            [
                relative_path,
                "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift",
                "Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift",
                "Sources/PersonalSitePublisherMac/Views/WritingDraftColumn.swift",
                "Sources/PersonalSitePublisherMac/Views/WritingDraftListComponents.swift",
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
