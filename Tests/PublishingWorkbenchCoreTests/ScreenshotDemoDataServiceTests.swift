import Darwin
import XCTest

@testable import PublishingWorkbenchCore

#if DEBUG
  final class ScreenshotDemoDataServiceTests: XCTestCase {
    func testScreenshotDemoSnapshotCoversReleaseScreenshotSurfacesWithoutSensitiveValues() throws {
      let snapshot = ScreenshotDemoDataService().makeSnapshot()

      XCTAssertEqual(snapshot.profiles.count, 2)
      XCTAssertTrue(snapshot.profiles.allSatisfy { $0.purpose == .publishing })
      XCTAssertEqual(snapshot.activeProfileID, snapshot.profiles.first?.id)
      XCTAssertTrue(snapshot.drafts.contains { $0.visibility == .private })
      XCTAssertTrue(snapshot.drafts.contains(where: \.isGeneralDraft))
      XCTAssertTrue(
        snapshot.drafts.contains {
          $0.siteProfileID == snapshot.activeProfileID && $0.status == .ready
        })
      XCTAssertTrue(
        snapshot.drafts.contains { draft in
          draft.siteProfileID != snapshot.activeProfileID
            && snapshot.profiles.contains {
              $0.id == draft.siteProfileID && $0.purpose == .publishing
            }
        })

      XCTAssertTrue(snapshot.releaseRecords.contains { $0.kind == .remoteDirectCommit })
      XCTAssertTrue(snapshot.releaseRecords.contains { $0.kind == .remoteReviewRequest })
      XCTAssertTrue(snapshot.releaseRecords.contains { $0.kind == .remotePublishFailure })
      XCTAssertFalse(snapshot.deploymentStatusSnapshots.isEmpty)
      XCTAssertEqual(snapshot.deploymentStatusSnapshots.first?.level, .success)
      XCTAssertFalse(snapshot.seoSocialPreviewSnapshots.isEmpty)
      XCTAssertEqual(
        Set(snapshot.seoSocialPreviewSnapshots.first?.cards.map(\.kind) ?? []),
        Set(SEOSocialPreviewCardKind.allCases))
      XCTAssertTrue(snapshot.repositoryAutoSyncSettings.isEnabled)
      XCTAssertTrue(snapshot.repositoryAutoSyncSettings.fetchBeforeScan)
      XCTAssertTrue(snapshot.deploymentPollingSettings.isEnabled)
      XCTAssertTrue(snapshot.privacySettings.masksPrivateContent)

      let article = try XCTUnwrap(
        snapshot.drafts.first(where: { $0.title == "RepoPress Studio 发布流程" })
      )
      let attachment = try XCTUnwrap(article.attachments.first)
      let sourcePath = try XCTUnwrap(attachment.sourceFilePath)
      let sourceURL = URL(fileURLWithPath: sourcePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      let temporaryRoot = FileManager.default.temporaryDirectory
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
      XCTAssertTrue(sourceURL.path.hasPrefix(temporaryRoot + "/"))
      XCTAssertTrue(FileManager.default.isReadableFile(atPath: sourceURL.path))
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.type]
          as? FileAttributeType,
        .typeRegular
      )
      XCTAssertGreaterThan(try Data(contentsOf: sourceURL).count, 32)
      XCTAssertTrue(
        article.bodyMarkdown.contains(
          "![\(attachment.altText)](\(attachment.relativePublishPath))"
        )
      )
      XCTAssertTrue(article.bodyMarkdown.contains("$$"))
      XCTAssertTrue(article.bodyMarkdown.contains("E = mc^2"))

      let encoded = String(data: try JSONEncoder.workbench.encode(snapshot), encoding: .utf8) ?? ""
      XCTAssertFalse(encoded.contains("/Users/"))
      XCTAssertFalse(encoded.localizedCaseInsensitiveContains("bearer "))
      XCTAssertFalse(encoded.localizedCaseInsensitiveContains("authorization"))
      XCTAssertFalse(encoded.contains("sk-"))
      XCTAssertFalse(encoded.contains("aiChatSessionsByDraftID"))
    }

    func testScreenshotDemoSnapshotKeepsDefaultWritingFixtureCompact() throws {
      unsetenv(ScreenshotDemoDataService.performanceFixtureEnvironmentKey)

      let snapshot = ScreenshotDemoDataService().makeSnapshot()
      let writingDraft = try XCTUnwrap(
        snapshot.drafts.first(where: { $0.title == "RepoPress Studio 发布流程" })
      )

      XCTAssertLessThan(
        writingDraft.bodyMarkdown.utf16.count,
        10_000,
        "普通截图夹具不应被性能夹具放大"
      )
      XCTAssertTrue(
        snapshot.drafts
          .filter { $0.id != writingDraft.id }
          .allSatisfy { $0.bodyMarkdown.utf16.count < 10_000 }
      )
    }

    func testScreenshotDemoSnapshotProvidesIsolatedLargeMarkdownFixture() throws {
      unsetenv(ScreenshotDemoDataService.performanceFixtureLengthEnvironmentKey)
      setenv(
        ScreenshotDemoDataService.performanceFixtureEnvironmentKey,
        "markdown-scroll",
        1
      )
      defer {
        unsetenv(ScreenshotDemoDataService.performanceFixtureEnvironmentKey)
        unsetenv(ScreenshotDemoDataService.performanceFixtureLengthEnvironmentKey)
      }

      let snapshot = ScreenshotDemoDataService().makeSnapshot()
      let writingDraft = try XCTUnwrap(
        snapshot.drafts.first(where: { $0.slug == "markdown-scroll-performance-fixture" })
      )

      XCTAssertGreaterThanOrEqual(writingDraft.bodyMarkdown.utf16.count, 100_000)
      XCTAssertTrue(writingDraft.bodyMarkdown.contains("# Markdown viewport performance fixture"))
      XCTAssertTrue(writingDraft.bodyMarkdown.contains("https://example.invalid/performance"))
      XCTAssertTrue(writingDraft.bodyMarkdown.contains("offscreen attribute writes bounded"))
      XCTAssertTrue(
        snapshot.drafts
          .filter { $0.id != writingDraft.id }
          .allSatisfy { $0.bodyMarkdown.utf16.count < 10_000 },
        "性能夹具只能放大目标写作草稿"
      )

      let encoded =
        String(
          data: try JSONEncoder.workbench.encode(snapshot),
          encoding: .utf8
        ) ?? ""
      XCTAssertFalse(encoded.contains("/Users/"))
      XCTAssertFalse(encoded.localizedCaseInsensitiveContains("bearer "))
      XCTAssertFalse(encoded.localizedCaseInsensitiveContains("authorization"))
      XCTAssertFalse(encoded.contains("sk-"))
    }

    func testScreenshotDemoSnapshotProvidesIsolatedRichAttachmentFixture() throws {
      unsetenv(ScreenshotDemoDataService.performanceFixtureLengthEnvironmentKey)
      setenv(
        ScreenshotDemoDataService.performanceFixtureEnvironmentKey,
        "markdown-rich-scroll",
        1
      )
      defer {
        unsetenv(ScreenshotDemoDataService.performanceFixtureEnvironmentKey)
        unsetenv(ScreenshotDemoDataService.performanceFixtureLengthEnvironmentKey)
      }

      let snapshot = ScreenshotDemoDataService().makeSnapshot()
      let richDraft = try XCTUnwrap(
        snapshot.drafts.first(where: { $0.slug == "markdown-rich-scroll-performance-fixture" })
      )
      let attachment = try XCTUnwrap(richDraft.attachments.first)
      let sourcePath = try XCTUnwrap(attachment.sourceFilePath)
      let sourceURL = URL(fileURLWithPath: sourcePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      let temporaryRoot = FileManager.default.temporaryDirectory
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path

      XCTAssertGreaterThanOrEqual(richDraft.bodyMarkdown.utf16.count, 100_000)
      XCTAssertEqual(richDraft.attachments.count, 1)
      XCTAssertTrue(sourceURL.path.hasPrefix(temporaryRoot + "/"))
      XCTAssertTrue(FileManager.default.isReadableFile(atPath: sourceURL.path))
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.type]
          as? FileAttributeType,
        .typeRegular
      )
      XCTAssertGreaterThan(try Data(contentsOf: sourceURL).count, 32)

      let imageMarkdown = "![Repeated safe demo attachment](\(attachment.relativePublishPath))"
      XCTAssertGreaterThanOrEqual(
        richDraft.bodyMarkdown.components(separatedBy: imageMarkdown).count - 1,
        4
      )
      XCTAssertTrue(richDraft.bodyMarkdown.contains("$x_i + y_i = z_i$"))
      XCTAssertTrue(richDraft.bodyMarkdown.contains("$\\alpha + \\beta = \\gamma$"))
      XCTAssertGreaterThanOrEqual(richDraft.bodyMarkdown.components(separatedBy: "$$").count - 1, 4)

      XCTAssertTrue(
        snapshot.drafts
          .filter { $0.id != richDraft.id }
          .allSatisfy { $0.bodyMarkdown.utf16.count < 10_000 },
        "富附件性能夹具只能放大目标写作草稿"
      )

      let encoded =
        String(
          data: try JSONEncoder.workbench.encode(snapshot),
          encoding: .utf8
        ) ?? ""
      XCTAssertFalse(encoded.contains("/Users/"))
      XCTAssertFalse(encoded.localizedCaseInsensitiveContains("bearer "))
      XCTAssertFalse(encoded.localizedCaseInsensitiveContains("authorization"))
      XCTAssertFalse(encoded.contains("sk-"))
    }

    func testScreenshotDemoSnapshotSupportsOneThousandCharacterComparisonFixture() throws {
      setenv(
        ScreenshotDemoDataService.performanceFixtureEnvironmentKey,
        "markdown-scroll",
        1
      )
      setenv(
        ScreenshotDemoDataService.performanceFixtureLengthEnvironmentKey,
        "1000",
        1
      )
      defer {
        unsetenv(ScreenshotDemoDataService.performanceFixtureEnvironmentKey)
        unsetenv(ScreenshotDemoDataService.performanceFixtureLengthEnvironmentKey)
      }

      let snapshot = ScreenshotDemoDataService().makeSnapshot()
      let writingDraft = try XCTUnwrap(
        snapshot.drafts.first(where: { $0.slug == "markdown-scroll-performance-fixture" })
      )

      XCTAssertGreaterThanOrEqual(writingDraft.bodyMarkdown.utf16.count, 1_000)
      XCTAssertLessThan(writingDraft.bodyMarkdown.utf16.count, 10_000)
    }

    func testScreenshotDemoSurfaceMapsRequiredScreenshotIDs() {
      let requiredIDs: Set<String> = [
        "writing",
        "ai-chat",
        "sync-api-publish",
        "seo-social-preview",
        "deployment-status",
        "maintenance",
        "settings",
        "general-drafts",
        "knowledge-library",
        "privacy-lock",
      ]

      XCTAssertEqual(Set(ScreenshotDemoSurface.allCases.map(\.rawValue)), requiredIDs)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "ai-chat"), .aiChat)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "sync-api-publish"), .syncAPIPublish)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "deployment-status"), .deploymentStatus)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "general-drafts"), .generalDrafts)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "knowledge-library"), .knowledgeLibrary)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "privacy-lock"), .quickHide)
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

    func testPerformanceFixtureDoesNotRequireScreenshotDemoEnvironment() {
      unsetenv(ScreenshotDemoDataService.environmentKey)
      unsetenv(ScreenshotDemoDataService.surfaceEnvironmentKey)
      setenv(ScreenshotDemoDataService.performanceFixtureEnvironmentKey, "markdown-scroll", 1)
      defer {
        unsetenv(ScreenshotDemoDataService.performanceFixtureEnvironmentKey)
      }

      XCTAssertTrue(ScreenshotDemoDataService.isEnabledFromEnvironment)
      XCTAssertNil(ScreenshotDemoDataService.requestedSurfaceFromEnvironment)
    }

    @MainActor
    func testScreenshotDemoSnapshotCanSeedWorkbenchStoreFromIsolatedPersistence() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "PersonalSitePublisherMacScreenshotDemoTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer {
        try? FileManager.default.removeItem(at: directory)
      }
      let persistence = WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json"))
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
    }

    func testScreenshotUITestPreparationClearsStaleDraftRecovery() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "PersonalSitePublisherMacScreenshotRecoveryTests-\(UUID().uuidString)",
          isDirectory: true
        )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer {
        try? FileManager.default.removeItem(at: directory)
      }
      let persistence = WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json"))
      let journal = DraftRecoveryJournal(fileURL: persistence.draftRecoveryJournalURL)
      let draft = ScreenshotDemoDataService().makeSnapshot().drafts[0]
      try journal.save([
        DraftRecoveryRecord(draft: draft, recoveredBodyMarkdown: "UI 测试上次退出时的正文")
      ])

      try ScreenshotDemoDataService.preparePersistence(
        persistence,
        resetsDraftRecovery: true
      )

      XCTAssertEqual(try journal.load(), [])
    }

    func testScreenshotPreparationPreservesDraftRecoveryOutsideUITests() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "PersonalSitePublisherMacScreenshotRecoveryTests-\(UUID().uuidString)",
          isDirectory: true
        )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer {
        try? FileManager.default.removeItem(at: directory)
      }
      let persistence = WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json"))
      let journal = DraftRecoveryJournal(fileURL: persistence.draftRecoveryJournalURL)
      let draft = ScreenshotDemoDataService().makeSnapshot().drafts[0]
      try journal.save([
        DraftRecoveryRecord(draft: draft, recoveredBodyMarkdown: "用户未保存的正文")
      ])

      try ScreenshotDemoDataService.preparePersistence(
        persistence,
        resetsDraftRecovery: false
      )

      XCTAssertEqual(try journal.load().map(\.recoveredBodyMarkdown), ["用户未保存的正文"])
    }

    @MainActor
    func testScreenshotUITestPreparationSeedsOfflineRSSWorkspace() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "PersonalSitePublisherMacScreenshotRSSTests-\(UUID().uuidString)",
          isDirectory: true
        )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer {
        unsetenv(ScreenshotDemoDataService.environmentKey)
        unsetenv(ScreenshotDemoDataService.uiTestEnvironmentKey)
        try? FileManager.default.removeItem(at: directory)
      }
      setenv(ScreenshotDemoDataService.environmentKey, "1", 1)
      setenv(ScreenshotDemoDataService.uiTestEnvironmentKey, "1", 1)
      let store = RSSReaderStore(
        fileURL: directory.appendingPathComponent("reader.sqlite"))

      ScreenshotDemoDataService.prepareRSSReaderFixtureIfEnabled(in: store)

      XCTAssertEqual(store.feeds.map(\.displayTitle), ["RepoPress 演示订阅"])
      XCTAssertEqual(store.articleHeaders.map(\.title), ["RepoPress Studio 发布工作流"])
      XCTAssertEqual(store.articleHeaderCount, 1)
      XCTAssertNil(store.lastError)
    }

    @MainActor
    func testScreenshotDemoSurfacesPrepareStoreForTargetWorkspaces() throws {
      let store = try makeScreenshotStore()

      ScreenshotDemoSurface.aiChat.apply(to: store)
      XCTAssertEqual(store.selectedSection, .writing)
      XCTAssertTrue(store.isAIPublishingAssistantPresented)
      XCTAssertFalse(store.aiChatMessages.isEmpty)
      XCTAssertFalse(store.isQuickHideActive)

      ScreenshotDemoSurface.deploymentStatus.apply(to: store)
      XCTAssertEqual(store.selectedSection, .sync)
      XCTAssertEqual(store.activeProfileDeploymentStatusSnapshots.count, 1)
      XCTAssertEqual(store.deploymentStatusMessage, "截图模式：部署状态和轮询记录已载入。")

      ScreenshotDemoSurface.maintenance.apply(to: store)
      XCTAssertEqual(store.selectedSection, .contentHealth)

      ScreenshotDemoSurface.seoSocialPreview.apply(to: store)
      XCTAssertEqual(store.selectedSection, .writing)
      XCTAssertTrue(store.isInspectorPresented)
      XCTAssertEqual(store.seoSocialPreviewSnapshots.count, 1)

      ScreenshotDemoSurface.generalDrafts.apply(to: store)
      XCTAssertEqual(store.selectedSection, .writing)
      XCTAssertEqual(store.draftListContentScope, .general)
      XCTAssertEqual(store.publishActionMessage, "截图模式：通用草稿已载入。")

      ScreenshotDemoSurface.quickHide.apply(to: store)
      XCTAssertEqual(store.selectedSection, .writing)
      XCTAssertTrue(store.isQuickHideActive)
      XCTAssertTrue(store.quickHideReason?.contains("私密内容已遮挡") == true)
    }

    @MainActor
    func testSyncAPIPublishUITestFixtureKeepsPublishActionDeterministic() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "PersonalSitePublisherMacSyncPublishUITest-\(UUID().uuidString)",
          isDirectory: true
        )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer {
        unsetenv(ScreenshotDemoDataService.environmentKey)
        unsetenv(ScreenshotDemoDataService.surfaceEnvironmentKey)
        unsetenv(ScreenshotDemoDataService.uiTestEnvironmentKey)
        unsetenv(ScreenshotDemoDataService.uiTestRepositoryRootEnvironmentKey)
        try? FileManager.default.removeItem(at: directory)
      }
      setenv(ScreenshotDemoDataService.environmentKey, "1", 1)
      setenv(ScreenshotDemoDataService.surfaceEnvironmentKey, "sync-api-publish", 1)
      setenv(ScreenshotDemoDataService.uiTestEnvironmentKey, "1", 1)
      setenv(
        ScreenshotDemoDataService.uiTestRepositoryRootEnvironmentKey,
        directory.path,
        1
      )

      let store = try makeScreenshotStore()
      ScreenshotDemoDataService.applyRequestedSurfaceIfEnabled(to: store)
      await Task.yield()

      XCTAssertEqual(store.selectedSection, .sync)
      XCTAssertFalse(store.repositoryScanState.isScanning)
      XCTAssertEqual(store.repositoryReport?.rootPath, directory.path)
      XCTAssertEqual(store.repositoryReport?.preflightIssues, [])
      XCTAssertEqual(store.localPublishReadiness?.blockingIssueCount, 0)
      XCTAssertNotNil(store.remotePublishPreviewSnapshot)
    }

    @MainActor
    private func makeScreenshotStore() throws -> WorkbenchStore {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "PersonalSitePublisherMacScreenshotDemoTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let persistence = WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json"))
      _ = try persistence.save(ScreenshotDemoDataService().makeSnapshot())
      return WorkbenchStore(persistence: persistence)
    }
  }
#endif
