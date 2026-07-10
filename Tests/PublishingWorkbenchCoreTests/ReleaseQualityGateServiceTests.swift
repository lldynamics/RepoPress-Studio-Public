import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class ReleaseQualityGateServiceTests: XCTestCase {
  func testReportBlocksMissingLocalizationRuntimeScreenshotsAndChecklist() throws {
    let root = try temporaryProjectRoot()
    try """
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(name: "Example")
    """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    XCTAssertFalse(report.isReadyForAppStore)
    XCTAssertTrue(report.blockingItems.contains { $0.id == "localization-catalog" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "localization-automation" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "runtime-automation" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "clean-runtime-evidence" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "screenshot-gate" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "app-store-metadata" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "app-store-archive-readiness" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "app-store-checklist" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "release-automation" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "storekit-sandbox" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "privacy-lock" })
    XCTAssertTrue(report.blockingItems.contains { $0.id == "pro-boundary" })
  }

  func testReportPassesWhenReleaseEvidenceIsPresent() throws {
    let root = try temporaryProjectRoot()
    try write(
      "script/check_localization_gate.sh",
      in: root,
      content: """
      #!/bin/sh
      grep -q 'defaultLocalization' Package.swift
      plutil -lint Sources/App/Resources/zh-Hans.lproj/Localizable.strings
      plutil -lint Sources/App/Resources/en.lproj/Localizable.strings
      plutil -lint Sources/App/Resources/zh-Hans.lproj/InfoPlist.strings
      plutil -lint Sources/App/Resources/en.lproj/InfoPlist.strings
      grep -q CFBundleDisplayName Sources/App/Resources/zh-Hans.lproj/InfoPlist.strings
      grep -q CFBundleDisplayName Sources/App/Resources/en.lproj/InfoPlist.strings
      uniq -d /tmp/zh-Hans.keys
      comm -23 /tmp/zh-Hans.keys /tmp/en.keys
      comm -13 /tmp/zh-Hans.keys /tmp/en.keys
      test -f Sources/App/Resources/Localizable.xcstrings
      raw_ui_literal_count=0
      """
    )
    try write(
      "script/build_and_run.sh",
      in: root,
      content: """
      #!/bin/sh
      swift run
      cat <<PLIST
      <key>CFBundleIdentifier</key>
      <string>com.jinfang.PersonalSitePublisherMac</string>
      <key>CFBundleShortVersionString</key>
      <string>1.0</string>
      <key>CFBundleVersion</key>
      <string>1</string>
      <key>CFBundleIconFile</key>
      <string>AppIcon</string>
      <key>CFBundleDisplayName</key>
      <string>Personal Site Publishing Console</string>
      <key>LSMinimumSystemVersion</key>
      <string>14.0</string>
      PLIST
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
      codesign --verify --deep --strict dist/PersonalSitePublisherMac.app
      echo 'hardened runtime'
      echo '--strict'
      echo 'APP_STORE_ARCHIVE_VALIDATION.md'
      """
    )
    try write(
      "script/check_release_gate.sh",
      in: root,
      content: """
      #!/bin/sh
      bash script/check_localization_gate.sh
      bash script/check_app_store_metadata.sh
      bash script/record_app_store_build_metadata_evidence.sh --dry-run
      bash script/test_app_store_build_metadata_evidence.sh
      bash script/check_app_store_archive_readiness.sh
      bash script/record_app_store_archive_validation_evidence.sh --dry-run
      bash script/test_app_store_archive_validation_evidence.sh
      bash script/check_ui_runtime.sh
      bash script/check_clean_runtime_evidence.sh
      bash script/record_clean_runtime_evidence.sh --dry-run
      bash script/test_clean_runtime_evidence.sh
      bash script/check_privacy_support_copy.sh
      bash script/test_privacy_support_copy.sh
      bash script/check_storekit.sh
      bash script/record_storekit_sandbox_evidence.sh --dry-run
      bash script/test_storekit_sandbox_evidence.sh
      bash script/export_release_evidence_bundle.sh --dry-run
      bash script/verify_remote_publish_live.sh --provider github --mode direct
      bash script/test_remote_publish_live_verifier.sh
      bash script/verify_remote_publish_live_matrix.sh
      bash script/test_remote_publish_live_matrix.sh
      bash script/record_external_verification_evidence.sh --dry-run
      bash script/record_remote_recovery_evidence.sh --dry-run
      bash script/test_remote_recovery_evidence.sh
      bash script/test_external_verification_evidence.sh
      bash script/check_screenshot_surface_map.sh
      bash script/test_screenshot_surface_map.sh
      bash script/test_screenshot_manifest_sync.sh
      bash script/test_screenshot_privacy.sh
      bash script/sync_screenshot_manifest_status.sh --check
      bash script/test_app_store_checklist_sync_evidence.sh
      bash script/test_release_gate_strict_reporting.sh
      bash script/sync_app_store_checklist.sh --dry-run
      bash script/check_screenshots.sh
      bash script/check_external_verification_evidence.sh
      bash script/check_screenshot_privacy.sh
      swift test
      """
    )
    try write("script/export_release_evidence_bundle.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/record_app_store_build_metadata_evidence.sh", in: root, content: "#!/bin/sh\necho 'App Store build metadata'\n")
    try write("script/test_app_store_build_metadata_evidence.sh", in: root, content: "#!/bin/sh\necho 'build metadata evidence test'\n")
    try write("script/record_app_store_archive_validation_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_app_store_archive_validation_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_clean_runtime_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/record_clean_runtime_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_clean_runtime_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_privacy_support_copy.sh", in: root, content: "#!/bin/sh\necho masksPrivateContent\n")
    try write("script/test_privacy_support_copy.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/record_storekit_sandbox_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_storekit_sandbox_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/verify_remote_publish_live.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_remote_publish_live_verifier.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/verify_remote_publish_live_matrix.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_remote_publish_live_matrix.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/record_external_verification_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/record_remote_recovery_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_remote_recovery_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_external_verification_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_screenshot_surface_map.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_screenshot_surface_map.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_screenshot_manifest_sync.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_screenshot_privacy.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/sync_screenshot_manifest_status.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_app_store_checklist_sync_evidence.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/test_release_gate_strict_reporting.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/sync_app_store_checklist.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_screenshot_privacy.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try writeCompletedArchiveValidationEvidence(in: root)
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
    try write("Sources/App/Resources/zh-Hans.lproj/Localizable.strings", in: root, content: "\"Hello\" = \"你好\";\n")
    try write("Sources/App/Resources/en.lproj/Localizable.strings", in: root, content: "\"Hello\" = \"Hello\";\n")
    try write("Sources/App/Resources/zh-Hans.lproj/InfoPlist.strings", in: root, content: "\"CFBundleDisplayName\" = \"个人网站发布控制台\";\n")
    try write("Sources/App/Resources/en.lproj/InfoPlist.strings", in: root, content: "\"CFBundleDisplayName\" = \"Personal Site Publishing Console\";\n")
    try write("Sources/App/AppStore.entitlements", in: root, content: appStoreEntitlements)
    try writeScreenshotManifest(in: root)
    try writeCompletedCleanRuntimeEvidence(in: root)
    for id in requiredScreenshotIDs {
      try write("docs/app-store-screenshots/\(id).png", in: root, content: "placeholder screenshot bytes")
    }
    try writeStoreKitEvidence(in: root)
    try writeProBoundaryEvidence(in: root)
    try writeOnlinePublishingEvidence(in: root)
    try writeReleaseLedgerRemoteOperationEvidence(in: root)
    try writeCrossWorkspaceAIWorkflowEvidence(in: root)
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
      content: "privacyProtectionStatus.checklistMarkdown privacyProtectionAudit.checklistMarkdown"
    )
    try write(
      "APP_STORE_CHECKLIST.md",
      in: root,
      content: """
      # App Store Release Checklist

      - [x] Archive validated.
      - [x] Localization checked.
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let blockingSummary = report.blockingItems
      .map { "\($0.id): \($0.message)" }
      .joined(separator: "\n")
    XCTAssertTrue(report.isReadyForAppStore, blockingSummary)
    XCTAssertTrue(report.blockingItems.isEmpty, blockingSummary)
    XCTAssertEqual(report.items.first { $0.id == "localization-languages" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "localization-automation" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "localization-automation" }?.evidence, "script/check_localization_gate.sh")
    XCTAssertEqual(report.items.first { $0.id == "runtime-automation" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "privacy-support-copy" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "screenshot-gate" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "screenshot-privacy" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "app-store-metadata" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "app-store-archive-readiness" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "app-store-checklist" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "release-automation" }?.status, .passed)
    XCTAssertEqual(report.items.first { $0.id == "storekit-sandbox" }?.status, .passed)
    let onlinePublishing = report.items.first { $0.id == "online-publishing" }
    XCTAssertEqual(onlinePublishing?.status, .passed, onlinePublishing?.message ?? "")
    let remoteSyncCenter = report.items.first { $0.id == "remote-sync-center" }
    XCTAssertEqual(remoteSyncCenter?.status, .passed, remoteSyncCenter?.message ?? "")
    let repositoryAutoSync = report.items.first { $0.id == "repository-auto-sync" }
    XCTAssertEqual(repositoryAutoSync?.status, .passed, repositoryAutoSync?.message ?? "")
    let aiChatWorkspace = report.items.first { $0.id == "ai-chat-workspace" }
    XCTAssertEqual(aiChatWorkspace?.status, .passed, aiChatWorkspace?.message ?? "")
    let seoSocialPreview = report.items.first { $0.id == "seo-social-preview" }
    XCTAssertEqual(seoSocialPreview?.status, .passed, seoSocialPreview?.message ?? "")
    let deploymentStatus = report.items.first { $0.id == "deployment-status" }
    XCTAssertEqual(deploymentStatus?.status, .passed, deploymentStatus?.message ?? "")
    let siteMaintenance = report.items.first { $0.id == "site-maintenance" }
    XCTAssertEqual(siteMaintenance?.status, .passed, siteMaintenance?.message ?? "")
    let releaseLedgerRollback = report.items.first { $0.id == "release-ledger-rollback" }
    XCTAssertEqual(releaseLedgerRollback?.status, .passed, releaseLedgerRollback?.message ?? "")
    let generalDrafts = report.items.first { $0.id == "general-drafts" }
    XCTAssertEqual(generalDrafts?.status, .passed, generalDrafts?.message ?? "")
    XCTAssertEqual(report.screenshotRequirements.count, requiredScreenshotIDs.count)
    XCTAssertEqual(report.capturedScreenshotRequirements.count, requiredScreenshotIDs.count)
    XCTAssertTrue(report.screenshotRequirements.allSatisfy(\.isCaptured))
    XCTAssertTrue(report.externalVerificationItems.contains { $0.id == "github-direct-publish" })
    XCTAssertTrue(report.externalVerificationItems.contains { $0.id == "gitlab-review-publish" })
  }

  func testScreenshotPrivacyGateBlocksLocalPathsAndTokenLikeSecrets() throws {
    let root = try temporaryProjectRoot()
    try write("script/check_screenshot_privacy.sh", in: root, content: "#!/bin/sh\nexit 1\n")
    try writeScreenshotManifest(in: root)
    try write(
      "docs/app-store-screenshots/privacy-lock.png",
      in: root,
      content: "PNG bytes /Users/7c96/Documents/site github_pat_12345678901234567890"
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let privacyGate = try XCTUnwrap(report.items.first { $0.id == "screenshot-privacy" })
    XCTAssertEqual(privacyGate.status, .blocked)
    XCTAssertTrue(privacyGate.message.contains("local path"))
    XCTAssertTrue(privacyGate.message.contains("token-like secret"))
    XCTAssertTrue(report.blockingItems.contains { $0.id == "screenshot-privacy" })
  }

  func testScreenshotGateWarnsWhenScriptExistsWithoutScreenshotFiles() throws {
    let root = try temporaryProjectRoot()
    try write("script/capture_app_screenshots.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try writeScreenshotManifest(in: root)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let screenshotGate = try XCTUnwrap(report.items.first { $0.id == "screenshot-gate" })
    XCTAssertEqual(screenshotGate.status, .warning)
    XCTAssertFalse(report.blockingItems.contains { $0.id == "screenshot-gate" })
    XCTAssertFalse(report.isReadyForAppStore)
  }

  func testRuntimeAutomationAcceptsDedicatedAccessibilityScript() throws {
    let root = try temporaryProjectRoot()
    try write("script/build_and_run.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_accessibility.sh", in: root, content: "#!/bin/sh\nexit 0\n")

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let runtimeGate = try XCTUnwrap(report.items.first { $0.id == "runtime-automation" })
    XCTAssertEqual(runtimeGate.status, .passed)
    XCTAssertEqual(runtimeGate.evidence, "script/check_accessibility.sh")
  }

  func testReleaseAutomationBlocksWhenTotalGateOmitsRequiredChecks() throws {
    let root = try temporaryProjectRoot()
    try write(
      "script/check_release_gate.sh",
      in: root,
      content: """
      #!/bin/sh
      bash script/check_localization_gate.sh
      bash script/check_screenshots.sh
      swift test
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let releaseAutomation = try XCTUnwrap(report.items.first { $0.id == "release-automation" })
    XCTAssertEqual(releaseAutomation.status, .blocked)
    XCTAssertTrue(releaseAutomation.message.contains("UI runtime"))
    XCTAssertTrue(releaseAutomation.message.contains("干净用户运行证据"))
    XCTAssertTrue(releaseAutomation.message.contains("隐私/支持文案"))
    XCTAssertTrue(releaseAutomation.message.contains("App Store 元数据"))
    XCTAssertTrue(releaseAutomation.message.contains("App Store 归档准备"))
    XCTAssertTrue(releaseAutomation.message.contains("StoreKit"))
    XCTAssertTrue(releaseAutomation.message.contains("本地证据包导出"))
    XCTAssertTrue(releaseAutomation.message.contains("远端真实 API 发布验证"))
    XCTAssertTrue(releaseAutomation.message.contains("外部证据受控录入"))
    XCTAssertTrue(releaseAutomation.message.contains("截图场景源码映射"))
    XCTAssertTrue(releaseAutomation.message.contains("App Store checklist 证据同步"))
    XCTAssertTrue(releaseAutomation.message.contains("外部验收证据"))
    XCTAssertTrue(releaseAutomation.message.contains("截图隐私"))
    XCTAssertTrue(report.blockingItems.contains { $0.id == "release-automation" })
  }

  func testStoreKitSandboxBlocksIncompleteProductMetadataAndMissingPurchaseRestoreEntrypoints() throws {
    let root = try temporaryProjectRoot()
    try write(
      "StoreKit/PersonalSitePublisher.storekit",
      in: root,
      content: """
      {
        "nonConsumables": [
          {
            "productID": "\(MonetizationProductCatalog.proLifetimeProductID)"
          }
        ]
      }
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let storeKit = try XCTUnwrap(report.items.first { $0.id == "storekit-sandbox" })
    XCTAssertEqual(storeKit.status, .blocked)
    XCTAssertTrue(storeKit.message.contains("显示价格"))
    XCTAssertTrue(storeKit.message.contains("en_US 本地化"))
    XCTAssertTrue(storeKit.message.contains("购买入口"))
    XCTAssertTrue(storeKit.message.contains("恢复购买入口"))
  }

  func testStoreKitSandboxRequiresEntitlementUpdatesAndRegressionTests() throws {
    let root = try temporaryProjectRoot()
    try writeStoreKitEvidence(
      in: root,
      includeTransactionUpdates: false,
      includeSandboxRegressionTests: false
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let storeKit = try XCTUnwrap(report.items.first { $0.id == "storekit-sandbox" })
    XCTAssertEqual(storeKit.status, .blocked)
    XCTAssertTrue(storeKit.message.contains("交易更新监听"))
    XCTAssertTrue(storeKit.message.contains("sandbox 待核验测试"))
    XCTAssertTrue(storeKit.message.contains("StoreKit 权益核验通过测试"))
    XCTAssertTrue(storeKit.evidence?.contains("StoreKitProEntitlementCoordinator.swift") == true)
    XCTAssertTrue(storeKit.evidence?.contains("MonetizationTests.swift") == true)
  }

  func testStoreKitSandboxRequiresStartupRefreshAndLifecycleCleanup() throws {
    let root = try temporaryProjectRoot()
    try writeStoreKitEvidence(
      in: root,
      includeAppStartupRefresh: false,
      includeLifecycleCleanup: false
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let storeKit = try XCTUnwrap(report.items.first { $0.id == "storekit-sandbox" })
    XCTAssertEqual(storeKit.status, .blocked)
    XCTAssertTrue(storeKit.message.contains("启动时权益监听"))
    XCTAssertTrue(storeKit.message.contains("交易监听生命周期清理"))
    XCTAssertTrue(storeKit.evidence?.contains("PersonalSitePublisherMacApp.swift") == true)
    XCTAssertTrue(storeKit.evidence?.contains("StoreKitProEntitlementCoordinator.swift") == true)
  }

  func testLocalizationAutomationBlocksWhenOnlyLocalizedResourcesExist() throws {
    let root = try temporaryProjectRoot()
    try write("Sources/App/Resources/zh-Hans.lproj/Localizable.strings", in: root, content: "\"Hello\" = \"你好\";\n")
    try write("Sources/App/Resources/en.lproj/Localizable.strings", in: root, content: "\"Hello\" = \"Hello\";\n")

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let automation = try XCTUnwrap(report.items.first { $0.id == "localization-automation" })
    XCTAssertEqual(automation.status, .blocked)
    XCTAssertTrue(automation.message.contains("check_localization_gate.sh"))
    XCTAssertTrue(automation.evidence?.contains("Localizable.strings") == true)
  }

  func testLocalizationAutomationBlocksWhenScriptDoesNotCompareStringKeys() throws {
    let root = try temporaryProjectRoot()
    try write(
      "script/check_localization_gate.sh",
      in: root,
      content: """
      #!/bin/sh
      grep -q 'defaultLocalization' Package.swift
      plutil -lint Sources/App/Resources/zh-Hans.lproj/Localizable.strings
      plutil -lint Sources/App/Resources/en.lproj/Localizable.strings
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let automation = try XCTUnwrap(report.items.first { $0.id == "localization-automation" })
    XCTAssertEqual(automation.status, .blocked)
    XCTAssertTrue(automation.message.contains("中英 key 一致性"))
    XCTAssertTrue(automation.message.contains("重复 key"))
    XCTAssertTrue(automation.message.contains("App 显示名"))
    XCTAssertEqual(automation.evidence, "script/check_localization_gate.sh")
  }

  func testScreenshotGateBlocksWhenManifestOmitsTargetFileNames() throws {
    let root = try temporaryProjectRoot()
    try write("script/check_screenshots.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    let rows = requiredScreenshotIDs
      .map { "| `\($0)` | \($0) | Required screenshot. |" }
      .joined(separator: "\n")
    try write(
      "docs/app-store-screenshots/SCREENSHOT_MANIFEST.md",
      in: root,
      content: """
      # Screenshot Manifest

      | ID | Screen | Notes |
      | --- | --- | --- |
      \(rows)
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let screenshotGate = try XCTUnwrap(report.items.first { $0.id == "screenshot-gate" })
    XCTAssertEqual(screenshotGate.status, .blocked)
    XCTAssertTrue(screenshotGate.message.contains("目标文件名"))
    XCTAssertTrue(report.blockingItems.contains { $0.id == "screenshot-gate" })
  }

  func testScreenshotGateWarnsWhenOnlySomeRequiredScreenshotsExist() throws {
    let root = try temporaryProjectRoot()
    try write("script/check_screenshots.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try writeScreenshotManifest(in: root)
    try write("docs/app-store-screenshots/writing.png", in: root, content: "placeholder screenshot bytes")

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let screenshotGate = try XCTUnwrap(report.items.first { $0.id == "screenshot-gate" })
    XCTAssertEqual(screenshotGate.status, .warning)
    XCTAssertTrue(screenshotGate.message.contains("ai-chat"))
    XCTAssertFalse(report.isReadyForAppStore)
    XCTAssertEqual(report.capturedScreenshotRequirements.map(\.id), ["writing"])
    XCTAssertTrue(report.missingScreenshotRequirements.contains { $0.id == "ai-chat" && $0.targetFileName == "ai-chat.png" })
    XCTAssertTrue(report.missingScreenshotRequirements.contains { $0.id == "release-readiness" })
  }

  func testScreenshotRequirementsExposeManifestMetadataAndMissingTargetFiles() throws {
    let root = try temporaryProjectRoot()
    try write("script/check_screenshots.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write(
      "docs/app-store-screenshots/SCREENSHOT_MANIFEST.md",
      in: root,
      content: """
      # Screenshot Manifest

      | ID | Target file | Screen | Notes | Status |
      | --- | --- | --- | --- | --- |
      | `writing` | `writing.png` | Writing workspace | Markdown editing and metadata. | Captured |
      | `ai-chat` |  | AI workspace | Independent AI conversation. | Pending capture |
      """
    )
    try write("docs/app-store-screenshots/writing.png", in: root, content: "placeholder screenshot bytes")

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let writing = try XCTUnwrap(report.screenshotRequirements.first { $0.id == "writing" })
    XCTAssertEqual(writing.screenTitle, "Writing workspace")
    XCTAssertEqual(writing.purpose, "Markdown editing and metadata.")
    XCTAssertEqual(writing.capturedFilePath, "docs/app-store-screenshots/writing.png")
    XCTAssertEqual(writing.gateStatus, .passed)

    let aiChat = try XCTUnwrap(report.screenshotRequirements.first { $0.id == "ai-chat" })
    XCTAssertEqual(aiChat.screenTitle, "AI workspace")
    XCTAssertFalse(aiChat.hasManifestTarget)
    XCTAssertEqual(aiChat.gateStatus, .blocked)
    XCTAssertTrue(aiChat.checklistLine.contains("未配置目标文件"))
    XCTAssertEqual(aiChat.captureCommand, "./script/capture_app_screenshots.sh --only ai-chat")
    XCTAssertEqual(aiChat.targetRelativePath, "docs/app-store-screenshots/<missing-target>")
    XCTAssertTrue(aiChat.capturePlanMarkdown.contains("Independent AI conversation."))

    let releaseReadiness = try XCTUnwrap(report.screenshotRequirements.first { $0.id == "release-readiness" })
    XCTAssertEqual(releaseReadiness.manifestStatus, "Manifest 缺少该截图场景")
    XCTAssertEqual(releaseReadiness.gateStatus, .blocked)
  }

  func testScreenshotCapturePlanMarkdownIncludesCommandsTargetsAndPrivacyReminder() throws {
    let root = try temporaryProjectRoot()
    try write("script/capture_app_screenshots.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try writeScreenshotManifest(in: root)
    try write("docs/app-store-screenshots/writing.png", in: root, content: "placeholder screenshot bytes")

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let markdown = report.screenshotCapturePlanMarkdown

    XCTAssertTrue(markdown.contains("# App Store 截图采集计划"))
    XCTAssertTrue(markdown.contains("- 已采集：1/10"))
    XCTAssertTrue(markdown.contains("- 缺失：ai-chat、sync-api-publish"))
    XCTAssertTrue(markdown.contains("./script/capture_app_screenshots.sh"))
    XCTAssertTrue(markdown.contains("./script/check_release_gate.sh --strict"))
    XCTAssertTrue(markdown.contains("./script/capture_app_screenshots.sh --only writing"))
    XCTAssertTrue(markdown.contains("docs/app-store-screenshots/writing.png"))
    XCTAssertTrue(markdown.contains("docs/app-store-screenshots/general-drafts.png"))
    XCTAssertTrue(markdown.contains("隐藏真实 Token"))
  }

  func testExternalVerificationPlanCoversOnlinePublishingStoreKitAndScreenshots() throws {
    let root = try temporaryProjectRoot()

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let ids = Set(report.externalVerificationItems.map(\.id))
    XCTAssertTrue(ids.contains("github-direct-publish"))
    XCTAssertTrue(ids.contains("github-review-publish"))
    XCTAssertTrue(ids.contains("gitlab-direct-publish"))
    XCTAssertTrue(ids.contains("gitlab-review-publish"))
    XCTAssertTrue(ids.contains("remote-conflict-deployment-rollback"))
    XCTAssertTrue(ids.contains("storekit-sandbox"))
    XCTAssertTrue(ids.contains("app-store-screenshots"))

    let markdown = report.externalVerificationPlanMarkdown
    XCTAssertTrue(markdown.contains("# 外部发布验收计划"))
    XCTAssertTrue(markdown.contains("最小权限 Token"))
    XCTAssertTrue(markdown.contains("GitHub API 直接提交"))
    XCTAssertTrue(markdown.contains("GitLab MR 发布"))
    XCTAssertTrue(markdown.contains("StoreKit sandbox 购买与恢复"))
    XCTAssertTrue(markdown.contains("远端冲突、部署和回滚"))
    XCTAssertTrue(markdown.contains("check_release_gate.sh --strict"))
  }

  func testExternalVerificationEvidenceTemplateRequiresFilledStructuredFields() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let template = report.externalVerificationEvidenceTemplate(for: "github-direct-publish")

    XCTAssertTrue(template.contains("GitHub API 直接提交 verified with redacted external evidence."))
    XCTAssertTrue(template.contains("Token scope: TODO: least-privilege contents write token confirmed"))
    XCTAssertTrue(template.contains("Commit SHA: TODO:"))
    XCTAssertTrue(template.contains("Next command: ./script/check_external_verification_evidence.sh"))
    XCTAssertTrue(template.contains("Final command: ./script/check_release_gate.sh --strict"))
    XCTAssertFalse(report.isExternalVerificationSummaryChecklistEligible(itemID: "github-direct-publish", summary: template))
    XCTAssertEqual(
      report.missingExternalVerificationSummaryLabels(itemID: "github-direct-publish", summary: template),
      ["Token scope:", "Commit SHA:", "Deployment status:", "Release ledger:"]
    )

    let emptyFields = """
    GitHub direct verified.
    Token scope:
    Commit SHA: abc123
    Deployment status: GitHub Pages passed.
    Release ledger: Ledger contains the direct publish entry.
    """
    XCTAssertFalse(report.isExternalVerificationSummaryChecklistEligible(itemID: "github-direct-publish", summary: emptyFields))
    XCTAssertEqual(
      report.missingExternalVerificationSummaryLabels(itemID: "github-direct-publish", summary: emptyFields),
      ["Token scope:"]
    )

    let filled = structuredExternalSummary(for: "github-direct-publish")
    XCTAssertTrue(report.isExternalVerificationSummaryChecklistEligible(itemID: "github-direct-publish", summary: filled))
    XCTAssertTrue(report.missingExternalVerificationSummaryLabels(itemID: "github-direct-publish", summary: filled).isEmpty)
  }

  func testExternalVerificationRecordingCommandsCoverEveryStructuredItem() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let expectedArgumentsByItemID: [String: [String]] = [
      "github-direct-publish": ["--token-scope", "--commit-sha", "--deployment-status", "--release-ledger"],
      "github-review-publish": ["--pr-url", "--provider-review-artifact", "--review-branch", "--target-branch", "--file-changes", "--deployment-status", "--release-ledger", "--rollback-draft"],
      "gitlab-direct-publish": ["--token-scope", "--commit-sha", "--deployment-status", "--release-ledger"],
      "gitlab-review-publish": ["--mr-url", "--provider-review-artifact", "--source-branch", "--target-branch", "--file-changes", "--deployment-status", "--release-ledger", "--rollback-draft"],
      "remote-conflict-deployment-rollback": ["--remote-conflict-preview", "--pending-offline-state", "--deployment-retry", "--rollback-package"],
      "storekit-sandbox": ["--storekit-product-lookup", "--storekit-purchase", "--storekit-restore", "--storekit-free-quota", "--storekit-boundary-events"],
      "app-store-screenshots": ["--screenshot-set", "--screenshot-privacy-gate", "--screenshot-strict-gate"],
    ]
    let expectedEnvironmentTemplateByItemID: [String: String] = [
      "github-direct-publish": "docs/release-evidence/remote-publish-live.env.example",
      "github-review-publish": "docs/release-evidence/remote-publish-live.env.example",
      "gitlab-direct-publish": "docs/release-evidence/remote-publish-live.env.example",
      "gitlab-review-publish": "docs/release-evidence/remote-publish-live.env.example",
      "remote-conflict-deployment-rollback": "docs/release-evidence/remote-recovery.env.example",
      "storekit-sandbox": "docs/release-evidence/storekit-sandbox.env.example",
      "app-store-screenshots": "docs/release-evidence/app-store-screenshots.env.example",
    ]

    XCTAssertEqual(Set(report.externalVerificationItems.map(\.id)), Set(expectedArgumentsByItemID.keys))

    for item in report.externalVerificationItems {
      let command = report.externalVerificationRecordingCommandMarkdown(for: item.id)
      XCTAssertTrue(command.contains("script/record_external_verification_evidence.sh --dry-run"))
      XCTAssertTrue(command.contains("script/record_external_verification_evidence.sh \\"))
      XCTAssertTrue(command.contains("--item \(item.id)"))
      XCTAssertTrue(command.contains("--summary"))
      XCTAssertTrue(command.contains("--execute"))
      XCTAssertTrue(command.contains("script/check_external_verification_evidence.sh"))
      XCTAssertTrue(command.contains("script/check_release_gate.sh --strict"))
      for argument in expectedArgumentsByItemID[item.id, default: []] {
        XCTAssertTrue(command.contains(argument), "\(item.id) command missing \(argument)")
      }
      if let environmentTemplate = expectedEnvironmentTemplateByItemID[item.id] {
        XCTAssertEqual(
          report.externalVerificationEnvironmentTemplatePath(for: item.id),
          environmentTemplate,
          "\(item.id) environment template API drifted"
        )
        XCTAssertTrue(
          command.contains("script/prepare_external_verification_envs.sh"),
          "\(item.id) command missing private env prep script"
        )
        XCTAssertTrue(
          command.contains(environmentTemplate.replacingOccurrences(of: ".env.example", with: ".env").split(separator: "/").last.map(String.init) ?? ""),
          "\(item.id) command missing copied env filename"
        )
        XCTAssertTrue(command.contains(environmentTemplate), "\(item.id) command missing \(environmentTemplate)")
      } else {
        XCTAssertNil(report.externalVerificationEnvironmentTemplatePath(for: item.id))
        XCTAssertFalse(command.contains(".env.example"), "\(item.id) command should not require a private env template")
      }
      XCTAssertFalse(command.contains("/Users/"))
      XCTAssertFalse(command.contains("Authorization: Bearer"))
    }

    let screenshotCommand = report.externalVerificationRecordingCommandMarkdown(for: "app-store-screenshots")
    XCTAssertTrue(screenshotCommand.contains("Ten App Store screenshots"))
    XCTAssertTrue(report.externalVerificationEvidenceTemplate(for: "app-store-screenshots").contains("all ten required App Store screens"))
  }

  func testOnlinePublishExternalEvidenceRejectsPendingPlaceholders() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let pendingSummaries = [
      "github-direct-publish": """
      GitHub direct pending.
      Token scope: Not verified with GitHub API.
      Commit SHA: Missing commit SHA.
      Deployment status: Waiting for GitHub Pages status.
      Release ledger: TODO record release ledger entry.
      """,
      "github-review-publish": """
      GitHub PR pending.
      PR URL: https://github.com/example/test-site/pull/1
      Provider review artifact: Pending PR API response.
      Review branch: codex/live-verify-github-review
      Target branch: main
      File changes: Missing file change review.
      Deployment status: Waiting for GitHub Actions status.
      Release ledger: TODO record release ledger entry.
      Rollback draft: TODO record rollback draft.
      """,
      "gitlab-direct-publish": """
      GitLab direct pending.
      Token scope: Not checked with GitLab API.
      Commit SHA: Missing commit SHA.
      Pipeline or Pages status: Waiting for GitLab pipeline status.
      Release ledger: TODO record release ledger entry.
      """,
      "gitlab-review-publish": """
      GitLab MR pending.
      MR URL: https://gitlab.com/example/test-site/-/merge_requests/1
      Provider review artifact: Pending MR API response.
      Source branch: codex/live-verify-gitlab-review
      Target branch: main
      File changes: Missing file change review.
      Deployment status: Waiting for GitLab Pages status.
      Release ledger: TODO record release ledger entry.
      Rollback draft: TODO record rollback draft.
      """,
    ]

    for (itemID, pendingSummary) in pendingSummaries {
      XCTAssertFalse(
        report.isExternalVerificationSummaryChecklistEligible(
          itemID: itemID,
          summary: pendingSummary
        ),
        itemID
      )
      XCTAssertTrue(
        report.isExternalVerificationSummaryChecklistEligible(
          itemID: itemID,
          summary: structuredExternalSummary(for: itemID)
        ),
        itemID
      )
    }
  }

  func testOnlinePublishExternalEvidenceRequiresReleaseLedgerToMatchPublishMode() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let directWithoutMode = structuredExternalSummary(for: "github-direct-publish")
      .replacingOccurrences(
        of: "Release ledger: Release ledger contains the online direct publish entry and deployment check.",
        with: "Release ledger: Release ledger contains online publish evidence."
      )
    XCTAssertFalse(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "github-direct-publish",
        summary: directWithoutMode
      )
    )

    let githubReviewWithoutPR = structuredExternalSummary(for: "github-review-publish")
      .replacingOccurrences(
        of: "Release ledger: Release ledger contains the GitHub PR publish entry, review branch, and deployment check.",
        with: "Release ledger: Release ledger contains only the online direct publish entry and deployment check."
      )
    XCTAssertFalse(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "github-review-publish",
        summary: githubReviewWithoutPR
      )
    )

    let gitlabReviewWithoutMR = structuredExternalSummary(for: "gitlab-review-publish")
      .replacingOccurrences(
        of: "Release ledger: Release ledger contains the GitLab MR publish entry, source branch, and deployment check.",
        with: "Release ledger: Release ledger contains only the GitLab direct publish entry and deployment check."
      )
    XCTAssertFalse(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "gitlab-review-publish",
        summary: gitlabReviewWithoutMR
      )
    )

    XCTAssertTrue(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "github-review-publish",
        summary: structuredExternalSummary(for: "github-review-publish")
      )
    )
    XCTAssertTrue(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "gitlab-review-publish",
        summary: structuredExternalSummary(for: "gitlab-review-publish")
      )
    )
  }

  func testStoreKitExternalEvidenceRejectsPendingSandboxPlaceholders() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0))
    let pendingSummary = ProSandboxVerificationSummary.make(
      state: .default,
      requirements: service.upgradeRequirements(state: .default)
    )

    XCTAssertFalse(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "storekit-sandbox",
        summary: pendingSummary.externalVerificationEvidenceMarkdown
      )
    )

    let verifiedState = MonetizationState(
      entitlement: ProEntitlementState(
        isUnlocked: true,
        source: .storeKit,
        productID: MonetizationProductCatalog.proLifetimeProductID,
        unlockedAt: Date(),
        lastCheckedAt: Date()
      )
    )
    let verifiedSummary = ProSandboxVerificationSummary.make(
      state: verifiedState,
      requirements: service.upgradeRequirements(state: verifiedState)
    )

    XCTAssertTrue(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "storekit-sandbox",
        summary: verifiedSummary.externalVerificationEvidenceMarkdown
      )
    )
  }

  func testScreenshotExternalEvidenceRejectsPendingGatePlaceholders() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let pendingSummary = """
    Screenshots pending.
    Screenshot set: Captured writing, AI chat, sync/API publish, SEO/social preview, deployment, maintenance, Pro, privacy lock, and release readiness screens.
    Screenshot privacy gate: Pending privacy gate review.
    Screenshot strict gate: TODO run STRICT_SCREENSHOTS=1 check_screenshots.sh.
    """

    XCTAssertFalse(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "app-store-screenshots",
        summary: pendingSummary
      )
    )

    let filled = structuredExternalSummary(for: "app-store-screenshots")
    XCTAssertTrue(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "app-store-screenshots",
        summary: filled
      )
    )
  }

  func testRemoteRecoveryExternalEvidenceRejectsPendingPlaceholders() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let pendingSummary = """
    Remote recovery pending.
    Remote conflict preview: TODO reproduce same-path remote edit.
    Pending/offline state: Failed deployment stayed pending for retry.
    Deployment retry: Waiting for provider retry.
    Rollback package: Missing rollback package.
    """

    XCTAssertFalse(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "remote-conflict-deployment-rollback",
        summary: pendingSummary
      )
    )

    let filled = structuredExternalSummary(for: "remote-conflict-deployment-rollback")
    XCTAssertTrue(
      report.isExternalVerificationSummaryChecklistEligible(
        itemID: "remote-conflict-deployment-rollback",
        summary: filled
      )
    )
  }

  func testExternalVerificationEvidenceMarkdownSummarizesRecordedEvidence() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let records = [
      ReleaseExternalVerificationEvidenceRecord(
        itemID: "github-direct-publish",
        summary: structuredExternalSummary(for: "github-direct-publish"),
        evidenceURL: "https://github.com/example/site/commit/abc123"
      )
    ]

    let markdown = report.externalVerificationEvidenceMarkdown(records: records)

    XCTAssertTrue(markdown.contains("# 外部发布验收证据"))
    XCTAssertTrue(markdown.contains("- 已记录：1/7"))
    XCTAssertTrue(markdown.contains("- 状态：外部验收证据未齐全"))
    XCTAssertTrue(markdown.contains("GitHub API 直接提交"))
    XCTAssertTrue(markdown.contains("GitHub direct verified."))
    XCTAssertTrue(markdown.contains("https://github.com/example/site/commit/abc123"))
    XCTAssertTrue(markdown.contains("GitLab MR 发布"))
    XCTAssertTrue(markdown.contains("尚未记录验收证据"))
  }

  func testExternalVerificationEvidenceFileMarkdownMatchesStrictGateFormat() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let markdown = report.externalVerificationEvidenceFileMarkdown(
      records: [
        ReleaseExternalVerificationEvidenceRecord(
          itemID: "github-direct-publish",
          summary: structuredExternalSummary(for: "github-direct-publish"),
          evidenceURL: "https://github.com/example/site/commit/abc123"
        )
      ]
    )

    XCTAssertTrue(markdown.contains("# External Verification Evidence"))
    XCTAssertTrue(markdown.contains("- [x] `github-direct-publish` - GitHub API 直接提交: GitHub direct verified."))
    XCTAssertTrue(markdown.contains("- Token scope:"))
    XCTAssertTrue(markdown.contains("- Deployment status:"))
    XCTAssertTrue(markdown.contains("- [ ] `github-review-publish`"))
    XCTAssertTrue(markdown.contains("## Evidence Notes"))
    XCTAssertTrue(markdown.contains("https://github.com/example/site/commit/abc123"))
  }

  func testExternalVerificationEvidenceFileStatusReadsCompletedItems() throws {
    let root = try temporaryProjectRoot()
    try write(
      "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md",
      in: root,
      content: """
      # External Verification Evidence

      - [x] `github-direct-publish` - GitHub API 直接提交: GitHub direct verified.
      - [X] `storekit-sandbox` - StoreKit sandbox verified.
      - [ ] `gitlab-direct-publish` - GitLab direct pending.

      ### GitHub API 直接提交
      - GitHub direct commit abc123 verified. https://github.com/example/site/commit/abc123
      - Token scope: Least-privilege token confirmed.
      - Commit SHA: abc123.
      - Deployment status: GitHub Pages reached success.
      - Release ledger: Ledger contains direct publish entry.
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let status = report.externalVerificationEvidenceFileStatus

    XCTAssertTrue(status.isPresent)
    XCTAssertEqual(status.totalCount, 7)
    XCTAssertEqual(Set(status.completedItemIDs), ["github-direct-publish"])
    XCTAssertTrue(status.missingItemIDs.contains("gitlab-direct-publish"))
    XCTAssertTrue(status.missingItemIDs.contains("storekit-sandbox"))
    XCTAssertFalse(status.isComplete)
    XCTAssertTrue(status.message.contains("已完成 1/7"))
  }

  func testExternalVerificationEvidenceFileMarkdownImportsCompletedRecords() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let records = report.externalVerificationEvidenceRecords(
      fromFileMarkdown: """
      # External Verification Evidence

      - [x] `github-direct-publish` - GitHub API 直接提交: GitHub direct commit abc123 verified.
      - [X] `storekit-sandbox` - StoreKit sandbox verified without secrets.
      - [ ] `gitlab-direct-publish` - GitLab direct pending.

      ### GitHub API 直接提交
      - GitHub direct commit abc123 verified. https://github.com/example/site/commit/abc123
      - Token scope: Least-privilege token confirmed.
      - Commit SHA: abc123.
      - Deployment status: GitHub Pages reached success.
      - Release ledger: Ledger contains direct publish entry.

      ### StoreKit sandbox 购买与恢复
      - StoreKit product lookup: Sandbox loaded product.
      - StoreKit purchase: Purchase completed.
      - StoreKit restore: Restore completed.
      - StoreKit free quota: Free quota boundary verified.
      - StoreKit boundary events: Recent Pro boundary events showed free-plan block and Pro no-quota allow.
      """,
      recordedAt: Date(timeIntervalSince1970: 100)
    )

    XCTAssertEqual(records.map(\.itemID), ["github-direct-publish", "storekit-sandbox"])
    XCTAssertTrue(records.first?.summary.contains("GitHub direct commit abc123 verified.") == true)
    XCTAssertTrue(records.first?.summary.contains("Token scope:") == true)
    XCTAssertEqual(records.first?.evidenceURL, "https://github.com/example/site/commit/abc123")
    XCTAssertTrue(records[1].summary.contains("StoreKit product lookup:"))
    XCTAssertNil(records[1].evidenceURL)
    XCTAssertEqual(records.first?.recordedAt, Date(timeIntervalSince1970: 100))
  }

  func testExternalVerificationImportSkipsLegacyStructuredItemsWithoutDetailFields() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let records = report.externalVerificationEvidenceRecords(
      fromFileMarkdown: """
      # External Verification Evidence

      - [x] `github-direct-publish` - GitHub direct verified.
      - [x] `storekit-sandbox` - Legacy StoreKit evidence without structured fields.
      - [x] `remote-conflict-deployment-rollback` - Legacy rollback evidence without structured fields.
      - [x] `app-store-screenshots` - Legacy screenshot evidence without structured fields.
      """
    )

    XCTAssertEqual(records.map(\.itemID), [])
  }

  func testExternalVerificationEvidenceFileStatusFlagsPrivateContent() throws {
    let root = try temporaryProjectRoot()
    try write(
      "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md",
      in: root,
      content: """
      # External Verification Evidence

      - [x] `github-direct-publish` - /Users/example/site ghp_abcdefghijklmnopqrstuvwxyz
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let status = report.externalVerificationEvidenceFileStatus

    XCTAssertTrue(status.privacyFindings.contains("本地路径"))
    XCTAssertTrue(status.privacyFindings.contains("Token 或授权头"))
    XCTAssertFalse(status.isComplete)
    XCTAssertEqual(status.title, "外部验收证据包需要清理")
  }

  func testExternalVerificationCoverageSummarizesMissingAndCompleteEvidence() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let emptyCoverage = report.externalVerificationCoverage(records: [])
    XCTAssertEqual(emptyCoverage.totalCount, 7)
    XCTAssertEqual(emptyCoverage.recordedCount, 0)
    XCTAssertFalse(emptyCoverage.isComplete)
    XCTAssertEqual(emptyCoverage.title, "尚未记录外部验收证据")
    XCTAssertTrue(emptyCoverage.message.contains("GitHub API 直接提交"))

    let fullRecords = completeExternalVerificationRecords()
    let fullCoverage = report.externalVerificationCoverage(records: fullRecords)
    XCTAssertEqual(fullCoverage.recordedCount, 7)
    XCTAssertTrue(fullCoverage.missingItems.isEmpty)
    XCTAssertTrue(fullCoverage.isComplete)
    XCTAssertEqual(fullCoverage.title, "外部验收证据齐全")
  }

  func testStrictReadinessSummaryListsScreenshotsExternalEvidenceAndChecklistActions() throws {
    let root = try temporaryProjectRoot()
    try write(
      "APP_STORE_CHECKLIST.md",
      in: root,
      content: """
      # App Store Release Checklist

      - [ ] Capture required screenshots.
      - [ ] Verify GitHub direct commit with least-privilege token.
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let summary = report.strictReadinessSummary(records: [])
    let actionIDs = Set(summary.actions.map(\.id))

    XCTAssertFalse(summary.isReady)
    XCTAssertTrue(actionIDs.contains("app-store-screenshots"))
    XCTAssertTrue(actionIDs.contains("external-verification"))
    XCTAssertTrue(actionIDs.contains("app-store-checklist"))
    XCTAssertTrue(summary.message.contains("check_release_gate.sh --strict"))
    XCTAssertTrue(summary.commandText.contains("./script/capture_app_screenshots.sh"))
    XCTAssertTrue(summary.commandText.contains("./script/check_external_verification_evidence.sh"))
    XCTAssertTrue(summary.commandText.contains("open APP_STORE_CHECKLIST.md"))
  }

  func testStrictReadinessSummaryPassesWhenStrictEvidenceIsComplete() {
    let item = ReleaseExternalVerificationItem(
      id: "github-direct-publish",
      title: "GitHub API 直接提交",
      purpose: "Verify direct publish.",
      evidenceToCollect: "Commit SHA.",
      steps: ["Publish to a test repository."]
    )
    let record = ReleaseExternalVerificationEvidenceRecord(
      itemID: item.id,
      summary: structuredExternalSummary(for: item.id)
    )
    let report = ReleaseQualityGateReport(
      projectRootPath: "/tmp/project",
      items: [],
      screenshotRequirements: [
        ReleaseScreenshotRequirement(
          id: "writing",
          targetFileName: "writing.png",
          screenTitle: "Writing",
          purpose: "Writing workspace.",
          manifestStatus: "Captured",
          capturedFilePath: "docs/app-store-screenshots/writing.png"
        )
      ],
      externalVerificationItems: [item],
      appStoreChecklistTasks: [
        ReleaseAppStoreChecklistTask(id: "manual-archive", title: "Validate archive before upload.", isChecked: true)
      ],
      externalVerificationEvidenceFileStatus: ReleaseExternalVerificationEvidenceFileStatus(
        isPresent: true,
        totalCount: 1,
        completedItemIDs: [item.id],
        missingItemIDs: [],
        privacyFindings: []
      )
    )

    let summary = report.strictReadinessSummary(records: [record])

    XCTAssertTrue(summary.isReady)
    XCTAssertEqual(summary.actions, [])
    XCTAssertEqual(summary.title, "严格发布门禁可执行")
    XCTAssertEqual(summary.commandText, "./script/check_release_gate.sh --strict")
  }

  func testAppStoreChecklistManualCommandsMapMissingTasksToEvidenceScripts() throws {
    let root = try temporaryProjectRoot()
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let archive = ReleaseAppStoreChecklistTask(
      id: "archive-validation",
      sectionTitle: "Build And Signing",
      title: "Validate the archive with App Store Connect or Transporter before upload.",
      isChecked: false
    )
    let metadata = ReleaseAppStoreChecklistTask(
      id: "app-store-metadata",
      sectionTitle: "Build And Signing",
      title: "Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements.",
      isChecked: false
    )
    let signingRuntime = ReleaseAppStoreChecklistTask(
      id: "archive-signing-runtime",
      sectionTitle: "Build And Signing",
      title: "Confirm distribution signing team and hardened runtime on the archived app.",
      isChecked: false
    )
    let screenshots = ReleaseAppStoreChecklistTask(
      id: "screenshots-capture",
      sectionTitle: "Screenshots",
      title: "Capture writing, AI chat, sync/API publish, SEO/social preview, deployment status, maintenance, general drafts, Pro, privacy lock, and release gate screens.",
      isChecked: false
    )
    let storeKit = ReleaseAppStoreChecklistTask(
      id: "storekit-sandbox",
      sectionTitle: "Privacy And Monetization",
      title: "Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.",
      isChecked: false
    )
    let github = ReleaseAppStoreChecklistTask(
      id: "github-live-publish",
      sectionTitle: "Publishing Workflow",
      title: "Verify GitHub direct commit and PR publishing with a least-privilege token.",
      isChecked: false
    )
    let gitlab = ReleaseAppStoreChecklistTask(
      id: "gitlab-live-publish",
      sectionTitle: "Publishing Workflow",
      title: "Verify GitLab direct commit and MR publishing with a least-privilege token.",
      isChecked: false
    )
    let remoteRecovery = ReleaseAppStoreChecklistTask(
      id: "remote-recovery",
      sectionTitle: "Publishing Workflow",
      title: "Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance.",
      isChecked: false
    )

    let metadataCommand = report.appStoreChecklistManualCommandMarkdown(for: metadata)
    XCTAssertTrue(metadataCommand.contains("check_app_store_metadata.sh"))
    XCTAssertFalse(metadataCommand.contains("record_app_store_archive_validation_bundle.sh"))

    let signingRuntimeCommand = report.appStoreChecklistManualCommandMarkdown(for: signingRuntime)
    XCTAssertTrue(signingRuntimeCommand.contains("record_app_store_archive_validation_bundle.sh"))
    XCTAssertFalse(signingRuntimeCommand.contains("check_app_store_metadata.sh"))

    let archiveCommand = report.appStoreChecklistManualCommandMarkdown(for: archive)
    XCTAssertTrue(archiveCommand.contains("record_app_store_archive_validation_bundle.sh"))
    XCTAssertFalse(archiveCommand.contains("check_app_store_metadata.sh"))
    XCTAssertTrue(archiveCommand.contains("docs/release-evidence/app-store-archive-validation.env.example"))

    let screenshotCommand = report.appStoreChecklistManualCommandMarkdown(for: screenshots)
    XCTAssertTrue(screenshotCommand.contains("capture_app_screenshots.sh --auto-window --force-relaunch"))
    XCTAssertTrue(screenshotCommand.contains("record_app_store_screenshot_evidence.sh --execute"))

    let storeKitCommand = report.appStoreChecklistManualCommandMarkdown(for: storeKit)
    XCTAssertTrue(storeKitCommand.contains("--item storekit-sandbox"))
    XCTAssertTrue(storeKitCommand.contains("--storekit-purchase"))
    XCTAssertTrue(storeKitCommand.contains("docs/release-evidence/storekit-sandbox.env.example"))

    let githubCommand = report.appStoreChecklistManualCommandMarkdown(for: github)
    XCTAssertTrue(githubCommand.contains("verify_remote_publish_live_matrix.sh --execute"))
    XCTAssertTrue(githubCommand.contains("--item github-direct-publish"))
    XCTAssertTrue(githubCommand.contains("--item github-review-publish"))
    XCTAssertTrue(githubCommand.contains("docs/release-evidence/remote-publish-live.env.example"))

    let gitlabCommand = report.appStoreChecklistManualCommandMarkdown(for: gitlab)
    XCTAssertTrue(gitlabCommand.contains("--item gitlab-direct-publish"))
    XCTAssertTrue(gitlabCommand.contains("--item gitlab-review-publish"))
    XCTAssertTrue(gitlabCommand.contains("docs/release-evidence/remote-publish-live.env.example"))

    let remoteCommand = report.appStoreChecklistManualCommandMarkdown(for: remoteRecovery)
    XCTAssertTrue(remoteCommand.contains("--item remote-conflict-deployment-rollback"))
    XCTAssertTrue(remoteCommand.contains("--rollback-package"))
    XCTAssertTrue(remoteCommand.contains("docs/release-evidence/remote-recovery.env.example"))

    for command in [metadataCommand, signingRuntimeCommand, archiveCommand, screenshotCommand, storeKitCommand, githubCommand, gitlabCommand, remoteCommand] {
      XCTAssertTrue(command.contains("script/sync_app_store_checklist.sh --dry-run"))
      XCTAssertTrue(command.contains("script/check_release_gate.sh --strict"))
      XCTAssertFalse(command.contains("/Users/"))
      XCTAssertFalse(command.contains("Authorization: Bearer"))
    }
  }

  func testAppStoreChecklistCoverageMapsAutomationAndExternalEvidence() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseGateEvidence(in: root)
    try writeStoreKitEvidence(in: root)
    try write("docs/app-store-screenshots/app-store-screenshots.png", in: root, content: "placeholder")
    try write(
      "APP_STORE_CHECKLIST.md",
      in: root,
      content: """
      # App Store Release Checklist

      ## Build And Signing

      - [ ] Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements.
      - [ ] Confirm distribution signing team and hardened runtime on the archived app.
      - [ ] Validate the archive with App Store Connect or Transporter before upload.

      ## Screenshots

      - [ ] Capture writing, AI chat, sync/API publish, SEO/social preview, deployment status, maintenance, Pro, privacy lock, and release gate screens.

      ## Privacy And Monetization

      - [ ] Review privacy policy/support copy against in-app privacy lock and private-content behavior.
      - [ ] Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.
      - [x] Confirm free users see clear upgrade copy before blocked AI, online publish, or batch publish actions.

      ## Publishing Workflow

      - [ ] Verify GitHub direct commit and PR publishing with a least-privilege token.
      - [ ] Verify GitLab direct commit and MR publishing with a least-privilege token.
      - [ ] Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance.
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      proUpgradeRequirements: MonetizationService(
        limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
      ).upgradeRequirements(state: .default),
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let records = [
      ReleaseExternalVerificationEvidenceRecord(itemID: "github-direct-publish", summary: structuredExternalSummary(for: "github-direct-publish")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "github-review-publish", summary: structuredExternalSummary(for: "github-review-publish")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "gitlab-direct-publish", summary: structuredExternalSummary(for: "gitlab-direct-publish")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "gitlab-review-publish", summary: structuredExternalSummary(for: "gitlab-review-publish")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "remote-conflict-deployment-rollback", summary: structuredExternalSummary(for: "remote-conflict-deployment-rollback")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "storekit-sandbox", summary: structuredExternalSummary(for: "storekit-sandbox")),
      ReleaseExternalVerificationEvidenceRecord(itemID: "app-store-screenshots", summary: structuredExternalSummary(for: "app-store-screenshots"))
    ]

    let coverage = report.appStoreChecklistCoverage(records: records)

    XCTAssertEqual(report.appStoreChecklistTasks.count, 10)
    XCTAssertEqual(coverage.checkedCount, 1)
    XCTAssertEqual(coverage.evidenceBackedCount, 9)
    XCTAssertTrue(coverage.missingTasks.isEmpty)
    XCTAssertTrue(coverage.isFullyCoveredByChecklistOrEvidence)
    XCTAssertEqual(coverage.message, "已勾选 1 项，另有 9 项由自动门禁或外部验收证据覆盖。")
    XCTAssertTrue(coverage.evidenceBackedTasks.contains { $0.evidence.contains("GitHub") })
    XCTAssertTrue(coverage.evidenceBackedTasks.contains { $0.evidence.contains("GitLab") })
    XCTAssertTrue(coverage.evidenceBackedTasks.contains { $0.evidence.contains("StoreKit") })
    XCTAssertTrue(coverage.evidenceBackedTasks.contains { $0.evidence.contains("Transporter") })
    XCTAssertTrue(coverage.evidenceBackedTasks.contains { $0.evidence.contains("隐私/支持文案") })
  }

  func testAppStoreChecklistCoverageCompletesWhenChecklistOrEvidenceCoversEveryTask() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseGateEvidence(in: root)
    try writeStoreKitEvidence(in: root)
    try write(
      "APP_STORE_CHECKLIST.md",
      in: root,
      content: """
      # App Store Release Checklist

      - [ ] Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements.
      - [x] Confirm distribution signing team and hardened runtime on the archived app.
      - [x] Validate the archive with App Store Connect or Transporter before upload.
      - [ ] Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      proUpgradeRequirements: MonetizationService(
        limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
      ).upgradeRequirements(state: .default),
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )
    let coverage = report.appStoreChecklistCoverage(
      records: [
        ReleaseExternalVerificationEvidenceRecord(itemID: "storekit-sandbox", summary: structuredExternalSummary(for: "storekit-sandbox"))
      ]
    )

    XCTAssertEqual(coverage.coveredCount, 4)
    XCTAssertTrue(coverage.missingTasks.isEmpty)
    XCTAssertTrue(coverage.isFullyCoveredByChecklistOrEvidence)
    XCTAssertEqual(coverage.title, "上架清单已有证据覆盖")
  }

  func testAppStoreChecklistMarkdownApplyingEvidenceChecksCoveredItemsOnly() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseGateEvidence(in: root)
    try writeStoreKitEvidence(in: root)
    try write(
      "APP_STORE_CHECKLIST.md",
      in: root,
      content: """
      # App Store Release Checklist

      - [ ] Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements.
      - [ ] Confirm distribution signing team and hardened runtime on the archived app.
      - [ ] Validate the archive with App Store Connect or Transporter before upload.
      - [ ] Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.
      """
    )
    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      proUpgradeRequirements: MonetizationService(
        limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
      ).upgradeRequirements(state: .default),
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let result = report.appStoreChecklistMarkdownApplyingEvidence(
      to: try String(contentsOf: root.appendingPathComponent("APP_STORE_CHECKLIST.md"), encoding: .utf8),
      records: [
        ReleaseExternalVerificationEvidenceRecord(itemID: "storekit-sandbox", summary: structuredExternalSummary(for: "storekit-sandbox"))
      ]
    )

    XCTAssertEqual(result.updatedCount, 4)
    XCTAssertTrue(result.markdown.contains("- [x] Confirm bundle identifier"))
    XCTAssertTrue(result.markdown.contains("Evidence: App Store 元数据门禁已通过"))
    XCTAssertTrue(result.markdown.contains("- [x] Confirm distribution signing team and hardened runtime on the archived app."))
    XCTAssertTrue(result.markdown.contains("Evidence: App Store 归档准备门禁已通过"))
    XCTAssertTrue(result.markdown.contains("- [x] Verify StoreKit product ID"))
    XCTAssertTrue(result.markdown.contains("Evidence: 已记录 StoreKit sandbox 外部验收证据"))
    XCTAssertTrue(result.markdown.contains("- [x] Validate the archive with App Store Connect or Transporter before upload."))
    XCTAssertTrue(result.markdown.contains("Evidence: 已记录 Transporter/App Store Connect 归档验证证据"))
  }

  @MainActor
  func testStorePersistsExternalVerificationEvidenceRecords() throws {
    let url = try temporaryProjectRoot().appendingPathComponent("workbench.json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    store.recordExternalVerificationEvidence(
      itemID: "github-direct-publish",
      summary: structuredExternalSummary(for: "github-direct-publish")
    )

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    reloaded.refreshReleaseQualityGate(projectRoot: url.deletingLastPathComponent())

    let record = try XCTUnwrap(reloaded.latestExternalVerificationEvidence(for: "github-direct-publish"))
    XCTAssertTrue(record.summary.contains("GitHub direct verified."))
    XCTAssertTrue(record.summary.contains("Release ledger:"))
    XCTAssertEqual(reloaded.externalVerificationCoverageSummary.recordedCount, 1)
    XCTAssertFalse(reloaded.externalVerificationCoverageSummary.isComplete)
    XCTAssertTrue(reloaded.externalVerificationEvidenceMarkdown.contains("GitHub direct verified."))
    XCTAssertTrue(reloaded.externalVerificationEvidenceMarkdown.contains("Release ledger:"))
  }

  @MainActor
  func testStoreRecordsReleaseRecoveryPackageAsExternalVerificationEvidence() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)
    let record = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "线上提交部分失败",
      summary: "1 个文件已写入 main，部署检查暂时离线。",
      draftTitle: "部分成功文章",
      changedPaths: ["content/posts/partial.md"],
      repositoryProvider: .github,
      repositoryBaseURL: "https://api.github.com",
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "abcdef1234567890"
    )
    let entry = try XCTUnwrap(
      ReleaseLedgerService()
        .ledger(releaseRecords: [record], deploymentStatusSnapshots: [:])
        .entries
        .first
    )

    store.recordReleaseRecoveryExternalVerificationEvidence(from: entry.recoveryPackage)

    let evidence = try XCTUnwrap(store.latestExternalVerificationEvidence(for: "remote-conflict-deployment-rollback"))
    XCTAssertTrue(evidence.summary.contains("Remote conflict preview:"))
    XCTAssertTrue(evidence.summary.contains("Pending/offline state:"))
    XCTAssertTrue(evidence.summary.contains("Deployment retry:"))
    XCTAssertTrue(evidence.summary.contains("Rollback package:"))
    XCTAssertEqual(evidence.evidenceURL, "https://github.com/owner/site/commit/abcdef1234567890")
    XCTAssertEqual(store.externalVerificationCoverageSummary.recordedCount, 1)
    XCTAssertTrue(store.externalVerificationEvidenceMarkdown.contains("remote-conflict-deployment-rollback"))
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("remote-conflict-deployment-rollback") == true)
  }

  @MainActor
  func testStoreRejectsPendingStoreKitSandboxEvidenceSummary() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)
    let service = MonetizationService(limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0))
    let pendingSummary = ProSandboxVerificationSummary.make(
      state: .default,
      requirements: service.upgradeRequirements(state: .default)
    )

    store.recordExternalVerificationEvidence(
      itemID: "storekit-sandbox",
      summary: pendingSummary.externalVerificationEvidenceMarkdown
    )

    XCTAssertNil(store.latestExternalVerificationEvidence(for: "storekit-sandbox"))
    XCTAssertEqual(store.externalVerificationCoverageSummary.recordedCount, 0)
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("结构化字段") == true)
  }

  @MainActor
  func testStoreWritesExternalVerificationEvidenceFileForReleaseGate() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)
    store.recordExternalVerificationEvidence(
      itemID: "github-direct-publish",
      summary: structuredExternalSummary(for: "github-direct-publish")
    )

    let evidenceURL = try store.writeExternalVerificationEvidenceFile(projectRoot: root)
    let content = try String(contentsOf: evidenceURL, encoding: .utf8)

    XCTAssertEqual(
      evidenceURL.path,
      root.appendingPathComponent("docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md").path
    )
    XCTAssertTrue(content.contains("- [x] `github-direct-publish`"))
    XCTAssertTrue(content.contains("- [ ] `gitlab-direct-publish`"))
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("已写入外部验收证据包") == true)
  }

  @MainActor
  func testStoreWritesRedactedLocalReleaseEvidenceBundle() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)
    store.recordExternalVerificationEvidence(
      itemID: "github-direct-publish",
      summary: """
      GitHub direct verified.
      Token scope: ghp_1234567890abcdef was checked from /Users/alice/private-site.
      Commit SHA: abc123 redacted test commit.
      Deployment status: GitHub Pages reached success.
      Release ledger: Release ledger contains the direct publish entry.
      """
    )

    let evidenceURL = try store.writeLocalReleaseEvidenceBundle(projectRoot: root)
    let content = try String(contentsOf: evidenceURL, encoding: .utf8)

    XCTAssertEqual(
      evidenceURL.deletingLastPathComponent().path,
      root.appendingPathComponent("docs/release-evidence").path
    )
    XCTAssertEqual(evidenceURL.lastPathComponent, "LOCAL_RELEASE_EVIDENCE.md")
    XCTAssertTrue(evidenceURL.lastPathComponent.hasSuffix(".md"))
    XCTAssertTrue(content.contains("# Local Release Evidence Bundle"))
    XCTAssertTrue(content.contains("External verification evidence: 1/7 completed"))
    XCTAssertTrue(content.contains("Final strict command: `./script/check_release_gate.sh --strict`"))
    XCTAssertTrue(content.contains("docs/release-evidence/app-store-screenshots.env.example"))
    XCTAssertTrue(content.contains("`github-direct-publish`"))
    XCTAssertTrue(content.contains("<redacted-token>"))
    XCTAssertTrue(content.contains("<redacted-local-path>"))
    XCTAssertFalse(content.contains("ghp_1234567890abcdef"))
    XCTAssertFalse(content.contains("/Users/alice/private-site"))
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("已写入本地发布证据包") == true)
  }

  @MainActor
  func testReleaseReportProvidesPrivateEnvironmentPreparationCommands() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)

    let commands = store.externalVerificationEnvironmentPreparationCommandMarkdown

    XCTAssertTrue(commands.contains("print_remaining_external_verification.sh"))
    XCTAssertTrue(commands.contains("prepare_external_verification_envs.sh --dry-run"))
    XCTAssertTrue(commands.contains("check_external_verification_envs.sh --mode template"))
    XCTAssertTrue(commands.contains("prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target remaining"))
    XCTAssertTrue(commands.contains("check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining"))
    XCTAssertTrue(commands.contains("check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remaining --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("follow the source lines it prints"))
    XCTAssertTrue(commands.contains("Do not copy filled values back into `docs/release-evidence/*.env.example`."))
    XCTAssertFalse(commands.contains("/Users/"))
    XCTAssertFalse(commands.contains("Authorization: Bearer"))

    let statusReportCommands = store.externalVerificationEnvironmentStatusReportCommandMarkdown

    XCTAssertTrue(statusReportCommands.contains("# External Verification Private Env Status Report"))
    XCTAssertTrue(statusReportCommands.contains("check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(statusReportCommands.contains("stat -f '%Lp %N' /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(statusReportCommands.contains("sed -n '1,220p' /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(statusReportCommands.contains("--env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute"))
    XCTAssertFalse(statusReportCommands.contains("/Users/"))
    XCTAssertFalse(statusReportCommands.contains("Authorization: Bearer"))

    let fieldChecklist = store.externalVerificationEnvironmentFieldChecklistMarkdown

    XCTAssertTrue(fieldChecklist.contains("# External Verification Private Env Field Checklist"))
    XCTAssertTrue(fieldChecklist.contains("remote-publish-live.env"))
    XCTAssertTrue(fieldChecklist.contains("REMOTE_VERIFY_GITHUB_TOKEN"))
    XCTAssertTrue(fieldChecklist.contains("REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER"))
    XCTAssertTrue(fieldChecklist.contains("remote-recovery.env"))
    XCTAssertTrue(fieldChecklist.contains("REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY"))
    XCTAssertTrue(fieldChecklist.contains("storekit-sandbox.env"))
    XCTAssertTrue(fieldChecklist.contains("STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY"))
    XCTAssertTrue(fieldChecklist.contains("app-store-archive-validation.env"))
    XCTAssertTrue(fieldChecklist.contains("APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY"))
    XCTAssertTrue(fieldChecklist.contains("Execute + checklist sync + strict gate:"))
    XCTAssertTrue(fieldChecklist.contains("script/sync_app_store_checklist.sh --execute"))
    XCTAssertTrue(fieldChecklist.contains("./script/check_release_gate.sh --strict"))
    XCTAssertTrue(fieldChecklist.contains("Do not run the `--execute` commands"))
    XCTAssertFalse(fieldChecklist.contains("/Users/"))
    XCTAssertFalse(fieldChecklist.contains("Authorization: Bearer"))
  }

  func testExternalVerificationEnvStatusReportParsesRedactedMarkdownByFile() {
    let reportText = """
    # External Verification Env Status

    - Mode: `filled`
    - Target: `remaining`
    - Env directory: `/private/tmp/personal-site-publisher-release-envs`
    - Checked targets: 2
    - Passing env files: 0
    - Issues: 3

    ## Required Fields

    - `remote-publish-live.env` (`remote-publish`): `REMOTE_VERIFY_GITHUB_TOKEN`, `REMOTE_VERIFY_GITHUB_OWNER`
    - `remote-recovery.env` (`remote-recovery`): `REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY`

    ## Issues

    - remote-publish-live.env has empty or placeholder value for REMOTE_VERIFY_GITHUB_TOKEN
    - remote-publish-live.env has empty or placeholder value for REMOTE_VERIFY_GITHUB_OWNER
    - remote-recovery.env is missing required variable REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY

    ## Evidence Completion

    ### `remote-publish`
    - [ ] `github-direct-publish`
    - [x] `github-review-publish`

    ### `remote-recovery`
    - [ ] `remote-conflict-deployment-rollback`

    ## Next Commands

    ```sh
    script/check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md
    script/run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remaining --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute
    ```
    """

    let report = ReleaseExternalVerificationEnvStatusReport.parse(redactedMarkdown: reportText)

    XCTAssertTrue(report.isPresent)
    XCTAssertFalse(report.isClean)
    XCTAssertEqual(report.mode, "filled")
    XCTAssertEqual(report.target, "remaining")
    XCTAssertEqual(report.checkedTargetCount, 2)
    XCTAssertEqual(report.passingEnvFileCount, 0)
    XCTAssertEqual(report.issueCount, 3)
    XCTAssertEqual(report.files.count, 2)
    XCTAssertEqual(report.files[0].envFilename, "remote-publish-live.env")
    XCTAssertEqual(report.files[0].targetID, "remote-publish")
    XCTAssertEqual(report.files[0].requiredKeys, ["REMOTE_VERIFY_GITHUB_TOKEN", "REMOTE_VERIFY_GITHUB_OWNER"])
    XCTAssertEqual(report.files[0].missingOrPlaceholderKeys, ["REMOTE_VERIFY_GITHUB_TOKEN", "REMOTE_VERIFY_GITHUB_OWNER"])
    XCTAssertEqual(report.files[1].missingOrPlaceholderKeys, ["REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY"])
    XCTAssertEqual(report.evidenceCompletions.count, 3)
    XCTAssertEqual(report.completedEvidenceCount, 1)
    XCTAssertEqual(report.pendingEvidenceCompletions.map(\.label), ["github-direct-publish", "remote-conflict-deployment-rollback"])
    XCTAssertEqual(report.pendingEvidenceCompletions.map(\.targetID), ["remote-publish", "remote-recovery"])
    XCTAssertTrue(report.evidenceCompletionMessage.contains("1/3"))
    XCTAssertEqual(report.nextCommands.count, 2)
    XCTAssertTrue(report.summaryMarkdown.contains("remote-publish-live.env"))
    XCTAssertTrue(report.summaryMarkdown.contains("REMOTE_VERIFY_GITHUB_TOKEN"))
    XCTAssertTrue(report.summaryMarkdown.contains("## Evidence Completion"))
    XCTAssertTrue(report.summaryMarkdown.contains("- [ ] `remote-publish`: github-direct-publish"))
    XCTAssertTrue(report.summaryMarkdown.contains("- [x] `remote-publish`: github-review-publish"))
    XCTAssertTrue(report.summaryMarkdown.contains("script/run_external_verification_from_envs.sh"))
    XCTAssertFalse(report.summaryMarkdown.contains("Authorization: Bearer"))
  }

  @MainActor
  func testReleaseReportProvidesCleanRuntimeAndArchiveRecordingCommands() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)

    let cleanRuntimeCommands = store.cleanRuntimeEvidenceRecordingCommandMarkdown
    let archiveCommands = store.appStoreArchiveValidationRecordingCommandMarkdown

    XCTAssertTrue(cleanRuntimeCommands.contains("record_clean_runtime_evidence.sh --dry-run"))
    XCTAssertTrue(cleanRuntimeCommands.contains("record_clean_runtime_evidence_bundle.sh"))
    XCTAssertTrue(cleanRuntimeCommands.contains("--clean-launch"))
    XCTAssertTrue(cleanRuntimeCommands.contains("--privacy-settings-workspace"))
    XCTAssertTrue(cleanRuntimeCommands.contains("--accessibility-keyboard-smoke"))
    XCTAssertTrue(cleanRuntimeCommands.contains("--execute"))
    XCTAssertFalse(cleanRuntimeCommands.contains("/Users/"))
    XCTAssertFalse(cleanRuntimeCommands.contains("Authorization: Bearer"))

    XCTAssertTrue(archiveCommands.contains("record_app_store_archive_validation_evidence.sh --dry-run"))
    XCTAssertTrue(archiveCommands.contains("prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target app-store-archive"))
    XCTAssertTrue(archiveCommands.contains("record_app_store_archive_validation_bundle.sh"))
    XCTAssertTrue(archiveCommands.contains("--clean-release-archive"))
    XCTAssertTrue(archiveCommands.contains("--distribution-signing-runtime"))
    XCTAssertTrue(archiveCommands.contains("--transporter-validation"))
    XCTAssertTrue(archiveCommands.contains("--execute"))
    XCTAssertFalse(archiveCommands.contains("/Users/"))
    XCTAssertFalse(archiveCommands.contains("Authorization: Bearer"))
  }

  @MainActor
  func testReleaseReportProvidesScreenshotEvidenceRecordingCommands() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)

    let commands = store.appStoreScreenshotEvidenceRecordingCommandMarkdown

    XCTAssertTrue(commands.contains("prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target app-store-screenshots"))
    XCTAssertTrue(commands.contains("source /private/tmp/personal-site-publisher-release-envs/app-store-screenshots.env"))
    XCTAssertTrue(commands.contains("check_app_store_screenshot_capture_readiness.sh"))
    XCTAssertTrue(commands.contains("capture_app_screenshots.sh --auto-window --force-relaunch"))
    XCTAssertTrue(commands.contains("check_screenshots.sh"))
    XCTAssertTrue(commands.contains("check_screenshot_privacy.sh"))
    XCTAssertTrue(commands.contains("record_app_store_screenshot_evidence.sh --execute"))
    XCTAssertTrue(commands.contains("check_release_gate.sh --strict"))
    XCTAssertFalse(commands.contains("/Users/"))
    XCTAssertFalse(commands.contains("Authorization: Bearer"))
  }

  @MainActor
  func testStoreProvidesRemainingReleaseVerificationCommandBundle() throws {
    let root = try temporaryProjectRoot()
    try writeScreenshotManifest(in: root)
    try write(
      "APP_STORE_CHECKLIST.md",
      in: root,
      content: """
      # App Store Release Checklist

      - [ ] Run clean runtime validation.
      - [ ] Verify GitHub direct commit with least-privilege token.
      """
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)

    let commands = store.remainingReleaseVerificationCommandMarkdown
    let runnerTargets = store.remainingExternalVerificationRunnerTargets

    XCTAssertTrue(commands.contains("# Remaining App Store Manual Verification Commands"))
    XCTAssertTrue(commands.contains("## Private Env Target Runner"))
    XCTAssertTrue(commands.contains("prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target remaining"))
    XCTAssertTrue(commands.contains("check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining"))
    XCTAssertTrue(commands.contains("check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target app-store-archive --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target app-store-archive --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remote-publish --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remote-publish --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target storekit --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target storekit --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remote-recovery --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remote-recovery --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target app-store-screenshots --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target app-store-screenshots --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute"))
    XCTAssertTrue(commands.contains("## Target Checklist Map"))
    XCTAssertTrue(commands.contains("App Store 归档验证 (`app-store-archive`): Confirm distribution signing team and hardened runtime on the archived app."))
    XCTAssertTrue(commands.contains("GitHub/GitLab 实测发布 (`remote-publish`): Verify GitHub direct commit and PR publishing with a least-privilege token."))
    XCTAssertTrue(commands.contains("Verify GitLab direct commit and MR publishing with a least-privilege token."))
    XCTAssertTrue(commands.contains("StoreKit Sandbox (`storekit`): Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox."))
    XCTAssertTrue(commands.contains("远端冲突/部署/回滚 (`remote-recovery`): Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance."))
    XCTAssertTrue(commands.contains("App Store 截图证据 (`app-store-screenshots`): Capture writing, AI chat, sync/API publish, SEO/social preview, deployment status, maintenance, general drafts, Pro, privacy lock, and release gate screens."))
    XCTAssertTrue(commands.contains("## Env Field Checklist"))
    XCTAssertTrue(commands.contains("remote-publish-live.env: `REMOTE_VERIFY_GITHUB_TOKEN`, `REMOTE_VERIFY_GITHUB_OWNER`, `REMOTE_VERIFY_GITHUB_REPO`, `REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER`, `REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER`, `REMOTE_VERIFY_GITLAB_TOKEN`, `REMOTE_VERIFY_GITLAB_OWNER`, `REMOTE_VERIFY_GITLAB_REPO`, `REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER`, `REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER`"))
    XCTAssertTrue(commands.contains("storekit-sandbox.env: `STOREKIT_PRODUCT_ID`, `STOREKIT_SANDBOX_PRODUCT_LOOKUP_SUMMARY`, `STOREKIT_SANDBOX_PURCHASE_SUMMARY`, `STOREKIT_SANDBOX_RESTORE_SUMMARY`, `STOREKIT_SANDBOX_FREE_QUOTA_SUMMARY`, `STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY`"))
    XCTAssertTrue(commands.contains("remote-recovery.env: `REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY`, `REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY`, `REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY`, `REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY`"))
    XCTAssertTrue(commands.contains("app-store-archive-validation.env: `APP_STORE_ARCHIVE_CLEAN_RELEASE_SUMMARY`, `APP_STORE_ARCHIVE_SIGNING_RUNTIME_SUMMARY`, `APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY`"))
    XCTAssertTrue(commands.contains("## Private Env Status Report"))
    XCTAssertTrue(commands.contains("# External Verification Private Env Status Report"))
    XCTAssertTrue(commands.contains("stat -f '%Lp %N' /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("sed -n '1,220p' /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"))
    XCTAssertTrue(commands.contains("record_clean_runtime_evidence_bundle.sh"))
    XCTAssertTrue(commands.contains("record_app_store_archive_validation_bundle.sh"))
    XCTAssertTrue(commands.contains("docs/release-evidence/app-store-archive-validation.env.example"))
    XCTAssertTrue(commands.contains("check_app_store_screenshot_capture_readiness.sh"))
    XCTAssertTrue(commands.contains("capture_app_screenshots.sh --auto-window --force-relaunch"))
    XCTAssertTrue(commands.contains("verify_remote_publish_live_matrix.sh --execute"))
    XCTAssertTrue(commands.contains("docs/release-evidence/remote-publish-live.env.example"))
    XCTAssertTrue(commands.contains("--item github-direct-publish"))
    XCTAssertTrue(commands.contains("--item gitlab-review-publish"))
    XCTAssertTrue(commands.contains("--item storekit-sandbox"))
    XCTAssertTrue(commands.contains("docs/release-evidence/storekit-sandbox.env.example"))
    XCTAssertTrue(commands.contains("docs/release-evidence/remote-recovery.env.example"))
    XCTAssertTrue(commands.contains("docs/release-evidence/app-store-screenshots.env.example"))
    XCTAssertTrue(commands.contains("script/sync_app_store_checklist.sh --execute"))
    XCTAssertTrue(commands.contains("script/check_release_gate.sh --strict"))
    XCTAssertFalse(commands.contains("/Users/"))
    XCTAssertFalse(commands.contains("Authorization: Bearer"))

    XCTAssertEqual(
      runnerTargets.map(\.id),
      ["app-store-archive", "remote-publish", "storekit", "remote-recovery", "app-store-screenshots"]
    )
    XCTAssertTrue(runnerTargets.contains { target in
      target.title == "GitHub/GitLab 实测发布"
        && target.environmentFilename == "remote-publish-live.env"
        && target.checklistItems.contains("Verify GitHub direct commit and PR publishing with a least-privilege token.")
        && target.checklistItems.contains("Verify GitLab direct commit and MR publishing with a least-privilege token.")
        && target.requiredEnvironmentKeys.contains("REMOTE_VERIFY_GITHUB_TOKEN")
        && target.requiredEnvironmentKeys.contains("REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER")
        && target.executeCommand.hasSuffix("--target remote-publish --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute")
        && target.finalizeCommand == "script/sync_app_store_checklist.sh --execute\n./script/check_release_gate.sh --strict"
        && target.executeAndFinalizeCommand.contains(target.executeCommand)
        && target.executeAndFinalizeCommand.contains("script/sync_app_store_checklist.sh --execute")
        && target.executeAndFinalizeCommand.contains("./script/check_release_gate.sh --strict")
    })
    XCTAssertTrue(runnerTargets.contains { target in
      target.title == "StoreKit Sandbox"
        && target.environmentFilename == "storekit-sandbox.env"
        && target.checklistItems == ["Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox."]
        && target.requiredEnvironmentKeys == [
          "STOREKIT_PRODUCT_ID",
          "STOREKIT_SANDBOX_PRODUCT_LOOKUP_SUMMARY",
          "STOREKIT_SANDBOX_PURCHASE_SUMMARY",
          "STOREKIT_SANDBOX_RESTORE_SUMMARY",
          "STOREKIT_SANDBOX_FREE_QUOTA_SUMMARY",
          "STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY",
        ]
        && target.dryRunCommand.hasSuffix("--target storekit --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md")
    })
  }

  @MainActor
  func testReleaseReportProvidesRemotePublishLiveVerificationCommands() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)

    let commands = store.remotePublishLiveVerificationCommandMarkdown

    XCTAssertTrue(commands.contains("verify_remote_publish_live_matrix.sh"))
    XCTAssertTrue(commands.contains("verify_remote_publish_live_matrix.sh --execute"))
    XCTAssertTrue(commands.contains("verify_remote_publish_live.sh --provider github --mode direct --execute"))
    XCTAssertTrue(commands.contains("verify_remote_publish_live.sh --provider github --mode review --execute"))
    XCTAssertTrue(commands.contains("verify_remote_publish_live.sh --provider gitlab --mode direct --execute"))
    XCTAssertTrue(commands.contains("verify_remote_publish_live.sh --provider gitlab --mode review --execute"))
    XCTAssertTrue(commands.contains("prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target remote-publish"))
    XCTAssertTrue(commands.contains("docs/release-evidence/remote-publish-live.env.example"))
    XCTAssertTrue(commands.contains("REMOTE_VERIFY_GITHUB_TOKEN=\"<github-token>\""))
    XCTAssertTrue(commands.contains("REMOTE_VERIFY_GITLAB_TOKEN=\"<gitlab-token>\""))
    XCTAssertFalse(commands.contains("/Users/"))
    XCTAssertFalse(commands.contains("Authorization: Bearer"))
  }

  @MainActor
  func testStoreBlocksScreenshotExternalVerificationEvidenceUntilCapturedAndPrivacyPassed() throws {
    let root = try temporaryProjectRoot()
    try write("script/capture_app_screenshots.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/check_screenshot_privacy.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try writeScreenshotManifest(in: root)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)

    XCTAssertFalse(store.canRecordAppStoreScreenshotEvidence)

    store.recordAppStoreScreenshotExternalVerificationEvidence()

    XCTAssertNil(store.latestExternalVerificationEvidence(for: "app-store-screenshots"))
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("截图证据还未齐全") == true)
  }

  @MainActor
  func testStoreRecordsAppStoreScreenshotExternalVerificationEvidenceWhenGateIsReady() throws {
    let root = try temporaryProjectRoot()
    try writeScreenshotRecordingEvidence(in: root)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)

    XCTAssertTrue(store.canRecordAppStoreScreenshotEvidence)

    store.recordAppStoreScreenshotExternalVerificationEvidence()

    let evidence = try XCTUnwrap(store.latestExternalVerificationEvidence(for: "app-store-screenshots"))
    XCTAssertTrue(evidence.summary.contains("Screenshot set:"))
    XCTAssertTrue(evidence.summary.contains("Screenshot privacy gate:"))
    XCTAssertTrue(evidence.summary.contains("Screenshot strict gate:"))
    XCTAssertTrue(evidence.summary.contains("writing"))
    XCTAssertTrue(store.externalVerificationCoverageSummary.recordedCount >= 1)
  }

  @MainActor
  func testStoreRejectsUnstructuredExternalEvidenceForStructuredItems() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)

    store.recordExternalVerificationEvidence(
      itemID: "storekit-sandbox",
      summary: "StoreKit sandbox verified."
    )

    XCTAssertNil(store.latestExternalVerificationEvidence(for: "storekit-sandbox"))
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("结构化字段") == true)

    store.recordExternalVerificationEvidence(
      itemID: "github-direct-publish",
      summary: "GitHub direct verified."
    )

    XCTAssertNil(store.latestExternalVerificationEvidence(for: "github-direct-publish"))
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("Token scope") == true)
  }

  @MainActor
  func testStoreWritesStructuredExternalEvidenceFileForRoundTripImport() throws {
    let root = try temporaryProjectRoot()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)
    store.recordExternalVerificationEvidence(
      itemID: "storekit-sandbox",
      summary: structuredExternalSummary(for: "storekit-sandbox")
    )

    let evidenceURL = try store.writeExternalVerificationEvidenceFile(projectRoot: root)
    let content = try String(contentsOf: evidenceURL, encoding: .utf8)

    XCTAssertTrue(content.contains("- [x] `storekit-sandbox`"))
    XCTAssertTrue(content.contains("- StoreKit product lookup:"))
    XCTAssertTrue(content.contains("- StoreKit purchase:"))

    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("roundtrip.json"))
    )
    reloaded.refreshReleaseQualityGate(projectRoot: root)
    let importedCount = try reloaded.importExternalVerificationEvidenceFile(projectRoot: root)

    XCTAssertEqual(importedCount, 1)
    XCTAssertTrue(reloaded.latestExternalVerificationEvidence(for: "storekit-sandbox")?.summary.contains("StoreKit restore:") == true)
  }

  @MainActor
  func testStoreImportsExternalVerificationEvidenceFileWithoutDuplicatingItems() throws {
    let root = try temporaryProjectRoot()
    try write(
      "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md",
      in: root,
      content: """
      # External Verification Evidence

      - [x] `github-direct-publish` - GitHub direct verified.
      - [x] `storekit-sandbox` - StoreKit sandbox verified.

      ### StoreKit sandbox 购买与恢复
      - StoreKit product lookup: Sandbox loaded product.
      - StoreKit purchase: Purchase completed.
      - StoreKit restore: Restore completed.
      - StoreKit free quota: Free quota boundary verified.
      - StoreKit boundary events: Recent Pro boundary events showed free-plan block and Pro no-quota allow.
      """
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)
    store.recordExternalVerificationEvidence(
      itemID: "github-direct-publish",
      summary: structuredExternalSummary(for: "github-direct-publish")
    )

    let importedCount = try store.importExternalVerificationEvidenceFile(projectRoot: root)
    let secondImportCount = try store.importExternalVerificationEvidenceFile(projectRoot: root)

    XCTAssertEqual(importedCount, 1)
    XCTAssertEqual(secondImportCount, 0)
    XCTAssertEqual(store.externalVerificationEvidenceRecords(for: "github-direct-publish").count, 1)
    XCTAssertTrue(store.latestExternalVerificationEvidence(for: "storekit-sandbox")?.summary.contains("StoreKit product lookup:") == true)
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("没有新的完成项") == true)
  }

  @MainActor
  func testStoreAppliesEvidenceToAppStoreChecklist() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseGateEvidence(in: root)
    try writeStoreKitEvidence(in: root)
    try write(
      "APP_STORE_CHECKLIST.md",
      in: root,
      content: """
      # App Store Release Checklist

      - [ ] Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements.
      - [ ] Confirm distribution signing team and hardened runtime on the archived app.
      - [ ] Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.
      - [ ] Validate the archive with App Store Connect or Transporter before upload.
      """
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    store.refreshReleaseQualityGate(projectRoot: root)
    store.recordExternalVerificationEvidence(
      itemID: "storekit-sandbox",
      summary: structuredExternalSummary(for: "storekit-sandbox")
    )

    let updatedCount = try store.applyEvidenceToAppStoreChecklist(projectRoot: root)
    let updatedChecklist = try String(contentsOf: root.appendingPathComponent("APP_STORE_CHECKLIST.md"), encoding: .utf8)

    XCTAssertEqual(updatedCount, 4)
    XCTAssertTrue(updatedChecklist.contains("- [x] Confirm bundle identifier"))
    XCTAssertTrue(updatedChecklist.contains("- [x] Confirm distribution signing team and hardened runtime on the archived app."))
    XCTAssertTrue(updatedChecklist.contains("- [x] Verify StoreKit product ID"))
    XCTAssertTrue(updatedChecklist.contains("- [x] Validate the archive with App Store Connect or Transporter before upload."))
    XCTAssertTrue(store.releaseQualityGateMessage?.contains("已用现有证据勾选 4 个") == true)
  }

  func testLegacySnapshotDecodesWithEmptyExternalVerificationEvidenceRecords() throws {
    let profile = SiteProfile.defaultProfile
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [ArticleDraft(siteProfileID: profile.id, title: "Legacy", slug: "legacy")],
        releaseRecords: []
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "externalVerificationEvidenceRecords")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertTrue(snapshot.externalVerificationEvidenceRecords.isEmpty)
  }

  func testAppStoreChecklistListsUncheckedItemsInGateMessage() throws {
    let root = try temporaryProjectRoot()
    try write(
      "APP_STORE_CHECKLIST.md",
      in: root,
      content: """
      # App Store Release Checklist

      - [x] Add repeatable UI runtime gate.
      - [ ] Capture required screenshots.
      - [ ] Verify StoreKit sandbox purchase and restore.
      - [ ] Verify GitHub direct commit with least-privilege token.
      - [ ] Verify GitLab merge request publish path.
      """
    )

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let checklist = try XCTUnwrap(report.items.first { $0.id == "app-store-checklist" })
    XCTAssertEqual(checklist.status, .blocked)
    XCTAssertTrue(checklist.message.contains("4 个未完成项"))
    XCTAssertTrue(checklist.message.contains("Capture required screenshots."))
    XCTAssertTrue(checklist.message.contains("Verify StoreKit sandbox purchase and restore."))
    XCTAssertTrue(checklist.message.contains("Verify GitHub direct commit with least-privilege token."))
    XCTAssertTrue(checklist.message.contains("…"))
    XCTAssertTrue(checklist.evidence?.contains("Verify GitLab merge request publish path.") == true)
  }

  func testWorkspaceCoverageRequiresEveryProductWorkspace() throws {
    let root = try temporaryProjectRoot()
    let legacyPublishingSections: [WorkspaceSection] = [
      .ai,
      .sync,
      .contentHealth,
      .maintenance,
      .images,
      .releaseHistory,
    ]

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      workspaceSections: legacyPublishingSections,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let workspaceCoverage = try XCTUnwrap(report.items.first { $0.id == "workspace-coverage" })
    XCTAssertEqual(workspaceCoverage.status, .blocked)
    XCTAssertTrue(workspaceCoverage.message.contains("素材库"))
    XCTAssertTrue(workspaceCoverage.message.contains("上架门禁"))
    XCTAssertTrue(report.blockingItems.contains { $0.id == "workspace-coverage" })
  }

  func testProductCapabilityGateBlocksMissingMobileParityCapabilities() throws {
    let root = try temporaryProjectRoot()

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true,
      productCapabilities: ReleaseProductCapabilityCoverage(
        onlinePublishing: false,
        remoteSyncCenter: false,
        repositoryAutoSync: false,
        seoSocialPreview: false,
        deploymentStatusPanel: false,
        siteMaintenanceWorkspace: false,
        releaseLedgerRollback: false,
        generalDraftWorkspace: false,
        privacyProtection: false,
        proBoundary: false,
        aiChatWorkspace: false
      )
    )

    let blockedIDs = Set(report.blockingItems.map(\.id))
    XCTAssertTrue(blockedIDs.contains("online-publishing"))
    XCTAssertTrue(blockedIDs.contains("remote-sync-center"))
    XCTAssertTrue(blockedIDs.contains("repository-auto-sync"))
    XCTAssertTrue(blockedIDs.contains("seo-social-preview"))
    XCTAssertTrue(blockedIDs.contains("deployment-status"))
    XCTAssertTrue(blockedIDs.contains("site-maintenance"))
    XCTAssertTrue(blockedIDs.contains("release-ledger-rollback"))
    XCTAssertTrue(blockedIDs.contains("general-drafts"))
    XCTAssertTrue(blockedIDs.contains("privacy-lock"))
    XCTAssertTrue(blockedIDs.contains("pro-boundary"))
    XCTAssertTrue(blockedIDs.contains("ai-chat-workspace"))
  }

  func testRepositoryAutoSyncGateRequiresSchedulerUIAndRegressionTests() throws {
    let root = try temporaryProjectRoot()
    try writeRepositoryAutoSyncEvidence(in: root, includeTickScheduler: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let autoSync = try XCTUnwrap(report.items.first { $0.id == "repository-auto-sync" })
    XCTAssertEqual(autoSync.status, .blocked)
    XCTAssertTrue(autoSync.message.contains("到期调度入口"))
    XCTAssertTrue(autoSync.evidence?.contains("RepositoryAutoSyncTests.swift") == true)
  }

  func testAIChatWorkspaceGateRequiresDedicatedChatContextRegenerateAndAttachmentCoverage() throws {
    let root = try temporaryProjectRoot()
    try writeAIChatWorkspaceEvidence(in: root, includeAttachmentTests: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let aiChatWorkspace = try XCTUnwrap(report.items.first { $0.id == "ai-chat-workspace" })
    XCTAssertEqual(aiChatWorkspace.status, .blocked)
    XCTAssertTrue(aiChatWorkspace.message.contains("附件加载测试"))
    XCTAssertTrue(aiChatWorkspace.evidence?.contains("AIChatWorkspaceView.swift") == true)
    XCTAssertTrue(aiChatWorkspace.evidence?.contains("WorkbenchStoreAIPromptTests.swift") == true)
  }

  func testAIChatWorkspaceGateBlocksMetadataInspectorAssistantRegression() throws {
    let root = try temporaryProjectRoot()
    try writeAIChatWorkspaceEvidence(in: root, includeInspectorBoundary: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let aiChatWorkspace = try XCTUnwrap(report.items.first { $0.id == "ai-chat-workspace" })
    XCTAssertEqual(aiChatWorkspace.status, .blocked)
    XCTAssertTrue(aiChatWorkspace.message.contains("写作 Inspector 不包含 AI 发布助手边界"))
    XCTAssertTrue(aiChatWorkspace.message.contains("写作 Inspector 不包含 AI 发布助手文案"))
    XCTAssertTrue(aiChatWorkspace.evidence?.contains("AIChatWorkspaceView.swift") == true)
  }

  func testOnlinePublishingGateRequiresProviderAPIsStoreEntrypointsAndRegressionTests() throws {
    let root = try temporaryProjectRoot()
    try writeOnlinePublishingEvidence(in: root, includeGitLabMergeRequest: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let onlinePublishing = try XCTUnwrap(report.items.first { $0.id == "online-publishing" })
    XCTAssertEqual(onlinePublishing.status, .blocked)
    XCTAssertTrue(onlinePublishing.message.contains("GitLab MR API"))
    XCTAssertTrue(onlinePublishing.evidence?.contains("RemoteRepositoryPublishService.swift") == true)
    XCTAssertTrue(onlinePublishing.evidence?.contains("RemoteRepositoryPublishServiceTests.swift") == true)
  }

  func testOnlinePublishingGateRequiresRemoteRollbackAndReviewWithdrawalCoverage() throws {
    let root = try temporaryProjectRoot()
    try writeOnlinePublishingEvidence(in: root, includeReviewWithdrawal: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let onlinePublishing = try XCTUnwrap(report.items.first { $0.id == "online-publishing" })
    XCTAssertEqual(onlinePublishing.status, .blocked)
    XCTAssertTrue(onlinePublishing.message.contains("Review 撤回 API"))
    XCTAssertTrue(onlinePublishing.evidence?.contains("RemoteRepositoryPublishService.swift") == true)
    XCTAssertTrue(onlinePublishing.evidence?.contains("RemoteRepositoryPublishServiceTests.swift") == true)
  }

  func testOnlinePublishingGateRequiresGitLabJSONAcceptHeaderCoverage() throws {
    let root = try temporaryProjectRoot()
    try writeOnlinePublishingEvidence(in: root, includeGitLabAcceptHeader: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let onlinePublishing = try XCTUnwrap(report.items.first { $0.id == "online-publishing" })
    XCTAssertEqual(onlinePublishing.status, .blocked)
    XCTAssertTrue(onlinePublishing.message.contains("GitLab JSON Accept 头"))
    XCTAssertTrue(onlinePublishing.evidence?.contains("RemoteRepositoryPublishService.swift") == true)
    XCTAssertTrue(onlinePublishing.evidence?.contains("RemoteRepositoryPublishServiceTests.swift") == true)
  }

  func testOnlinePublishingGateRequiresReviewDeploymentBoundaryCoverage() throws {
    let root = try temporaryProjectRoot()
    try writeOnlinePublishingEvidence(in: root, includeReviewDeploymentBoundary: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let onlinePublishing = try XCTUnwrap(report.items.first { $0.id == "online-publishing" })
    XCTAssertEqual(onlinePublishing.status, .blocked)
    XCTAssertTrue(onlinePublishing.message.contains("Review 发布不触发部署校验边界"))
    XCTAssertTrue(onlinePublishing.message.contains("Review 历史部署快照过滤"))
    XCTAssertTrue(onlinePublishing.message.contains("Review 发布等待合并测试"))
    XCTAssertTrue(onlinePublishing.evidence?.contains("WorkbenchStore.swift") == true)
  }

  func testRemoteSyncCenterGateRequiresTokenConflictPreviewUIAndRegressionTests() throws {
    let root = try temporaryProjectRoot()
    try writeRemoteSyncCenterEvidence(in: root, includeBatchConflictTest: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let remoteSync = try XCTUnwrap(report.items.first { $0.id == "remote-sync-center" })
    XCTAssertEqual(remoteSync.status, .blocked)
    XCTAssertTrue(remoteSync.message.contains("批量远端冲突预览测试"))
    XCTAssertTrue(remoteSync.evidence?.contains("RemoteRepositoryPublishPreview.swift") == true)
    XCTAssertTrue(remoteSync.evidence?.contains("WorkbenchStoreProfileTests.swift") == true)
  }

  func testSEOSocialPreviewGateRequiresCardsCacheAIAndRelatedArticleCoverage() throws {
    let root = try temporaryProjectRoot()
    try writeSEOSocialPreviewEvidence(in: root, includeManualRefreshTest: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let seoSocialPreview = try XCTUnwrap(report.items.first { $0.id == "seo-social-preview" })
    XCTAssertEqual(seoSocialPreview.status, .blocked)
    XCTAssertTrue(seoSocialPreview.message.contains("缓存和手动刷新测试"))
    XCTAssertTrue(seoSocialPreview.evidence?.contains("SEOSocialPreviewService.swift") == true)
    XCTAssertTrue(seoSocialPreview.evidence?.contains("SEOSocialPreviewServiceTests.swift") == true)
  }

  func testSEOSocialPreviewGateRequiresAIChatEntrypoint() throws {
    let root = try temporaryProjectRoot()
    try writeSEOSocialPreviewEvidence(in: root, includeAIChatEntrypoint: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let seoSocialPreview = try XCTUnwrap(report.items.first { $0.id == "seo-social-preview" })
    XCTAssertEqual(seoSocialPreview.status, .blocked)
    XCTAssertTrue(seoSocialPreview.message.contains("SEO 社交预览 AI Prompt"))
    XCTAssertTrue(seoSocialPreview.message.contains("AI 对话入口"))
    XCTAssertTrue(seoSocialPreview.evidence?.contains("SEOSocialPreviewService.swift") == true)
  }

  func testSEOSocialPreviewGateRequiresDeploymentSiteURLProductionMetaCoverage() throws {
    let root = try temporaryProjectRoot()
    try writeSEOSocialPreviewEvidence(in: root, includeDeploymentSiteURLTest: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let seoSocialPreview = try XCTUnwrap(report.items.first { $0.id == "seo-social-preview" })
    XCTAssertEqual(seoSocialPreview.status, .blocked)
    XCTAssertTrue(seoSocialPreview.message.contains("线上部署 URL 社交元数据测试"))
    XCTAssertTrue(seoSocialPreview.evidence?.contains("SEOSocialPreviewService.swift") == true)
    XCTAssertTrue(seoSocialPreview.evidence?.contains("SEOSocialPreviewServiceTests.swift") == true)
  }

  func testDeploymentStatusGateRequiresProvidersPollingUIAndRegressionTests() throws {
    let root = try temporaryProjectRoot()
    try writeDeploymentStatusEvidence(in: root, includeGitLabPipelineTest: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let deploymentStatus = try XCTUnwrap(report.items.first { $0.id == "deployment-status" })
    XCTAssertEqual(deploymentStatus.status, .blocked)
    XCTAssertTrue(deploymentStatus.message.contains("GitLab Pipeline 测试"))
    XCTAssertTrue(deploymentStatus.evidence?.contains("DeploymentStatusService.swift") == true)
    XCTAssertTrue(deploymentStatus.evidence?.contains("DeploymentStatusServiceTests.swift") == true)
  }

  func testDeploymentStatusGateRequiresPostPublishHistoryEvidence() throws {
    let root = try temporaryProjectRoot()
    try writeDeploymentStatusEvidence(in: root, includeHistoryEvidence: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let deploymentStatus = try XCTUnwrap(report.items.first { $0.id == "deployment-status" })
    XCTAssertEqual(deploymentStatus.status, .blocked)
    XCTAssertTrue(deploymentStatus.message.contains("部署状态历史缓存"))
    XCTAssertTrue(deploymentStatus.message.contains("发布后校验历史轨迹"))
    XCTAssertTrue(deploymentStatus.evidence?.contains("DeploymentStatusServiceTests.swift") == true)
  }

  func testDeploymentStatusGateRequiresPostPublishSocialMetadataEvidence() throws {
    let root = try temporaryProjectRoot()
    try writeDeploymentStatusEvidence(in: root, includeSocialMetadataEvidence: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let deploymentStatus = try XCTUnwrap(report.items.first { $0.id == "deployment-status" })
    XCTAssertEqual(deploymentStatus.status, .blocked)
    XCTAssertTrue(deploymentStatus.message.contains("发布后社交元数据校验"))
    XCTAssertTrue(deploymentStatus.message.contains("发布页面社交元数据成功测试"))
    XCTAssertTrue(deploymentStatus.evidence?.contains("DeploymentStatusServiceTests.swift") == true)
  }

  func testSiteMaintenanceGateRequiresCalendarTaxonomyRelationsLinksOperationsAndTests() throws {
    let root = try temporaryProjectRoot()
    try writeSiteMaintenanceEvidence(in: root, includeRelationSuggestionTest: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let siteMaintenance = try XCTUnwrap(report.items.first { $0.id == "site-maintenance" })
    XCTAssertEqual(siteMaintenance.status, .blocked)
    XCTAssertTrue(siteMaintenance.message.contains("文章关系建议测试"))
    XCTAssertTrue(siteMaintenance.evidence?.contains("SiteMaintenanceService.swift") == true)
    XCTAssertTrue(siteMaintenance.evidence?.contains("SiteMaintenanceServiceTests.swift") == true)
  }

  func testSiteMaintenanceGateRequiresMaintenanceActionAIEntrypoint() throws {
    let root = try temporaryProjectRoot()
    try writeSiteMaintenanceEvidence(in: root, includeMaintenanceAIEntrypoint: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let siteMaintenance = try XCTUnwrap(report.items.first { $0.id == "site-maintenance" })
    XCTAssertEqual(siteMaintenance.status, .blocked)
    XCTAssertTrue(siteMaintenance.message.contains("维护行动 AI Prompt"))
    XCTAssertTrue(siteMaintenance.message.contains("维护任务 AI 入口"))
    XCTAssertTrue(siteMaintenance.evidence?.contains("SiteMaintenanceServiceTests.swift") == true)
  }

  func testReleaseLedgerRollbackGateRequiresPendingRecoveryRollbackUIAndEvidenceTests() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseLedgerRollbackEvidence(in: root, includeRecoveryPackageTest: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let releaseLedger = try XCTUnwrap(report.items.first { $0.id == "release-ledger-rollback" })
    XCTAssertEqual(releaseLedger.status, .blocked)
    XCTAssertTrue(releaseLedger.message.contains("恢复包测试"))
    XCTAssertTrue(releaseLedger.evidence?.contains("ReleaseLedgerService.swift") == true)
    XCTAssertTrue(releaseLedger.evidence?.contains("ReleaseLedgerServiceTests.swift") == true)
  }

  func testReleaseLedgerRollbackGateRequiresRemoteOperationRecordsAndUI() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseLedgerRollbackEvidence(in: root, includeRemoteOperationRecords: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let releaseLedger = try XCTUnwrap(report.items.first { $0.id == "release-ledger-rollback" })
    XCTAssertEqual(releaseLedger.status, .blocked)
    XCTAssertTrue(releaseLedger.message.contains("远端回滚发布记录类型"))
    XCTAssertTrue(releaseLedger.evidence?.contains("ReleaseLedgerService.swift") == true)
    XCTAssertTrue(releaseLedger.evidence?.contains("ReleaseLedgerServiceTests.swift") == true)
  }

  func testReleaseLedgerRollbackGateRequiresRollbackDeploymentCheck() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseLedgerRollbackEvidence(in: root, includeRollbackDeploymentCheck: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let releaseLedger = try XCTUnwrap(report.items.first { $0.id == "release-ledger-rollback" })
    XCTAssertEqual(releaseLedger.status, .blocked)
    XCTAssertTrue(releaseLedger.message.contains("线上回滚后部署校验"))
    XCTAssertTrue(releaseLedger.message.contains("线上回滚部署校验测试"))
    XCTAssertTrue(releaseLedger.evidence?.contains("WorkbenchStore.swift") == true)
  }

  func testReleaseLedgerRollbackGateRequiresRecoveryPackageAIEntrypoint() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseLedgerRollbackEvidence(in: root, includeRecoveryAIEntrypoint: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let releaseLedger = try XCTUnwrap(report.items.first { $0.id == "release-ledger-rollback" })
    XCTAssertEqual(releaseLedger.status, .blocked)
    XCTAssertTrue(releaseLedger.message.contains("发布恢复 AI Prompt"))
    XCTAssertTrue(releaseLedger.message.contains("恢复包 AI 入口"))
    XCTAssertTrue(releaseLedger.evidence?.contains("ReleaseLedgerService.swift") == true)
  }

  func testReleaseLedgerRollbackGateRequiresRemoteRecoveryVerificationDraft() throws {
    let root = try temporaryProjectRoot()
    try writeReleaseLedgerRollbackEvidence(in: root, includeRecoveryVerificationDraft: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let releaseLedger = try XCTUnwrap(report.items.first { $0.id == "release-ledger-rollback" })
    XCTAssertEqual(releaseLedger.status, .blocked)
    XCTAssertTrue(releaseLedger.message.contains("远端恢复验收草稿"))
    XCTAssertTrue(releaseLedger.message.contains("Store 远端恢复验收草稿入口"))
    XCTAssertTrue(releaseLedger.evidence?.contains("ReleaseLedgerService.swift") == true)
  }

  func testGeneralDraftWorkspaceGateRequiresWorkspaceBackupUIAndRegressionTests() throws {
    let root = try temporaryProjectRoot()
    try writeGeneralDraftWorkspaceEvidence(in: root, includeBackupWriteTest: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let generalDrafts = try XCTUnwrap(report.items.first { $0.id == "general-drafts" })
    XCTAssertEqual(generalDrafts.status, .blocked)
    XCTAssertTrue(generalDrafts.message.contains("备份写入测试"))
    XCTAssertTrue(generalDrafts.evidence?.contains("GeneralDraftLibraryService.swift") == true)
    XCTAssertTrue(generalDrafts.evidence?.contains("GeneralDraftLibraryServiceTests.swift") == true)
  }

  func testGeneralDraftWorkspaceGateRequiresAIReusePlanPromptAndEntrypoints() throws {
    let root = try temporaryProjectRoot()
    try writeGeneralDraftWorkspaceEvidence(in: root, includeAIReusePrompt: false)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let generalDrafts = try XCTUnwrap(report.items.first { $0.id == "general-drafts" })
    XCTAssertEqual(generalDrafts.status, .blocked)
    XCTAssertTrue(generalDrafts.message.contains("跨站复用 AI Prompt"))
    XCTAssertTrue(generalDrafts.evidence?.contains("GeneralDraftLibraryService.swift") == true)
  }

  func testPrivacyProtectionGateRequiresLockMaskingSettingsAndRegressionTests() throws {
    let root = try temporaryProjectRoot()
    try writeRepositoryAutoSyncEvidence(in: root)
    try writePrivacySupportCopyEvidence(in: root, includeAIRequestBlockTest: false)
    try writeStoreKitEvidence(in: root)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let privacy = try XCTUnwrap(report.items.first { $0.id == "privacy-lock" })
    XCTAssertEqual(privacy.status, .blocked)
    XCTAssertTrue(privacy.message.contains("AI 请求锁定测试"))
    XCTAssertTrue(privacy.evidence?.contains("PrivacyProtectionModels.swift") == true)
    XCTAssertTrue(privacy.evidence?.contains("PrivacyProtectionTests.swift") == true)
  }

  func testPrivacyProtectionGateRequiresSettingsWindowInactiveLocking() throws {
    let root = try temporaryProjectRoot()
    try writeRepositoryAutoSyncEvidence(in: root)
    try writePrivacySupportCopyEvidence(in: root, includeSettingsInactiveLock: false)
    try writeStoreKitEvidence(in: root)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let privacy = try XCTUnwrap(report.items.first { $0.id == "privacy-lock" })
    XCTAssertEqual(privacy.status, .blocked)
    XCTAssertTrue(privacy.message.contains("设置窗口后台锁定"))
    XCTAssertTrue(privacy.evidence?.contains("PrivacyProtectionModels.swift") == true)
  }

  func testPrivacyProtectionGateRequiresPrivateCopyPackageMasking() throws {
    let root = try temporaryProjectRoot()
    try writeRepositoryAutoSyncEvidence(in: root, includePrivateCopyPackageMasking: false)
    try writePrivacySupportCopyEvidence(in: root, includePrivateCopyPackageMasking: false)
    try writeStoreKitEvidence(in: root)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let privacy = try XCTUnwrap(report.items.first { $0.id == "privacy-lock" })
    XCTAssertEqual(privacy.status, .blocked)
    XCTAssertTrue(privacy.message.contains("私密复制包遮挡"))
    XCTAssertTrue(privacy.message.contains("SEO/Social 复制包遮挡测试"))
    XCTAssertTrue(privacy.evidence?.contains("PrivacyProtectionTests.swift") == true)
  }

  func testProBoundaryGateRequiresUpgradeCopyForEveryPremiumFeature() throws {
    let root = try temporaryProjectRoot()
    let partialRequirements = MonetizationService(
      limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
    )
    .upgradeRequirements(state: .default)
    .filter { $0.feature != .onlinePublishing }

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      proUpgradeRequirements: partialRequirements,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let proBoundary = try XCTUnwrap(report.items.first { $0.id == "pro-boundary" })
    XCTAssertEqual(proBoundary.status, .blocked)
    XCTAssertTrue(proBoundary.message.contains(PremiumFeature.onlinePublishing.displayName))
    XCTAssertTrue(proBoundary.evidence?.contains(PremiumFeature.aiRequest.displayName) == true)
  }

  func testProBoundaryGateBlocksExplicitlyMissingUpgradeRequirements() throws {
    let root = try temporaryProjectRoot()

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      proUpgradeRequirements: [],
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let proBoundary = try XCTUnwrap(report.items.first { $0.id == "pro-boundary" })
    XCTAssertEqual(proBoundary.status, .blocked)
    XCTAssertTrue(proBoundary.message.contains("免费版额度"))
    XCTAssertNil(proBoundary.evidence)
  }

  func testProBoundaryGatePassesWithActionableUpgradeRequirements() throws {
    let root = try temporaryProjectRoot()
    try writeProBoundaryEvidence(in: root)
    let requirements = MonetizationService(
      limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
    )
    .upgradeRequirements(state: .default)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      proUpgradeRequirements: requirements,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let proBoundary = try XCTUnwrap(report.items.first { $0.id == "pro-boundary" })
    XCTAssertEqual(proBoundary.status, .passed)
    XCTAssertTrue(proBoundary.message.contains("AI 请求"))
    XCTAssertTrue(proBoundary.message.contains("GitHub/GitLab"))
    XCTAssertTrue(proBoundary.message.contains("批量发布"))
    XCTAssertTrue(proBoundary.evidence?.contains("需要 Pro") == true)
    XCTAssertTrue(proBoundary.evidence?.contains("购买或恢复") == true)
  }

  func testProBoundaryGateRequiresSourceLevelFreeQuotaAndBlockedFeatureCoverage() throws {
    let root = try temporaryProjectRoot()
    try writeProBoundaryEvidence(in: root, includeOnlinePublishingConsumption: false)
    let requirements = MonetizationService(
      limits: FreePlanLimits(aiRequestLimit: 0, onlinePublishAttemptLimit: 0, batchPublishLimit: 0)
    )
    .upgradeRequirements(state: .default)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      proUpgradeRequirements: requirements,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let proBoundary = try XCTUnwrap(report.items.first { $0.id == "pro-boundary" })
    XCTAssertEqual(proBoundary.status, .blocked)
    XCTAssertTrue(proBoundary.message.contains("线上发布额度消耗"))
    XCTAssertTrue(proBoundary.evidence?.contains("WorkbenchStore.swift") == true)
    XCTAssertTrue(proBoundary.evidence?.contains("MonetizationTests.swift") == true)
  }

  func testStoreKitSandboxBlocksWhenProductIDIsMissing() throws {
    let root = try temporaryProjectRoot()
    try write("StoreKit/PersonalSitePublisher.storekit", in: root, content: """
    {
      "nonConsumables": [
        {
          "productID": "wrong.product",
          "referenceName": "Wrong Pro"
        }
      ]
    }
    """)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let storeKitItem = try XCTUnwrap(report.items.first { $0.id == "storekit-sandbox" })
    XCTAssertEqual(storeKitItem.status, .blocked)
    XCTAssertTrue(storeKitItem.message.contains("Pro 产品 ID"))
  }

  func testAppStoreMetadataGateRequiresScriptBuildMetadataAndSandboxEntitlements() throws {
    let root = try temporaryProjectRoot()
    try write("script/check_app_store_metadata.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write(
      "script/build_and_run.sh",
      in: root,
      content: """
      #!/bin/sh
      echo CFBundleIdentifier
      echo CFBundleShortVersionString
      echo CFBundleVersion
      echo CFBundleIconFile
      echo CFBundleDisplayName
      echo LSMinimumSystemVersion
      """
    )
    try write("Sources/App/AppStore.entitlements", in: root, content: """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
      <key>com.apple.security.app-sandbox</key>
      <true/>
    </dict>
    </plist>
    """)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let metadata = try XCTUnwrap(report.items.first { $0.id == "app-store-metadata" })
    XCTAssertEqual(metadata.status, .blocked)
    XCTAssertTrue(metadata.message.contains("Network Client"))
    XCTAssertTrue(metadata.message.contains("User Selected Read/Write"))
  }

  func testAppStoreMetadataGateBlocksWhenBuildScriptOmitsVersionMetadata() throws {
    let root = try temporaryProjectRoot()
    try write("script/check_app_store_metadata.sh", in: root, content: "#!/bin/sh\nexit 0\n")
    try write("script/build_and_run.sh", in: root, content: "#!/bin/sh\necho CFBundleIdentifier\n")
    try write("Sources/App/AppStore.entitlements", in: root, content: appStoreEntitlements)

    let report = ReleaseQualityGateService().report(
      projectRoot: root,
      hasPrivacyProtection: true,
      hasProBoundary: true,
      hasDeploymentStatusPanel: true,
      hasAIChatWorkspace: true
    )

    let metadata = try XCTUnwrap(report.items.first { $0.id == "app-store-metadata" })
    XCTAssertEqual(metadata.status, .blocked)
    XCTAssertTrue(metadata.message.contains("版本号"))
    XCTAssertTrue(metadata.message.contains("Build number"))
  }
}
