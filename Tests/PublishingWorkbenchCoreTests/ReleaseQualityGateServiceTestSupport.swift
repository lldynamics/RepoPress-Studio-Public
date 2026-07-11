import Foundation
import XCTest
@testable import PublishingWorkbenchCore

extension ReleaseQualityGateServiceTests {
  func temporaryProjectRoot() throws -> URL {
    try TestWorkbenchFactory.temporaryProjectRoot(prefix: "ReleaseQualityGateServiceTests")
  }

  func write(_ relativePath: String, in root: URL, content: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  var appStoreEntitlements: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
      <key>com.apple.security.app-sandbox</key>
      <true/>
      <key>com.apple.security.network.client</key>
      <true/>
      <key>com.apple.security.files.user-selected.read-write</key>
      <true/>
    </dict>
    </plist>
    """
  }

  var requiredScreenshotIDs: [String] {
    [
      "writing",
      "ai-chat",
      "sync-api-publish",
      "seo-social-preview",
      "deployment-status",
      "maintenance",
      "general-drafts",
      "pro-settings",
      "privacy-lock",
      "release-readiness",
    ]
  }

  func writeScreenshotManifest(in root: URL) throws {
    let rows = requiredScreenshotIDs
      .map { "| `\($0)` | `\($0).png` | \($0) | Required screenshot. | Pending capture |" }
      .joined(separator: "\n")
    try write(
      "docs/app-store-screenshots/SCREENSHOT_MANIFEST.md",
      in: root,
      content: """
      # Screenshot Manifest

      | ID | Target file | Screen | Notes | Status |
      | --- | --- | --- | --- | --- |
      \(rows)
      """
    )
  }

  func writeReleaseGateEvidence(in root: URL) throws {
    try write(
      "script/build_and_run.sh",
      in: root,
      content: """
      #!/bin/sh
      swift run
      echo CFBundleIdentifier
      echo CFBundleShortVersionString
      echo CFBundleVersion
      echo CFBundleIconFile
      echo CFBundleDisplayName
      echo LSMinimumSystemVersion
      """
    )
    try write(
      "script/check_app_store_metadata.sh",
      in: root,
      content: "#!/bin/sh\nbash script/build_and_run.sh --package-only\n"
    )
    try write(
      "script/check_app_store_archive_readiness.sh",
      in: root,
      content: """
      #!/bin/sh
      bash script/check_app_store_metadata.sh
      bash script/record_app_store_build_metadata_evidence.sh --dry-run
      codesign --verify --deep --strict dist/PersonalSitePublisherMac.app
      echo 'hardened runtime'
      echo '--strict'
      echo 'APP_STORE_ARCHIVE_VALIDATION.md'
      """
    )
    try write("script/record_app_store_build_metadata_evidence.sh", in: root, content: "#!/bin/sh\necho 'App Store build metadata'\n")
    try write("script/test_app_store_build_metadata_evidence.sh", in: root, content: "#!/bin/sh\necho 'build metadata evidence test'\n")
    try write("script/check_accessibility.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_clean_runtime_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/record_clean_runtime_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_clean_runtime_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("Sources/App/AppStore.entitlements", in: root, content: appStoreEntitlements)
    try writeCompletedArchiveValidationEvidence(in: root)
    try writeCompletedCleanRuntimeEvidence(in: root)
    try writeOnlinePublishingEvidence(in: root)
    try writeRemoteSyncCenterEvidence(in: root)
    try writeSEOSocialPreviewEvidence(in: root)
    try writeDeploymentStatusEvidence(in: root)
    try writeSiteMaintenanceEvidence(in: root)
    try writeReleaseLedgerRollbackEvidence(in: root)
    try writeGeneralDraftWorkspaceEvidence(in: root)
    try writeRepositoryAutoSyncEvidence(in: root)
    try writePrivacySupportCopyEvidence(in: root)
    try writeAIChatWorkspaceEvidence(in: root)
    try writeProBoundaryEvidence(in: root)
    try writeScreenshotRecordingEvidence(in: root, includeFiles: false)
    try writeLocalReleaseEvidenceBundleEvidence(in: root)
    try writeOnlinePublishingEvidence(in: root)
    try writeReleaseLedgerRemoteOperationEvidence(in: root)
    try writeCrossWorkspaceAIWorkflowEvidence(in: root)
    let releaseGateDetailURL = root.appendingPathComponent(
      "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift"
    )
    let releaseGateDetail = (try? String(contentsOf: releaseGateDetailURL, encoding: .utf8)) ?? ""
    try write(
      "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift",
      in: root,
      content: releaseGateDetail + "\nfunc externalVerificationEnvironmentStatusSection() {}\n"
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchAIFeatureFacade.swift",
      in: root,
      content: "selectedChatDraft updateChatDraft chatPublishingPackage activeChatEditorSelectionRange"
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceMessageFlowSection.swift",
      in: root,
      content: "AIChatMessageFlowState AIChatMessageFlowActions setCapabilityMode"
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSections.swift",
      in: root,
      content: "SiteMaintenanceReportSections"
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSectionGroups.swift",
      in: root,
      content: "SiteMaintenancePlanningSections SiteMaintenanceGovernanceReportSections"
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
      in: root,
      content: "privacyProtectionStatus.checklistMarkdown privacyProtectionAudit.checklistMarkdown proMonetizationAuditReport externalVerificationEvidenceMarkdown externalVerificationRecordingCommandMarkdown"
    )
  }

  func writeReleaseLedgerRemoteOperationEvidence(in root: URL) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift") + """

      enum ReleaseRecordKind {
        case remoteRollback
        case remoteReviewWithdrawal
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      extension WorkbenchStore {
        func remoteRollbackDraft(for record: Any) {}
        func remoteReviewWithdrawalDraft(for record: Any) {}
      }
      """
    )
  }

  func writeCrossWorkspaceAIWorkflowEvidence(in root: URL) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift") + """

      func testGeneralDraftReusePlanPromptBuildsCrossSiteRewriteInstruction() {}
      func testMaintenanceActionPromptBuildsActionableWorkbenchContext() {}
      func testReleaseRecoveryPromptBuildsRetryRollbackDecisionContext() {}
      let relatedPrompt = "relatedArticleSuggestionPrompt"
      let maintenanceGuide = "site-maintenance-assistant"
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift") + """

      enum GeneralDraftAIReusePromptEvidence {
        static func generalDraftReusePlanPrompt() {}
        static func releaseRecoveryPrompt() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      extension WorkbenchStore {
        var deploymentStatusHistory: [String] { [] }
        func sendMaintenanceActionToAI() {}
        func sendReleaseRecoveryPackageToAI() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift") + """

      struct ReleaseRecordBatchItem {}
      extension ReleaseRecord {
        var batchItems: [ReleaseRecordBatchItem] { [] }
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift") + """

      extension GeneralDraftLibraryDetailView {
        func sendReusePlanToAI() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift") + """

      extension ReleaseHistoryDetailView {
        func deploymentStatusHistoryTimeline() {}
      }
      extension ReleaseHistoryDetailView {
        func sendRecoveryPackageToAI(store: WorkbenchStore) {
          store.sendReleaseRecoveryPackageToAI()
        }
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift") + """

      extension SiteMaintenanceActionQueueSection {
        func sendToAI(store: WorkbenchStore) {
          store.sendMaintenanceActionToAI()
        }
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift") + """

      extension GeneralDraftLibraryInspectorView {
        func sendReusePlanToAI() {}
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift") + """

      func testStoreSendsMaintenanceActionIntoAIChatWorkspace() {}
      func testStoreSendsReleaseRecoveryPackageIntoAIChatWorkspace() {}
      """
    )
  }

  func writeScreenshotRecordingEvidence(
    in root: URL,
    includeFiles: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write("script/capture_app_screenshots.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_screenshots.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_screenshot_privacy.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try writeScreenshotManifest(in: root)
    if includeFiles {
      for id in requiredScreenshotIDs {
        try write("docs/app-store-screenshots/\(id).png", in: root, content: "placeholder screenshot bytes")
      }
    }
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      extension WorkbenchStore {
        public var canRecordAppStoreScreenshotEvidence: Bool { true }
        public func recordAppStoreScreenshotExternalVerificationEvidence() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift") + """

      struct ScreenshotEvidenceButton {
        func render(store: WorkbenchStore) {
          store.recordAppStoreScreenshotExternalVerificationEvidence()
        }
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift") + """

      func testStoreRecordsAppStoreScreenshotExternalVerificationEvidenceWhenGateIsReady() {}
      func testStoreBlocksScreenshotExternalVerificationEvidenceUntilCapturedAndPrivacyPassed() {}
      """
    )
  }

  func writeLocalReleaseEvidenceBundleEvidence(in root: URL) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift") + """

      extension ReleaseQualityGateReport {
        public func localReleaseEvidenceBundleMarkdown(records: [ReleaseExternalVerificationEvidenceRecord]) -> String { "" }
        public var cleanRuntimeEvidenceRecordingCommandMarkdown: String { "" }
        public var appStoreArchiveValidationRecordingCommandMarkdown: String { "" }
        public var remotePublishLiveVerificationCommandMarkdown: String { "" }
        public var externalVerificationEnvironmentPreparationCommandMarkdown: String { "" }
        public func externalVerificationEnvironmentFieldChecklistMarkdown(records: [ReleaseExternalVerificationEvidenceRecord]) -> String { "" }
        public struct ReleaseExternalVerificationEnvStatusReport {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      extension WorkbenchStore {
        public var localReleaseEvidenceBundleMarkdown: String { "" }
        public var cleanRuntimeEvidenceRecordingCommandMarkdown: String { "" }
        public var appStoreArchiveValidationRecordingCommandMarkdown: String { "" }
        public var remotePublishLiveVerificationCommandMarkdown: String { "" }
        public var externalVerificationEnvironmentPreparationCommandMarkdown: String { "" }
        public var externalVerificationEnvironmentFieldChecklistMarkdown: String { "" }
        public var externalVerificationEnvironmentStatusReport: ReleaseExternalVerificationEnvStatusReport { ReleaseExternalVerificationEnvStatusReport() }
        public func writeLocalReleaseEvidenceBundle() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift") + """

      struct LocalReleaseEvidenceBundleButtons {
        func render(store: WorkbenchStore) {
          _ = store.localReleaseEvidenceBundleMarkdown
          _ = store.cleanRuntimeEvidenceRecordingCommandMarkdown
          _ = store.appStoreArchiveValidationRecordingCommandMarkdown
          _ = store.remotePublishLiveVerificationCommandMarkdown
          _ = store.externalVerificationEnvironmentPreparationCommandMarkdown
          _ = store.externalVerificationEnvironmentFieldChecklistMarkdown
          _ = store.externalVerificationEnvironmentStatusReport
          store.writeLocalReleaseEvidenceBundle()
        }
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift") + """

      func testStoreWritesRedactedLocalReleaseEvidenceBundle() {}
      func testReleaseReportProvidesCleanRuntimeAndArchiveRecordingCommands() {}
      func testReleaseReportProvidesRemotePublishLiveVerificationCommands() {}
      func testReleaseReportProvidesPrivateEnvironmentPreparationCommands() {}
      func testExternalVerificationEnvStatusReportParsesRedactedMarkdownByFile() {}
      """
    )
  }

  func writeOnlinePublishingEvidence(
    in root: URL,
    includeGitLabMergeRequest: Bool = true,
    includeReviewWithdrawal: Bool = true,
    includeGitLabAcceptHeader: Bool = true,
    includeReviewDeploymentBoundary: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift",
      in: root,
      content: """
      public struct RemoteRepositoryPublishService {
        public func checkAccess() {}
        public func createRepository() {}
        public func publish() {}
        public func rollback() {}
        \(includeReviewWithdrawal ? "public func withdrawReview() {}" : "")
        private func publishToGitHub() {
          _ = GitHubPutContentsBody.self
          _ = GitHubCreatePullRequestBody.self
          validateExpectedRemoteVersion()
        }
        private func publishToGitLab() {
          _ = GitLabCreateProjectBody.self
          _ = GitLabCreateCommitBody.self
          \(includeGitLabMergeRequest ? "_ = GitLabCreateMergeRequestBody.self" : "")
          \(includeGitLabAcceptHeader ? #"setValue("application/json", forHTTPHeaderField: "Accept")"# : "")
          validateExpectedRemoteVersion()
        }
        private func setValue(_ value: String, forHTTPHeaderField field: String) {}
        private func validateExpectedRemoteVersion() {}
      }
      private struct GitHubPutContentsBody {}
      private struct GitHubCreatePullRequestBody {}
      private struct GitLabCreateProjectBody {}
      private struct GitLabCreateCommitBody {}
      \(includeGitLabMergeRequest ? "private struct GitLabCreateMergeRequestBody {}" : "")
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift") + """

      extension ReleaseQualityGateReport {
        public var remotePublishLiveVerificationCommandMarkdown: String { "" }
        public var externalVerificationEnvironmentPreparationCommandMarkdown: String { "" }
        public func externalVerificationEnvironmentFieldChecklistMarkdown(records: [ReleaseExternalVerificationEvidenceRecord]) -> String { "" }
        public struct ReleaseExternalVerificationEnvStatusReport {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      extension WorkbenchStore {
        var remotePublishLiveVerificationCommandMarkdown: String { "" }
        var externalVerificationEnvironmentPreparationCommandMarkdown: String { "" }
        var externalVerificationEnvironmentFieldChecklistMarkdown: String { "" }
        var externalVerificationEnvironmentStatusReport: ReleaseExternalVerificationEnvStatusReport { ReleaseExternalVerificationEnvStatusReport() }
        func createRemoteRepositoryForActiveProfile() {
          _ = remoteRepositoryPublishService.createRepository
        }
        func createGitHubRepositoryForActiveProfile() {}
        func rollbackRemoteRelease() {
          _ = remoteRepositoryPublishService.rollback
        }
        \(includeReviewWithdrawal ? """
        func withdrawRemoteReview() {
          _ = remoteRepositoryPublishService.withdrawReview
        }
        """ : "")
        func publishSelectedDraftOnlineUsingPreferredStrategy() {
          _ = remoteRepositoryPublishService.publish
        }
        func publishBatchReadyDraftsOnlineUsingPreferredStrategy() {
          _ = remoteRepositoryPublishService.publish
        }
        \(includeReviewDeploymentBoundary ? "func shouldRefreshDeploymentStatusAfterRemoteOperation() {}" : "")
        func checkAccess() {
          _ = remoteRepositoryPublishService.checkAccess
        }
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift") + """

      extension ReleaseLedgerService {
        \(includeReviewDeploymentBoundary ? "func relevantDeploymentStatus() {}" : "")
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift") + """

      struct RemotePublishLiveVerificationCommandButton {
        func render(store: WorkbenchStore) {
          store.createRemoteRepositoryForActiveProfile()
          _ = store.remotePublishLiveVerificationCommandMarkdown
          _ = store.externalVerificationEnvironmentPreparationCommandMarkdown
          _ = store.externalVerificationEnvironmentFieldChecklistMarkdown
          _ = store.externalVerificationEnvironmentStatusReport
          externalVerificationEnvironmentStatusSection()
          _ = "执行线上回滚"
          _ = "批量文章"
          \(includeReviewWithdrawal ? #"let withdrawButton = "撤回线上 Review""# : "")
        }
        func externalVerificationEnvironmentStatusSection() {}
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift") + """

      func testReleaseReportProvidesRemotePublishLiveVerificationCommands() {}
      func testReleaseReportProvidesPrivateEnvironmentPreparationCommands() {}
      func testExternalVerificationEnvStatusReportParsesRedactedMarkdownByFile() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift",
      in: root,
      content: """
      func testGitHubDirectPublishUpdatesExistingContentOnTargetBranch() {}
      func testGitHubReviewPublishCreatesBranchWritesContentsAndPullRequest() {}
      func testGitHubDirectPublishStopsWhenExpectedRemoteSHAChanged() {}
      func testGitHubRollbackCreatesCommitFromParentTreeAndUpdatesBranch() {}
      func testGitHubRollbackStopsWhenTargetBranchMoved() {}
      \(includeReviewWithdrawal ? "func testGitHubReviewWithdrawalClosesPullRequest() {}" : "")
      func testGitLabDirectPublishUpdatesExistingContentOnTargetBranch() {}
      func testGitLabReviewPublishCreatesCommitActionsAndMergeRequest() {}
      \(includeGitLabAcceptHeader ? "let gitLabAcceptHeaderAssertion = Accept\") == \"application/json" : "")
      func testGitLabDirectPublishStopsWhenLastCommitIDChanged() {}
      func testGitLabRollbackUsesCommitRevertAPI() {}
      \(includeReviewWithdrawal ? "func testGitLabReviewWithdrawalClosesMergeRequest() {}" : "")
      func testAccessCheckReportsWritableGitHubRepository() {}
      func testAccessCheckReportsNormalizedGitLabAPIBaseURL() {}
      func testCreatesGitLabGroupProject() {}
      func testCreateGitHubRepositoryForActiveProfileUsesAPIAndUpdatesProfile() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift") + """

      func testCreateGitHubRepositoryForActiveProfileUsesAPIAndUpdatesProfile() {}
      let batchDetailAssertion = "batchItems.map"
      \(includeReviewDeploymentBoundary ? "func testOnlineReviewPublishWaitsForMergeWithoutDeploymentStatusRefresh() {}" : "")
      func testRemoteRollbackCreatesRollbackRecordFromReleaseHistory() {}
      \(includeReviewWithdrawal ? "func testRemoteReviewWithdrawalCreatesReleaseRecordFromReleaseHistory() {}" : "")
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift") + """

      \(includeReviewDeploymentBoundary ? #"let reviewDeploymentSnapshotIgnored = "主站可访问，但 PR 尚未合并""# : "")
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ReleaseRecordTests.swift",
      in: root,
      content: """
      func testBatchRemotePublishRecordCapturesTraceableDraftItems() {}
      func testBatchRemotePublishFailureRecoveryPackageIncludesDraftItems() {}
      """
    )
  }

  func writeRemoteSyncCenterEvidence(
    in root: URL,
    includeBatchConflictTest: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PublishingWorkbenchCore/Models/RemoteRepositoryPublishPreview.swift",
      in: root,
      content: """
      public struct RemoteRepositoryPublishPreview {
        var remoteConflictPaths: [String] = []
        var checklistMarkdown: String { "" }
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/RemotePublishRiskService.swift",
      in: root,
      content: """
      public struct RemotePublishRiskService {
        func remoteConflictPaths() -> [String] { [] }
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      final class WorkbenchStore {
        var repositoryTokenAvailability: String { "" }
        var activeRemoteRepositoryAccessCheck: String? { nil }
        var hasStaleRemoteRepositoryAccessCheckForActiveProfile: Bool { false }
        func saveRepositoryAccessToken() {}
        func deleteRepositoryAccessToken() {}
        func refreshRepositoryTokenAvailability() {}
        func checkRepositoryTokenAccess() {}
        func remoteRepositoryPublishPreview(for draft: Any) {}
        func remoteRepositoryPublishPreview(for plan: Any) {}
        func matchingRemoteRepositoryAccessCheck() {}
        func importableRemoteChangedArticlePaths() {}
        func publishSelectedDraftOnlineUsingPreferredStrategy() {
          _ = remoteRepositoryPublishService.publish
        }
        func publishBatchReadyDraftsOnlineUsingPreferredStrategy() {
          _ = remoteRepositoryPublishService.publish
        }
        func shouldRefreshDeploymentStatusAfterRemoteOperation() {}
        func checkAccess() {
          _ = remoteRepositoryPublishService.checkAccess
        }
        func previewConflicts() {
          _ = remotePublishRiskService.remoteConflictPaths
        }
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/LocalRepositoryService.swift",
      in: root,
      content: """
      public struct LocalRepositoryService {
        func remoteChangedFilesForRole() {}
        let remoteChangedFiles = "remoteChangedFiles"
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift") + """

      struct SyncDetailView {
        let title = "线上发布中心"
        func checkRepositoryTokenAccess() {}
        func remoteConflictPreview() {}
        func batchOnlinePublishPreview() {}
        func remoteChangedFiles() {}
        func importableRemoteChangedArticleCount() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift",
      in: root,
      content: """
      struct PublishDrawerView {
        let title = "线上发布预览"
        func checkRepositoryTokenAccess() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
      in: root,
      content: """
      let tokenField = "GitHub/GitLab/Vercel/Netlify/Cloudflare Token"
      func saveRepositoryAccessToken() {}
      func deleteRepositoryAccessToken() {}
      func checkRepositoryTokenAccess() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/WorkspaceModelsTests.swift",
      in: root,
      content: """
      func testRemoteRepositoryPreviewBlocksReadOnlyAccessCheck() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift") + """

      func testRemoteRepositoryPublishPreviewSummarizesReviewRequestAndRemoteRisk() {}
      func testRemoteRepositoryPublishPreviewRequiresTokenBeforeOnlinePublish() {}
      func testRemoteRepositoryPublishPreviewRequiresPermissionCheckBeforePublish() {}
      func testRepositoryPermissionCheckPersistsAcrossRelaunch() {}
      func testRemoteRepositoryPublishPreviewRejectsAccessCheckFromDifferentOwner() {}
      func testRemoteRepositoryPublishPreviewRejectsAccessCheckFromDifferentAPIBaseURL() {}
      func testOnlineDirectPublishBlocksRemoteSamePathConflictBeforeCallingAPI() {}
      \(includeBatchConflictTest ? "func testBatchRemoteRepositoryPublishPreviewIncludesReviewableRemoteConflicts() {}" : "")
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/RepositoryAutoSyncTests.swift",
      in: root,
      content: """
      func testAutoSyncFetchesUpstreamBeforeScanningRemoteChanges() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/LocalRepositoryServiceTests.swift",
      in: root,
      content: """
      let remoteChangedFiles = "remoteChangedFiles"
      """
    )
  }

  func writeAIChatWorkspaceEvidence(
    in root: URL,
    includeAttachmentTests: Bool = true,
    includeInspectorBoundary: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift",
      in: root,
      content: """
      struct AIChatWorkspaceView {
        let selectedImageAttachmentIDs = Set<String>()
        func body() {
          // accessibilityIdentifier("ai-chat-workspace")
          _ = AIChatPromptLibrarySheet.self
          contextOverview()
          conversationTitle(for: "draft")
          regenerate(draft: "draft")
          aiChatImageAttachments()
        }
        func contextOverview() {}
        func conversationTitle(for draft: String) {}
        func regenerate(draft: String) {}
        func aiChatImageAttachments() {}
      }
      struct AIChatPromptLibrarySheet {}
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift") + """

      struct WorkspaceLayoutViews {
        func body(draft: ArticleDraft, store: WorkbenchStore) {
          AIChatWorkspaceView(store: store)
          MacMarkdownComposerView(draft: draft, store: store)
          WorkspaceTaskInspector(section: store.selectedSection)
        }
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift") + (includeInspectorBoundary
        ? """

        struct EditorInspectorView {
          func metadataContent() {}
        }
        """
        : """

        struct EditorInspectorView {
          let oldAssistant = AIPublishingAssistant()
          let title = "AI 发布助手"
        }
        """)
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ContentView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/ContentView.swift") + """

      struct ContentView {
        func open() {
          openAIChatWorkspace()
        }
        func openAIChatWorkspace() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      final class WorkbenchStore {
        func openAIChatWorkspace() {}
        func prepareAIChat() {}
        func startNewAIChatConversation() {}
        func restoreArchivedAIChatConversation() {}
        func regenerateLastAIChatReply() {}
        func regenerateAIChatReply() {}
        func sendAIChatMessage() {}
        func sendSEOSocialPreviewToAI() {}
        func aiChatImageAttachments() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift") + """

      enum AIPublishingChatPromptTemplateService {
        static func articleContextPrompt() {}
        static func paragraphContextPrompt() {}
        static func quotedMessagePrompt() {}
        static func seoSocialPreviewPrompt() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingChatConversationPresentation.swift",
      in: root,
      content: """
      enum AIPublishingChatConversationPresentation {
        static func displayTitle() {}
        static func contextSummary() {}
        static func archivedConversationPresentation() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingChatTranscriptService.swift",
      in: root,
      content: """
      enum AIPublishingChatTranscriptService {
        static func markdownTranscript() {
          _ = "图片附件"
        }
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift") + """

      func testArticleContextPromptBuildsExplicitCurrentArticleReference() {}
      func testParagraphContextPromptBuildsFocusedArticleInstruction() {}
      func testQuotedAssistantMessagePromptBuildsFollowUpInstruction() {}
      func testSEOSocialPreviewPromptBuildsMetadataAndSocialCardContext() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIPublishingChatConversationPresentationTests.swift",
      in: root,
      content: """
      func testDisplayTitleUsesFirstUserMessageBeforeDraftTitle() {}
      func testContextSummaryMatchesSiteAndGeneralModes() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIPublishingChatTranscriptServiceTests.swift",
      in: root,
      content: """
      func testMarkdownTranscriptIncludesConversationMetadataAndMessages() {}
      func testMessageDisplayContentIncludesImageAttachmentNames() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreAIPromptTests.swift",
      in: root,
      content: """
      func testAIEntryOpensDedicatedChatWorkspaceWithoutMetadataAssistant() {}
      func testQuickPromptLibraryCoversMobilePublishingCapabilityGroups() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift") + """

      func testStoreArchivesAndRestoresAIChatConversations() {}
      func testStoreRegeneratesSelectedAssistantReplyFromMatchingUserTurn() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreImageBatchTests.swift",
      in: root,
      content: """
      \(includeAttachmentTests ? "func testAIChatImageAttachmentsLoadsSelectedDraftImages() {}" : "")
      func testAIChatImageAttachmentsUsesMobileEightMegabyteLimit() {}
      """
    )
  }

  func writeProBoundaryEvidence(
    in root: URL,
    includeOnlinePublishingConsumption: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift",
      in: root,
      content: """
      public struct FreePlanLimits {}
      public enum PremiumFeature {
        case aiRequest
        case onlinePublishing
        case batchPublishing
      }
      public struct ProUpgradeRequirement {}
      public struct ProMonetizationAuditReport {}
      public struct ProSandboxVerificationSummary {
        public var externalVerificationRecordingCommandMarkdown: String { "" }
      }
      public struct ProBoundaryEvidenceSummary {}
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      extension WorkbenchStore {
        public func accessDecision(for feature: PremiumFeature) {}
        public func remainingFreeUses(for feature: PremiumFeature) {}
        public var proUpgradeRequirements: [ProUpgradeRequirement] { [] }
        public var proStatusSummary: String { "" }
        public var proSandboxVerificationSummary: String { "" }
        public func applyProEntitlement(productID: String, source: String) {}
        public func markProEntitlementCheckCompleted(foundEntitlement: Bool, message: String? = nil) {}
        public func consumeFeatureUse(_ feature: PremiumFeature) {}
        private func canStartFeatureUse(_ feature: PremiumFeature) {}
        private func recordProFeatureBlock() {}
        func usePremiumBoundaries() {
          \(includeOnlinePublishingConsumption ? "consumeFeatureUse(.onlinePublishing)" : "")
          consumeFeatureUse(.batchPublishing)
          canStartFeatureUse(.aiRequest)
        }
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SettingsView.swift") + """

      struct ProSettingsEvidence {
        func render(store: WorkbenchStore, storeKitProEntitlementCoordinator: StoreKitProEntitlementCoordinator) async {
          _ = store.proStatusSummary
          _ = store.proSandboxVerificationSummary
          ProBoundaryEvidenceRow(summary: store.proSandboxVerificationSummary.boundaryEvidence)
          _ = PremiumFeature.allCases
          _ = store.proUpgradeRequirements
          await storeKitProEntitlementCoordinator.purchasePro(store: store)
          await storeKitProEntitlementCoordinator.restorePro(store: store)
          _ = store.proMonetizationAuditReport
          _ = store.proSandboxVerificationSummary.externalVerificationEvidenceMarkdown
          _ = store.proSandboxVerificationSummary.externalVerificationRecordingCommandMarkdown
          copyProAuditChecklist()
          copyProSandboxEvidence()
          copyProSandboxRecordingCommand()
        }
        func copyProAuditChecklist() {}
        func copyProSandboxEvidence() {}
        func copyProSandboxRecordingCommand() {}
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift",
      in: root,
      content: """
      func testFreePlanAllowsLimitedAIRequestsAndBlocksOnlinePublishing() {}
      func testStoreExposesUpgradeRequirementsForSettingsAndGates() {}
      func testProEntitlementAllowsPremiumFeaturesWithoutConsumingFreeUsage() {}
      func testBlockedAIChatSendDoesNotAppendUserMessage() {}
      func testBlockedPremiumFeatureRecordsUpgradeNoticeAndUnlockClearsIt() {}
      func testSilentStoreKitEntitlementCheckUpdatesTimestampWithoutUserMessage() {}
      func testProSandboxVerificationSummaryTracksRemainingSandboxChecks() {}
      func testProSandboxVerificationSummaryRejectsLocalOverrideAsSandboxEvidence() {}
      func testProSandboxVerificationSummaryRejectsMismatchedStoreKitProductID() {}
      func testProSandboxVerificationSummaryRequiresBoundaryEventEvidenceBeforeVerified() {}
      func testProSandboxVerificationSummaryIsVerifiedForCheckedStoreKitEntitlement() {}
      func testProSandboxVerificationSummaryBuildsExternalEvidenceFields() {}
      func testProSandboxVerificationSummaryBuildsRecordingCommand() {}
      """
    )
  }

  func writeSiteMaintenanceEvidence(
    in root: URL,
    includeRelationSuggestionTest: Bool = true,
    includeMaintenanceAIEntrypoint: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift",
      in: root,
      content: """
      public struct SiteMaintenanceReport {
        var calendarBuckets: [String] = []
        var calendarInsights: [String] = []
        var calendarScheduleItems: [String] = []
        var relationSuggestions: [SiteRelationSuggestion] = []
        var linkAuditItems: [SiteLinkAuditItem] = []
        var operationLogEntries: [MaintenanceOperationLogEntry] = []
        var maintenanceChecklistMarkdown: String { "" }
      }
      public struct TaxonomyGovernanceSummary {}
      public struct StaleArticleCandidate {}
      public struct SiteRelationSuggestion {}
      public struct SiteLinkAuditItem {}
      public struct MaintenanceOperationLogEntry {}
      public struct SiteMaintenanceService {
        func healthSummary() {}
        func maintenanceActionItems() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      final class WorkbenchStore {
        var siteMaintenanceSnapshot: SiteMaintenanceSnapshot?
        func refreshSiteMaintenanceSnapshot() {}
        \(includeMaintenanceAIEntrypoint ? "func sendMaintenanceActionToAI() {}" : "")
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/SiteMaintenanceSnapshot.swift",
      in: root,
      content: """
      public struct SiteMaintenanceSnapshot {
        var report: SiteMaintenanceReport
        var sourceVersion: Int
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift",
      in: root,
      content: """
      enum WorkspaceSection {
        case generalDrafts
        case maintenance
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift") + """

      struct SiteMaintenanceDetailView {
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailContent.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailContent.swift") + """

      struct SiteMaintenanceSnapshotPlaceholder {}
      struct SiteMaintenanceDetailContent {}
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceSnapshotHeader.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceSnapshotHeader.swift") + """

      struct SiteMaintenanceSnapshotHeader {}
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceCalendarSection.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceCalendarSection.swift") + """

      struct SiteMaintenanceCalendarSection {}
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceContentPerformanceSection.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceContentPerformanceSection.swift") + """

      struct SiteMaintenanceContentPerformanceSection {}
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift") + """

      struct SiteMaintenanceActionQueueSection {
        \(includeMaintenanceAIEntrypoint ? "func sendToAI() { store.sendMaintenanceActionToAI() }" : "")
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift") + """

      struct SiteMaintenanceTaxonomySection {}
      struct SiteMaintenanceStaleArticleSection {}
      struct SiteMaintenanceRelationSuggestionSection {}
      struct SiteMaintenanceLinkAuditSection {}
      struct SiteMaintenanceOperationLogSection {}
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingPromptLibraryService.swift",
      in: root,
      content: """
      enum PromptScope {
        case maintenance
      }
      let selectedScope = "case .maintenance"
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/SiteMaintenanceServiceTests.swift",
      in: root,
      content: """
      func testReportBuildsCalendarTaxonomyStaleArticlesAndLinkAudit() {}
      \(includeRelationSuggestionTest ? "func testReportSuggestsInternalLinksFromSharedTaxonomy() {}" : "")
      func testMaintenanceChecklistMarkdownSummarizesActionableWorkbenchSections() {}
      func testReportIncludesRecentReleaseRecordsAsOperationLog() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift") + """

      let guide = "site-maintenance-assistant"
      let relatedPrompt = "relatedArticleSuggestionPrompt"
      \(includeMaintenanceAIEntrypoint ? "let maintenanceActionPrompt = \"maintenanceActionPrompt\"" : "")
      \(includeMaintenanceAIEntrypoint ? "func testMaintenanceActionPromptBuildsActionableWorkbenchContext() {}" : "")
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift") + """

      enum AIPublishingChatPromptTemplateService {
        \(includeMaintenanceAIEntrypoint ? "static func maintenanceActionPrompt() {}" : "")
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift") + """

      \(includeMaintenanceAIEntrypoint ? "func testStoreSendsMaintenanceActionIntoAIChatWorkspace() {}" : "")
      """
    )
  }

  func writeReleaseLedgerRollbackEvidence(
    in root: URL,
    includeRecoveryPackageTest: Bool = true,
    includeRemoteOperationRecords: Bool = true,
    includeRecoveryAIEntrypoint: Bool = true,
    includeRecoveryVerificationDraft: Bool = true,
    includeRollbackDeploymentCheck: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift") + """

      enum ReleaseRecordKind {
        \(includeRemoteOperationRecords ? "case remoteRollback" : "")
        \(includeRemoteOperationRecords ? "case remoteReviewWithdrawal" : "")
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift",
      in: root,
      content: """
      public enum ReleaseLedgerStatus {
        case pendingRemoteRecovery
        case pendingRetry
      }
      public struct ReleaseRollbackDraft {}
      public struct ReleaseRecoveryPackage {}
      public struct ReleaseDeploymentOverview {}
      public struct ReleaseLedgerService {
        func rollbackDraft(for record: Any) {}
        func failedRemotePublishRollbackDraft() {}
        func externalVerificationEvidence() {}
        func relevantDeploymentStatus() {}
        \(includeRecoveryVerificationDraft ? #"var remoteRecoveryVerificationDraftMarkdown: String { "" }"# : "")
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      final class WorkbenchStore {
        var activeProfileReleaseLedger: String { "" }
        \(includeRecoveryVerificationDraft ? #"var releaseRecoveryVerificationDraftMarkdown: String { "" }"# : "")
        \(includeRecoveryAIEntrypoint ? "func sendReleaseRecoveryPackageToAI() {}" : "")
        \(includeRemoteOperationRecords ? """
        func remoteRollbackDraft(for record: Any) {}
        func remoteReviewWithdrawalDraft(for record: Any) {}
        \(includeRollbackDeploymentCheck ? #"""
        func rollbackRemoteRelease() async {
          let rollbackRecord = "remoteRollback"
          await refreshDeploymentStatus(for: rollbackRecord)
        }
        """# : "func rollbackRemoteRelease() {}")
        \(includeRollbackDeploymentCheck ? "func refreshDeploymentStatus(for record: Any) async {}" : "")
        func withdrawRemoteReview() {}
        """ : "")
        func recordReleaseRecoveryExternalVerificationEvidence() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift") + """

      struct ReleaseHistoryDetailView {
        func releaseActionQueueSection() {}
        func releaseRecordCard() {}
        func copyRecoveryPackage() {}
        func copyRecoveryEvidence() {}
        \(includeRecoveryVerificationDraft ? #"let recoveryVerificationDraftButton = "复制恢复验收草稿""# : "")
        \(includeRecoveryAIEntrypoint ? "func sendRecoveryPackageToAI(store: WorkbenchStore) { store.sendReleaseRecoveryPackageToAI() }" : "")
        func copyRollbackDraft() {}
        let rollbackReviewButton = "打开回滚 PR/MR"
        \(includeRemoteOperationRecords ? #"let remoteRollbackButton = "执行线上回滚""# : "")
        \(includeRemoteOperationRecords ? #"let remoteReviewWithdrawalButton = "撤回线上 Review""# : "")
      }
      """
    )
    try write(
      "script/record_remote_recovery_evidence.sh",
      in: root,
      content: """
      #!/bin/sh
      echo "pending/retry release ledger states: present"
      """
    )
    try write(
      "script/test_remote_recovery_evidence.sh",
      in: root,
      content: """
      #!/bin/sh
      echo "pending retry ledger regression test: present"
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift",
      in: root,
      content: """
      func testUnknownDeploymentCheckBecomesRetryablePendingState() {}
      func testPartialRemotePublishFailureBecomesPendingRecoveryState() {}
      \(includeRecoveryPackageTest ? "func testRecoveryPackageCombinesDeploymentSignalsAndRollbackCommands() {}" : "")
      func testRecoveryPackageBuildsExternalVerificationEvidenceSummary() {}
      \(includeRecoveryVerificationDraft ? "func testRemoteRecoveryVerificationDraftCombinesConflictRetryAndRollbackEvidence() {}" : "")
      func testRollbackDraftsUseCommitReviewAndLocalRecoveryPlans() {}
      func testGitLabCommitRollbackDraftBuildsMergeRequestURL() {}
      let reviewDeploymentSnapshotIgnored = "主站可访问，但 PR 尚未合并"
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift") + """

      \(includeRemoteOperationRecords ? "func testRemoteRollbackCreatesRollbackRecordFromReleaseHistory() {}" : "")
      \(includeRemoteOperationRecords && includeRollbackDeploymentCheck ? #"let rollbackDeploymentEvidence = "Rollback commit is live""# : "")
      \(includeRemoteOperationRecords ? "func testOnlineReviewPublishWaitsForMergeWithoutDeploymentStatusRefresh() {}" : "")
      \(includeRemoteOperationRecords ? "func testRemoteReviewWithdrawalCreatesReleaseRecordFromReleaseHistory() {}" : "")
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift",
      in: root,
      content: """
      func testStoreRecordsReleaseRecoveryPackageAsExternalVerificationEvidence() {}
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift") + """

      enum ReleaseRecoveryAIPromptEvidence {
        \(includeRecoveryAIEntrypoint ? "static func releaseRecoveryPrompt() {}" : "")
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift") + """

      \(includeRecoveryAIEntrypoint ? "func testReleaseRecoveryPromptBuildsRetryRollbackDecisionContext() {}" : "")
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift") + """

      \(includeRecoveryAIEntrypoint ? "func testStoreSendsReleaseRecoveryPackageIntoAIChatWorkspace() {}" : "")
      """
    )
  }

  func writeGeneralDraftWorkspaceEvidence(
    in root: URL,
    includeBackupWriteTest: Bool = true,
    includeAIReusePrompt: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write(
      "Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift",
      in: root,
      content: """
      enum WorkspaceSection {
        case generalDrafts
        case maintenance
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Models/RepositoryProvider.swift",
      in: root,
      content: """
      enum SiteProfilePurpose {
        case generalDraftBackup
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift",
      in: root,
      content: """
      public struct GeneralDraftLibraryReport {}
      public struct GeneralDraftLibraryItem {}
      public struct GeneralDraftReusePlan {}
      public struct GeneralDraftBackupPlan {}
      public struct GeneralDraftBackupWriteResult {}
      public struct GeneralDraftLibraryPackagePlan {}
      public struct GeneralDraftLibraryService {
        let tagSummary = "标签维度"
        let manifestPath = "general-drafts/MANIFEST.md"
        let command = "git add general-drafts"
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      final class WorkbenchStore {
        var generalDraftLibraryReport: GeneralDraftLibraryReport { GeneralDraftLibraryReport() }
        var generalDraftBackupPlan: GeneralDraftBackupPlan { GeneralDraftBackupPlan() }
        func importGeneralDraftLibraryPackage() {}
        func ensureGeneralDraftProfile() {}
        func createGeneralDraft() {}
        func copyDraftToActiveProfile() {}
        func writeGeneralDraftBackupToRepository() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift") + """

      enum AIPublishingChatPromptTemplateService {
        \(includeAIReusePrompt ? "static func generalDraftReusePlanPrompt() {}" : "")
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift") + """

      struct GeneralDraftLibraryDetailView {
        func reusePlanSection() {}
        func sendReusePlanToAI() {}
        func backupSection() {}
        func librarySection() {}
        func assetSection() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift",
      in: root,
      content: """
      struct GeneralDraftLibraryInspectorView {
        func sendReusePlanToAI() {}
      }
      struct WorkspaceTaskInspector {
        func socialDebugLinkSection() {}
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift",
      in: root,
      content: """
      func testReportGroupsGeneralDraftsReusableCandidatesAndAssets() {}
      func testStoreCreatesGeneralDraftProfileAndCopiesDraftToActiveProfile() {}
      func testReportSummarizesTagAndCategoryDistribution() {}
      func testSourceFieldDiffsDetectChangedTitleSlugSummaryTagsCategoriesAndBodyLength() {}
      func testGeneralDraftLibraryPackagePlanExportRoundTrip() {}
      func testStoreImportGeneralDraftLibraryPackageUpdatesExistingAndInsertsNew() {}
      func testBackupPlanExportsOnlyGeneralDraftsWithManifestAndCommands() {}
      \(includeBackupWriteTest ? "func testWriteBackupPersistsManifestAndGeneralDraftFiles() {}" : "")
      func testStoreWritesGeneralDraftBackupToRepositoryAndUpdatesMessage() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift",
      in: root,
      content: """
      \(includeAIReusePrompt ? "func testGeneralDraftReusePlanPromptBuildsCrossSiteRewriteInstruction() {}" : "")
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/PreflightCheckServiceTests.swift",
      in: root,
      content: """
      func testGeneralDraftPurposeSkipsRepositoryReadiness() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ContentHealthSummaryTests.swift",
      in: root,
      content: """
      func testGeneralDraftSiteIssuesDoNotRequireRepositoryReadiness() {}
      """
    )
  }

  func writeDeploymentStatusEvidence(
    in root: URL,
    includeGitLabPipelineTest: Bool = true,
    includeHistoryEvidence: Bool = true,
    includeSocialMetadataEvidence: Bool = true
  ) throws {
    try write(
      "Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift",
      in: root,
      content: """
      public enum DeploymentProvider {
        case githubPages
        case gitlabPages
        case netlify
        case vercel
        case cloudflarePages
        case custom
      }
      public struct DeploymentStatusProviderReadiness {}
      public struct DeploymentStatusSnapshot {
        var postPublishCheckItems: [String] { [] }
      }
      private func githubSignals() {}
      private func gitLabSignals() {}
      private func netlifySignals() {}
      private func vercelSignals() {}
      private func cloudflarePagesSignals() {}
      private func endpointSignal() {}
      private func articlePageSignal() {}
      \(includeSocialMetadataEvidence ? "private func articlePageSocialSignal() {}" : "")
      \(includeSocialMetadataEvidence ? "private func firstMetaContent() {}" : "")
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Models/DeploymentPollingModels.swift",
      in: root,
      content: """
      public struct DeploymentPollingSettings {}
      public struct DeploymentPollingState {}
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: """
      final class WorkbenchStore {
        var deploymentStatusSnapshots: [String] = []
        \(includeHistoryEvidence ? "var deploymentStatusHistory: [String] = []" : "")
        func updateDeploymentPollingSettings() {}
        func tickDeploymentPolling() {}
        func runDeploymentPolling() {}
        func refreshDeploymentStatus() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift",
      in: root,
      content: """
      struct ReleaseHistoryDetailView {
        var deploymentStatusSummary: String { "deploymentStatusSummary" }
        var deploymentPollingSummary: String { "deploymentPollingSummary" }
        \(includeHistoryEvidence ? "var deploymentStatusHistoryTimeline: String { \"deploymentStatusHistoryTimeline\" }" : "")
        // Toggle("启用部署轮询"
        // Picker("轮询间隔"
        func actions() {
          store.refreshDeploymentStatus()
          store.runDeploymentPolling()
        }
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
      in: root,
      content: """
      let tokenField = "GitHub/GitLab/Vercel/Netlify/Cloudflare Token"
      func saveRepositoryAccessToken() {}
      func deleteRepositoryAccessToken() {}
      func checkRepositoryTokenAccess() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift",
      in: root,
      content: """
      func testGitHubPagesActionsAndEndpointBuildSuccessfulSnapshot() {}
      \(includeGitLabPipelineTest ? "func testGitLabPipelineAndPagesEndpointBuildSuccessfulSnapshot() {}" : "")
      func testNetlifyDeployAPIBuildsSuccessfulSnapshotWithoutCustomEndpoint() {}
      func testVercelDeploymentsAPIBuildsRunningSnapshotWithProjectAndTeam() {}
      func testCloudflarePagesAPIBuildsSuccessfulSnapshotWithAccountAndProject() {}
      func testDeploymentEndpointUsesBearerTokenOnlyWhenExplicitlyEnabled() {}
      func testDeploymentCheckVerifiesPublishedArticlePageContainsTitle() {}
      \(includeSocialMetadataEvidence ? "func testDeploymentArticleCheckVerifiesPublishedSocialMetadataAgainstReleaseSnapshot() {}" : "")
      \(includeSocialMetadataEvidence ? "func testDeploymentArticleCheckFailsWhenPublishedSocialImageURLIsMissing() {}" : "")
      \(includeSocialMetadataEvidence ? "func testDeploymentArticleCheckFailsWhenPublishedSocialImageAltIsMissing() {}" : "")
      \(includeSocialMetadataEvidence ? "func testDeploymentArticleCheckFailsWhenPublishedSocialTitleIsMissing() {}" : "")
      func testStoreRefreshDeploymentStatusCachesSnapshotForRecord() {}
      \(includeHistoryEvidence ? "func testStoreRefreshDeploymentStatusKeepsHistoryForRecord() {}" : "")
      func testDeploymentPollingChecksPendingDeploymentRecordsAndCachesSnapshots() {}
      func testDeploymentPollingSummarizesSuccessRunningAndFailedRecords() {}
      """
    )
  }

  func writeSEOSocialPreviewEvidence(
    in root: URL,
    includeManualRefreshTest: Bool = true,
    includeAIChatEntrypoint: Bool = true,
    includeDeploymentSiteURLTest: Bool = true
  ) throws {
    try write(
      "Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift",
      in: root,
      content: """
      public enum SEOSocialPreviewCardKind {
        case search
        case openGraph
        case twitter
      }
      public struct SEOSocialPreviewCachePresentation {}
      public struct SEOSocialPreviewDebugLink {}
      public struct SEOSocialPreviewService {
        func canonicalURL() -> String {
          let productionBaseURL = "deploymentSiteURL"
          return productionBaseURL
        }
      }
      public struct SEOSocialPreviewSnapshot {
        var platformReadiness: [String] { [] }
        var socialShareCopyItems: [String] { [] }
        var externalDebugLinks: [SEOSocialPreviewDebugLink] { [] }
        func publishPackageMarkdown() -> String { "" }
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift",
      in: root,
      content: """
      struct EditorInspectorView {
        func prepareSEOSocialPreviewIfNeeded() {}
        func manualRefresh() {
          store.refreshSEOSocialPreview()
        }
        func socialDebugLinkSection() {}
        func relatedArticleSuggestionSection() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift",
      in: root,
      content: """
      struct MacMarkdownComposerView {
        \(includeAIChatEntrypoint ? #"let aiEntryTitle = "打开 AI 对话""# : "")
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift",
      in: root,
      content: """
      struct WorkspaceTaskInspector {
        func socialDebugLinkSection() {}
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: """
      final class WorkbenchStore {
        func prepareSEOSocialPreview() {}
        func refreshSEOSocialPreview() {}
        \(includeAIChatEntrypoint ? "func sendSEOSocialPreviewToAI() {}" : "")
        func isSEOSocialPreviewStale() {}
        func refreshSEOSocialPreviewAfterAIMetadataChange() {}
        func relatedArticleSuggestions() {}
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift",
      in: root,
      content: """
      func testSnapshotBuildsSearchOpenGraphAndTwitterCards() {}
      \(includeDeploymentSiteURLTest ? "func testSnapshotUsesDeploymentSiteURLForProductionSocialMetaWhenPreviewURLIsMissing() {}" : "")
      func testSnapshotProvidesExternalSocialDebugLinks() {}
      func testPrivateSnapshotHidesSocialImage() {}
      \(includeManualRefreshTest ? "func testStoreKeepsCachedSnapshotUntilManualRefresh() {}" : "")
      func testApplyingAIMetadataRefreshesSEOSocialPreviewSnapshot() {}
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift",
      in: root,
      content: """
      func testRemoteRepositoryPublishPreviewSummarizesReviewRequestAndRemoteRisk() {}
      func testRemoteRepositoryPublishPreviewRequiresTokenBeforeOnlinePublish() {}
      func testRemoteRepositoryPublishPreviewRequiresPermissionCheckBeforePublish() {}
      func testRepositoryPermissionCheckPersistsAcrossRelaunch() {}
      func testRemoteRepositoryPublishPreviewRejectsAccessCheckFromDifferentOwner() {}
      func testRemoteRepositoryPublishPreviewRejectsAccessCheckFromDifferentAPIBaseURL() {}
      func testOnlineDirectPublishBlocksRemoteSamePathConflictBeforeCallingAPI() {}
      func testBatchRemoteRepositoryPublishPreviewIncludesReviewableRemoteConflicts() {}
      func testRelatedArticleSuggestions() {
        _ = store.relatedArticleSuggestions
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift",
      in: root,
      content: """
      func testRelatedArticleSuggestionPrompt() {
        _ = AIPublishingChatPromptTemplateService.relatedArticleSuggestionPrompt
      }
      \(includeAIChatEntrypoint ? "func testSEOSocialPreviewPromptBuildsMetadataAndSocialCardContext() {}" : "")
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift",
      in: root,
      content: """
      enum AIPublishingChatPromptTemplateService {
        static func relatedArticleSuggestionPrompt() {}
        \(includeAIChatEntrypoint ? "static func seoSocialPreviewPrompt() {}" : "")
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift",
      in: root,
      content: """
      \(includeAIChatEntrypoint ? "func testStoreSendsSEOSocialPreviewIntoAIChatWorkspace() {}" : "")
      """
    )
  }

  func writeRepositoryAutoSyncEvidence(
    in root: URL,
    includeTickScheduler: Bool = true,
    includePrivateCopyPackageMasking: Bool = true
  ) throws {
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: """
      final class WorkbenchStore {
        func publishSelectedDraftOnlineUsingPreferredStrategy() {
          _ = remoteRepositoryPublishService.publish
        }
        func publishBatchReadyDraftsOnlineUsingPreferredStrategy() {
          _ = remoteRepositoryPublishService.publish
        }
        func checkAccess() {
          _ = remoteRepositoryPublishService.checkAccess
        }
        var repositoryTokenAvailability: String { "" }
        var activeRemoteRepositoryAccessCheck: String? { nil }
        var hasStaleRemoteRepositoryAccessCheckForActiveProfile: Bool { false }
        func saveRepositoryAccessToken() {}
        func deleteRepositoryAccessToken() {}
        func refreshRepositoryTokenAvailability() {}
        func checkRepositoryTokenAccess() {}
        func remoteRepositoryPublishPreview(for draft: Any) {}
        func remoteRepositoryPublishPreview(for plan: Any) {}
        func matchingRemoteRepositoryAccessCheck() {}
        func previewConflicts() {
          _ = remotePublishRiskService.remoteConflictPaths
        }
        func prepareSEOSocialPreview() {}
        func refreshSEOSocialPreview() {}
        func isSEOSocialPreviewStale() {}
        func refreshSEOSocialPreviewAfterAIMetadataChange() {}
        func relatedArticleSuggestions() {}
        var deploymentStatusSnapshots: [String] = []
        func updateDeploymentPollingSettings() {}
        func tickDeploymentPolling() {}
        func runDeploymentPolling() {}
        func refreshDeploymentStatus() {}
        func rollbackRemoteRelease() async {
          let rollbackRecord = "remoteRollback"
          await refreshDeploymentStatus(for: rollbackRecord)
        }
        func refreshDeploymentStatus(for record: Any) async {}
        var siteMaintenanceSnapshot: SiteMaintenanceSnapshot?
        func refreshSiteMaintenanceSnapshot() {}
        var activeProfileReleaseLedger: String { "" }
        var releaseRecoveryVerificationDraftMarkdown: String { "" }
        func recordReleaseRecoveryExternalVerificationEvidence() {}
        var generalDraftLibraryReport: GeneralDraftLibraryReport { GeneralDraftLibraryReport() }
        var generalDraftBackupPlan: GeneralDraftBackupPlan { GeneralDraftBackupPlan() }
        var generalDraftLibraryPackagePlan: GeneralDraftLibraryPackagePlan { GeneralDraftLibraryPackagePlan() }
        func importGeneralDraftLibraryPackage() {}
        func ensureGeneralDraftProfile() {}
        func createGeneralDraft() {}
        func copyDraftToActiveProfile() {}
        func writeGeneralDraftBackupToRepository() {}
        var privacySettings: PrivacyProtectionSettings { PrivacyProtectionSettings() }
        var isPrivacyLocked: Bool { false }
        var canUseProtectedWorkbench: Bool { !isPrivacyLocked }
        var privacyProtectionStatus: PrivacyProtectionStatus { PrivacyProtectionStatus() }
        var privacyProtectionAudit: PrivacyProtectionAudit { PrivacyProtectionAudit() }
        func lockPrivacy(reason: String = "") {}
        func unlockPrivacy() {}
        func lockPrivacyIfNeededForInactiveScene() {}
        func privateContentDisplay() {}
        func isPrivateContentMasked() {}
        func matchesPrivacyProtectedDraftSearch() {}
        \(includePrivateCopyPackageMasking ? "func privateContentProtectedPackageMarkdown() {}" : "")
        \(includePrivateCopyPackageMasking ? "func seoSocialPublishPackageMarkdown() {}" : "")
        func updateRepositoryAutoSyncSettings() {}
        \(includeTickScheduler ? "func tickRepositoryAutoSync() {}" : "")
        func runRepositoryAutoSync() {
          _ = repositoryService.fetchUpstream
          _ = importableRemoteChangedArticlePaths
        }
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/SiteMaintenanceSnapshot.swift",
      in: root,
      content: """
      public struct SiteMaintenanceSnapshot {
        var sourceVersion: Int
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift",
      in: root,
      content: """
      // 线上发布中心
      // checkRepositoryTokenAccess
      // remoteConflictPreview
      // batchOnlinePublishPreview
      // remoteChangedFiles
      // importableRemoteChangedArticleCount
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift",
      in: root,
      content: """
      // deploymentStatusSummary
      // deploymentPollingSummary
      // Toggle("启用部署轮询"
      // Picker("轮询间隔"
      // store.refreshDeploymentStatus()
      // store.runDeploymentPolling()
      // ReleaseHistoryDetailView
      // releaseActionQueueSection
      // releaseRecordCard
      // copyRecoveryPackage
      // copyRecoveryEvidence
      // 复制恢复验收草稿
      // copyRollbackDraft
      // 打开回滚 PR/MR
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift",
      in: root,
      content: """
      // SiteMaintenanceDetailView
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailContent.swift",
      in: root,
      content: """
      // SiteMaintenanceSnapshotPlaceholder
      // SiteMaintenanceDetailContent
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceSnapshotHeader.swift",
      in: root,
      content: """
      // SiteMaintenanceSnapshotHeader
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceCalendarSection.swift",
      in: root,
      content: """
      // SiteMaintenanceCalendarSection
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceContentPerformanceSection.swift",
      in: root,
      content: """
      // SiteMaintenanceContentPerformanceSection
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift",
      in: root,
      content: """
      // SiteMaintenanceActionQueueSection
      // sendToAI
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift",
      in: root,
      content: """
      // SiteMaintenanceTaxonomySection
      // SiteMaintenanceStaleArticleSection
      // SiteMaintenanceRelationSuggestionSection
      // SiteMaintenanceLinkAuditSection
      // SiteMaintenanceOperationLogSection
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift",
      in: root,
      content: """
      // GeneralDraftLibraryDetailView
      // reusePlanSection
      // backupSection
      // librarySection
      // assetSection
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift",
      in: root,
      content: """
      // repositoryAutoSyncSection
      // Toggle("启用自动同步"
      // Toggle("扫描前 fetch upstream"
      // Picker("扫描间隔"
      // store.runRepositoryAutoSync()
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/RepositoryAutoSyncTests.swift",
      in: root,
      content: """
      func testAutoSyncTickRunsOnlyWhenDue() {}
      func testAutoSyncFetchesUpstreamBeforeScanningRemoteChanges() {}
      """
    )
  }

  func writeCompletedCleanRuntimeEvidence(in root: URL) throws {
    try write(
      "docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md",
      in: root,
      content: """
      # Clean Runtime Validation Evidence

      - [x] App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.
        Evidence: Clean test user launched the app through build_and_run --verify and reached the main workspace without migration or permission failures.
      - [x] First launch, privacy lock, settings, and workspace switching were verified without exposing private content.
        Evidence: First launch, privacy lock, settings, and workspace switching were verified with sample data and redacted screenshots only.
      - [x] Keyboard navigation, focus visibility, VoiceOver labels, and primary commands were smoke checked in the running app.
        Evidence: Keyboard navigation, visible focus, VoiceOver labels, and primary menu commands were smoke checked in the running app.
      """
    )
  }

  func writePrivacySupportCopyEvidence(
    in root: URL,
    includeAIRequestBlockTest: Bool = true,
    includeSettingsInactiveLock: Bool = true,
    includePrivateCopyPackageMasking: Bool = true
  ) throws {
    try write("script/check_privacy_support_copy.sh", in: root, content: "#!/bin/sh\necho masksPrivateContent\n")
    try write("script/test_privacy_support_copy.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write(
      "docs/privacy-support-copy.md",
      in: root,
      content: """
      # Privacy And Support Copy Review

      The privacy lock covers launch protection and background auto lock before showing workbench content.
      Private-content masking hides private article titles from list and release surfaces.
      Do not include local paths, access tokens, authorization headers, or private article body text in support requests.
      Use redacted screenshots for support. Online publishing, AI requests, deployment checks, and StoreKit may contact external services.
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift",
      in: root,
      content: """
      public struct PrivacyProtectionSettings {
        let requiresUnlockOnLaunch = true
        let locksWhenInactive = true
        let masksPrivateContent = true
      }
      public struct PrivacyProtectionStatus {}
      public struct PrivacyProtectionAudit {}
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/ContentView.swift",
      in: root,
      content: """
      struct ContentView {
        let overlay = "PrivacyLockOverlay(store: store)"
        func lockPrivacyIfNeededForInactiveScene() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/SharedViews.swift",
      in: root,
      content: """
      struct PrivacyLockOverlay {
        let identifier = "privacy-lock-overlay"
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Views/DraftEditorWindowView.swift",
      in: root,
      content: """
      struct DraftEditorWindowView {
        let overlay = "PrivacyLockOverlay(store: store)"
        func lockPrivacyIfNeededForInactiveScene() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift",
      in: root,
      content: """
      let settingsOverlay = "PrivacyLockOverlay(store: store)"
      \(includeSettingsInactiveLock ? "func lockPrivacyIfNeededForInactiveScene() {}" : "")
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift",
      in: root,
      content: """
      func commands() {
        store.lockPrivacy(reason: "manual")
        store.unlockPrivacy()
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/AIPublishingFixQueueService.swift",
      in: root,
      content: """
      func queue(draft: Draft) {
        guard !draft.isPrivate else { return }
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift",
      in: root,
      content: """
      public enum SEOSocialPreviewCardKind {
        case search
        case openGraph
        case twitter
      }
      public struct SEOSocialPreviewCachePresentation {}
      public struct SEOSocialPreviewDebugLink {}
      public struct SEOSocialPreviewService {
        func canonicalURL() -> String {
          let productionBaseURL = "deploymentSiteURL"
          return productionBaseURL
        }
      }
      public struct SEOSocialPreviewSnapshot {
        var platformReadiness: [String] { [] }
        var socialShareCopyItems: [String] { [] }
        var externalDebugLinks: [SEOSocialPreviewDebugLink] { [] }
        func publishPackageMarkdown() -> String { "" }
      }
      let privateSocialImage = "draft.isPrivate ? nil"
      """
    )
    try write(
      "Sources/PublishingWorkbenchScreenshotSupport/ScreenshotDemoDataService.swift",
      in: root,
      content: """
      enum ScreenshotDemoSurface {
        case privacyLock
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/SEOAuditServiceTests.swift",
      in: root,
      content: "let testName = \"私密文章不输出预览图\"\n"
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift",
      in: root,
      content: """
      func testStoreLocksOnLaunchAndInactiveWhenConfigured() {}
      func testProtectedWorkbenchAvailabilityFollowsPrivacyLockState() {}
      func testPrivacyLockBlocksRemotePublishingBeforeQuotaOrAPIUse() {}
      \(includeAIRequestBlockTest ? "func testPrivacyLockBlocksAIRequestsBeforeQuotaOrConversationChanges() {}" : "")
      func testPrivateContentDisplayMasksOnlyPrivateDraftsWhenEnabled() {}
      func testPrivacyProtectedDraftSearchDoesNotMatchHiddenPrivateMetadata() {}
      \(includePrivateCopyPackageMasking ? "func testSEOSocialPublishPackageMasksPrivateDraftWhenProtectionEnabled() {}" : "")
      \(includePrivateCopyPackageMasking ? "func testGeneralDraftLibraryReportMasksPrivateDraftsAndAssetsWhenProtectionEnabled() {}" : "")
      func testPrivacyProtectionAuditCountsOnlyActiveProfilePrivateDrafts() {}
      func testPrivacyProtectionStatusChecklistSummarizesReviewableBehavior() {}
      """
    )
  }

  func writeCompletedArchiveValidationEvidence(in root: URL) throws {
    try write(
      "docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md",
      in: root,
      content: """
      # App Store Archive Validation Evidence

      - [x] Clean Release archive produced from a clean checkout.
        Evidence: clean archive verified.
      - [x] Distribution signing and hardened runtime verified on the archive.
        Evidence: distribution signing and hardened runtime verified.
      - [x] Archive validated with App Store Connect or Transporter before upload.
        Evidence: Transporter validation completed.
      """
    )
  }

  static func structuredExternalSummary(for itemID: String) -> String {
    switch itemID {
    case "github-direct-publish":
      return """
      GitHub direct verified.
      Token scope: Least-privilege contents write token was confirmed by GitHub API.
      Commit SHA: abc123 redacted test commit.
      Deployment status: GitHub Pages or Actions status reached success for the test commit.
      Release ledger: Release ledger contains the online direct publish entry and deployment check.
      """
    case "github-review-publish":
      return """
      GitHub PR verified.
      PR URL: https://github.com/example/test-site/pull/1
      Provider review artifact: GitHub Pull Request API returned number #1, state open, draft=false.
      Review branch: codex/live-verify-github-review
      Target branch: main
      File changes: Created disposable live verification file through GitHub API.
      Deployment status: GitHub Pages or Actions status was checked for the PR branch.
      Release ledger: Release ledger contains the GitHub PR publish entry, review branch, and deployment check.
      Rollback draft: Rollback draft listed the review branch, file path, and revert path.
      """
    case "gitlab-direct-publish":
      return """
      GitLab direct verified.
      Token scope: Least-privilege project write token was confirmed by GitLab API.
      Commit SHA: def456 redacted test commit.
      Pipeline or Pages status: GitLab Pipeline or Pages status reached success for the test commit.
      Release ledger: Release ledger contains the GitLab direct publish entry and deployment check.
      """
    case "gitlab-review-publish":
      return """
      GitLab MR verified.
      MR URL: https://gitlab.com/example/test-site/-/merge_requests/1
      Provider review artifact: GitLab Merge Request API returned iid !1, state opened, merge status available.
      Source branch: codex/live-verify-gitlab-review
      Target branch: main
      File changes: Created disposable live verification file through GitLab API.
      Deployment status: GitLab Pipeline or Pages status was checked for the MR branch.
      Release ledger: Release ledger contains the GitLab MR publish entry, source branch, and deployment check.
      Rollback draft: Rollback draft listed the source branch, file path, and revert path.
      """
    case "remote-conflict-deployment-rollback":
      return """
      Rollback verified.
      Remote conflict preview: Direct publish was blocked after same-path remote edit.
      Pending/offline state: Failed deployment stayed pending for retry.
      Deployment retry: Manual retry refreshed deployment status.
      Rollback package: Rollback package included branch, files, and PR/MR draft URL.
      """
    case "storekit-sandbox":
      return """
      StoreKit sandbox verified.
      StoreKit product lookup: Sandbox loaded product personal.site.publisher.pro.
      StoreKit purchase: Purchase completed and entitlement source changed to StoreKit.
      StoreKit restore: Restore reapplied Pro entitlement after clearing local state.
      StoreKit free quota: Free quota boundary showed upgrade copy before purchase.
      StoreKit boundary events: Recent Pro boundary events showed free-plan block before purchase and Pro no-quota allow after unlock.
      """
    case "app-store-screenshots":
      return """
      Screenshots verified.
      Screenshot set: Captured all required App Store screens.
      Screenshot privacy gate: Screenshot privacy gate passed.
      Screenshot strict gate: Strict screenshot and release gate output reviewed.
      """
    default:
      return "\(itemID) verified."
    }
  }

  func structuredExternalSummary(for itemID: String) -> String {
    Self.structuredExternalSummary(for: itemID)
  }

  func completeExternalVerificationRecords() -> [ReleaseExternalVerificationEvidenceRecord] {
    [
      ReleaseExternalVerificationEvidenceRecord(itemID: "github-direct-publish", summary: structuredExternalSummary(for: "github-direct-publish")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "github-review-publish", summary: structuredExternalSummary(for: "github-review-publish")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "gitlab-direct-publish", summary: structuredExternalSummary(for: "gitlab-direct-publish")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "gitlab-review-publish", summary: structuredExternalSummary(for: "gitlab-review-publish")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "remote-conflict-deployment-rollback", summary: structuredExternalSummary(for: "remote-conflict-deployment-rollback")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "storekit-sandbox", summary: structuredExternalSummary(for: "storekit-sandbox")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "app-store-screenshots", summary: structuredExternalSummary(for: "app-store-screenshots")),
    ]
  }

  func writeStoreKitEvidence(
    in root: URL,
    includeTransactionUpdates: Bool = true,
    includeSandboxRegressionTests: Bool = true,
    includeAppStartupRefresh: Bool = true,
    includeLifecycleCleanup: Bool = true
  ) throws {
    func existingContent(_ relativePath: String) -> String {
      let url = root.appendingPathComponent(relativePath)
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    try write("StoreKit/PersonalSitePublisher.storekit", in: root, content: """
    {
      "nonConsumables": [
        {
          "description": "Unlock GitHub/GitLab online publishing, expanded AI requests, and batch publishing.",
          "displayPrice": "29.99",
          "localizations": [
            {
              "description": "Unlock GitHub/GitLab online publishing, expanded AI requests, and batch publishing.",
              "displayName": "Personal Site Publisher Pro",
              "locale": "en_US"
            },
            {
              "description": "解锁 GitHub/GitLab 线上发布、更多 AI 请求和批量发布能力。",
              "displayName": "个人网站发布控制台 Pro",
              "locale": "zh_Hans"
            }
          ],
          "productID": "\(MonetizationProductCatalog.proLifetimeProductID)",
          "referenceName": "Personal Site Publisher Pro"
        }
      ]
    }
    """)
    try write(
      "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
      in: root,
      content: """
      import SwiftUI
      struct SettingsView: View {
        var body: some View {
          Text(store.proStatusSummary)
          Text(store.proSandboxVerificationSummary)
          ProBoundaryEvidenceRow(summary: store.proSandboxVerificationSummary.boundaryEvidence)
          Text("GitHub/GitLab/Vercel/Netlify/Cloudflare Token")
          Button("保存仓库 Token") { store.saveRepositoryAccessToken(repositoryTokenInput) }
          Button("删除仓库 Token") { store.deleteRepositoryAccessToken() }
          Button("检查仓库权限") { Task { await store.checkRepositoryTokenAccess() } }
          Button("解锁 Pro") { Task { await coordinator.purchasePro(store: store) } }
          Button("恢复购买") { Task { await coordinator.restorePro(store: store) } }
          ForEach(Array(PremiumFeature.allCases), id: \\.id) { feature in Text(feature.displayName) }
          ForEach(store.proUpgradeRequirements) { requirement in Text(requirement.title) }
          Toggle("启动时要求解锁工作台", isOn: privacySettingBinding(\\.requiresUnlockOnLaunch))
          Toggle("切到后台时自动锁定", isOn: privacySettingBinding(\\.locksWhenInactive))
          Toggle("在列表和概览中遮挡私密文章", isOn: privacySettingBinding(\\.masksPrivateContent))
        }
        let audit = store.privacyProtectionAudit
        func copyPrivacyChecklist() {}
        func copyPrivacyAuditChecklist() {}
        func copyProAuditChecklist() {}
        func copyProSandboxEvidence() {}
        func copyProSandboxRecordingCommand() {}
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift",
      in: root,
      content: existingContent("Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift") + """

      import SwiftUI
      struct PersonalSitePublisherMacApp: App {
        let store = WorkbenchStore()
        let storeKitProEntitlementCoordinator = StoreKitProEntitlementCoordinator()
        var body: some Scene {
          WindowGroup("App") {
            Text("App")
              \(includeAppStartupRefresh ? ".task { storeKitProEntitlementCoordinator.start(store: store) }" : "")
          }
        }
      }
      """
    )
    try write(
      "Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift",
      in: root,
      content: """
      import StoreKit
      final class StoreKitProEntitlementCoordinator {
        let productID = "\(MonetizationProductCatalog.proLifetimeProductID)"
        var transactionUpdatesTask: Task<Void, Never>?
        \(includeLifecycleCleanup ? "deinit { transactionUpdatesTask?.cancel() }" : "")
        func purchasePro(store: Any) async {
          let product = try! await Product.products(for: [productID]).first!
          let transaction = try? await product.purchase()
          store.applyProEntitlement(productID: productID, source: "storeKit")
        }
        func restorePro(store: Any) async {
          try? await AppStore.sync()
          for await _ in Transaction.currentEntitlements {
            store.applyProEntitlement(productID: productID, source: "storeKit")
          }
          store.markProEntitlementCheckCompleted(foundEntitlement: false)
        }
        func start(store: Any) async {
          \(includeTransactionUpdates ? "for await _ in Transaction.updates { store.applyProEntitlement(productID: productID, source: \"storeKit\") }" : "")
        }
      }
      """
    )
    try write(
      "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift",
      in: root,
      content: existingContent("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift") + """

      extension WorkbenchStore {
        public func applyProEntitlement(productID: String, source: String) {}
        public func markProEntitlementCheckCompleted(foundEntitlement: Bool, message: String? = nil) {}
        public var proSandboxVerificationSummary: String { "" }
      }
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift") + """

      func testProEntitlementAllowsPremiumFeaturesWithoutConsumingFreeUsage() {}
      func testSilentStoreKitEntitlementCheckUpdatesTimestampWithoutUserMessage() {}
      \(includeSandboxRegressionTests ? "func testProSandboxVerificationSummaryTracksRemainingSandboxChecks() {}" : "")
      \(includeSandboxRegressionTests ? "func testProSandboxVerificationSummaryRejectsLocalOverrideAsSandboxEvidence() {}" : "")
      \(includeSandboxRegressionTests ? "func testProSandboxVerificationSummaryRejectsMismatchedStoreKitProductID() {}" : "")
      \(includeSandboxRegressionTests ? "func testProSandboxVerificationSummaryRequiresBoundaryEventEvidenceBeforeVerified() {}" : "")
      \(includeSandboxRegressionTests ? "func testProSandboxVerificationSummaryIsVerifiedForCheckedStoreKitEntitlement() {}" : "")
      \(includeSandboxRegressionTests ? "func testProSandboxVerificationSummaryBuildsExternalEvidenceFields() {}" : "")
      """
    )
    try write(
      "Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift",
      in: root,
      content: existingContent("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift") + """

      func testStoreKitSandboxBlocksIncompleteProductMetadataAndMissingPurchaseRestoreEntrypoints() {}
      func testStoreKitSandboxRequiresEntitlementUpdatesAndRegressionTests() {}
      """
    )
  }
}
