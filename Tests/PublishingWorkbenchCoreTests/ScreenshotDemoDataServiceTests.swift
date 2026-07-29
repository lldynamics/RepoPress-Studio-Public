import Darwin
import XCTest
@testable import PublishingWorkbenchCore

final class ScreenshotDemoDataServiceTests: XCTestCase {
  func testScreenshotDemoSnapshotCoversReleaseScreenshotSurfacesWithoutSensitiveValues() throws {
    let snapshot = ScreenshotDemoDataService().makeSnapshot()

    XCTAssertEqual(snapshot.profiles.count, 2)
    XCTAssertTrue(snapshot.profiles.allSatisfy { $0.purpose == .publishing })
    XCTAssertEqual(snapshot.activeProfileID, snapshot.profiles.first?.id)
    XCTAssertTrue(snapshot.drafts.contains { $0.visibility == .private })
    XCTAssertTrue(snapshot.drafts.contains(where: \.isGeneralDraft))
    XCTAssertTrue(snapshot.drafts.contains { $0.siteProfileID == snapshot.activeProfileID && $0.status == .ready })
    XCTAssertTrue(snapshot.drafts.contains { draft in
      draft.siteProfileID != snapshot.activeProfileID
        && snapshot.profiles.contains { $0.id == draft.siteProfileID && $0.purpose == .publishing }
    })

    XCTAssertTrue(snapshot.releaseRecords.contains { $0.kind == .remoteDirectCommit })
    XCTAssertTrue(snapshot.releaseRecords.contains { $0.kind == .remoteReviewRequest })
    XCTAssertTrue(snapshot.releaseRecords.contains { $0.kind == .remotePublishFailure })
    XCTAssertFalse(snapshot.deploymentStatusSnapshots.isEmpty)
    XCTAssertEqual(snapshot.deploymentStatusSnapshots.first?.level, .success)
    XCTAssertFalse(snapshot.seoSocialPreviewSnapshots.isEmpty)
    XCTAssertEqual(Set(snapshot.seoSocialPreviewSnapshots.first?.cards.map(\.kind) ?? []), Set(SEOSocialPreviewCardKind.allCases))
    XCTAssertTrue(snapshot.repositoryAutoSyncSettings.isEnabled)
    XCTAssertTrue(snapshot.repositoryAutoSyncSettings.fetchBeforeScan)
    XCTAssertTrue(snapshot.deploymentPollingSettings.isEnabled)
    XCTAssertTrue(snapshot.privacySettings.masksPrivateContent)
    XCTAssertFalse(snapshot.monetizationState.entitlement.isUnlocked)
    XCTAssertEqual(snapshot.monetizationState.freeUsage.aiRequestCount, 9)

    let encoded = String(data: try JSONEncoder.workbench.encode(snapshot), encoding: .utf8) ?? ""
    XCTAssertFalse(encoded.contains("/Users/"))
    XCTAssertFalse(encoded.localizedCaseInsensitiveContains("bearer "))
    XCTAssertFalse(encoded.localizedCaseInsensitiveContains("authorization"))
    XCTAssertFalse(encoded.contains("sk-"))
    XCTAssertFalse(encoded.contains("aiChatSessionsByDraftID"))
  }

  func testScreenshotDemoSurfaceMapsRequiredScreenshotIDs() {
    let requiredIDs: Set<String> = [
      "writing",
      "ai-chat",
      "sync-api-publish",
      "seo-social-preview",
      "deployment-status",
      "maintenance",
      "general-drafts",
      "knowledge-library",
      "pro-settings",
      "privacy-lock",
    ]

    XCTAssertEqual(Set(ScreenshotDemoSurface.allCases.map(\.rawValue)), requiredIDs)
    XCTAssertEqual(ScreenshotDemoSurface(rawValue: "ai-chat"), .aiChat)
    XCTAssertEqual(ScreenshotDemoSurface(rawValue: "sync-api-publish"), .syncAPIPublish)
    XCTAssertEqual(ScreenshotDemoSurface(rawValue: "deployment-status"), .deploymentStatus)
    XCTAssertEqual(ScreenshotDemoSurface(rawValue: "general-drafts"), .generalDrafts)
    XCTAssertEqual(ScreenshotDemoSurface(rawValue: "knowledge-library"), .knowledgeLibrary)
    XCTAssertEqual(ScreenshotDemoSurface(rawValue: "privacy-lock"), .privacyLock)
  }

  func testScreenshotDemoSurfaceCanBeReadFromEnvironment() {
    setenv(ScreenshotDemoDataService.environmentKey, "1", 1)
    setenv(ScreenshotDemoDataService.surfaceEnvironmentKey, "deployment-status", 1)
    defer {
      unsetenv(ScreenshotDemoDataService.environmentKey)
      unsetenv(ScreenshotDemoDataService.surfaceEnvironmentKey)
    }

    XCTAssertTrue(ScreenshotDemoDataService.isEnabledFromEnvironment)
    XCTAssertEqual(ScreenshotDemoDataService.requestedSurfaceFromEnvironment, .deploymentStatus)
  }

  @MainActor
  func testScreenshotDemoSnapshotCanSeedWorkbenchStoreFromIsolatedPersistence() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacScreenshotDemoTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let persistence = WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json"))
    _ = try persistence.save(ScreenshotDemoDataService().makeSnapshot())

    let store = WorkbenchStore(persistence: persistence)

    XCTAssertEqual(store.activeProfile.name, "示例个人网站")
    XCTAssertTrue(store.visibleDrafts.contains { $0.title == "RepoPress Studio 发布流程" })
    XCTAssertTrue(store.visibleDrafts.contains { $0.visibility == .private })
    XCTAssertEqual(store.activeProfileReleaseLedger.summary.rollbackAvailableCount, 3)
    XCTAssertEqual(store.activeProfileDeploymentStatusSnapshots.count, 1)
    XCTAssertEqual(store.seoSocialPreviewSnapshots.count, 1)
    XCTAssertTrue(store.repositoryAutoSyncSettings.isEnabled)
    XCTAssertTrue(store.deploymentPollingSettings.isEnabled)
    XCTAssertEqual(store.proStatusSummary.entitlement.source, .none)
  }

  @MainActor
  func testScreenshotDemoSurfacesPrepareStoreForTargetWorkspaces() throws {
    let store = try makeScreenshotStore()

    ScreenshotDemoSurface.aiChat.apply(to: store)
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.isAIPublishingAssistantPresented)
    XCTAssertFalse(store.aiChatMessages.isEmpty)
    XCTAssertFalse(store.isPrivacyLocked)

    ScreenshotDemoSurface.deploymentStatus.apply(to: store)
    XCTAssertEqual(store.selectedSection, .releaseHistory)
    XCTAssertEqual(store.activeProfileDeploymentStatusSnapshots.count, 1)
    XCTAssertEqual(store.deploymentStatusMessage, "截图模式：部署状态和轮询记录已载入。")

    ScreenshotDemoSurface.seoSocialPreview.apply(to: store)
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.isInspectorPresented)
    XCTAssertEqual(store.seoSocialPreviewSnapshots.count, 1)

    ScreenshotDemoSurface.generalDrafts.apply(to: store)
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.draftListContentScope, .general)
    XCTAssertEqual(store.publishActionMessage, "截图模式：通用草稿已载入。")

    ScreenshotDemoSurface.privacyLock.apply(to: store)
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertTrue(store.isPrivacyLocked)
    XCTAssertTrue(store.privacyLockReason?.contains("私密内容已遮挡") == true)
  }

  @MainActor
  private func makeScreenshotStore() throws -> WorkbenchStore {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacScreenshotDemoTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let persistence = WorkbenchPersistence(fileURL: directory.appendingPathComponent("workbench.json"))
    _ = try persistence.save(ScreenshotDemoDataService().makeSnapshot())
    return WorkbenchStore(persistence: persistence)
  }
}
