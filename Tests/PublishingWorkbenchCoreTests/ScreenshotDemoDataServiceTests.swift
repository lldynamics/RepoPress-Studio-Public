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
      let ledger = ReleaseLedgerService().ledger(
        releaseRecords: snapshot.releaseRecords,
        deploymentStatusSnapshots: Dictionary(
          uniqueKeysWithValues: snapshot.deploymentStatusSnapshots.compactMap { status in
            status.releaseRecordID.map { ($0, status) }
          }
        )
      )
      let checkedRecordID = try XCTUnwrap(snapshot.deploymentStatusSnapshots.first?.releaseRecordID)
      XCTAssertEqual(ledger.entries.first { $0.id == checkedRecordID }?.status, .succeeded)
      XCTAssertFalse(
        ledger.actionItems.contains {
          $0.recordID == checkedRecordID && $0.kind == .observeDeployment
        })
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
      ]

      XCTAssertEqual(Set(ScreenshotDemoSurface.allCases.map(\.rawValue)), requiredIDs)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "ai-chat"), .aiChat)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "sync-api-publish"), .syncAPIPublish)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "deployment-status"), .deploymentStatus)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "general-drafts"), .generalDrafts)
      XCTAssertEqual(ScreenshotDemoSurface(rawValue: "knowledge-library"), .knowledgeLibrary)
      XCTAssertNil(ScreenshotDemoSurface(rawValue: "privacy-lock"))
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

    func testScreenshotUITestPreparationReseedsAnUnreadableSharedFixture() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "PersonalSitePublisherMacScreenshotStaleFixtureTests-\(UUID().uuidString)",
          isDirectory: true
        )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer {
        try? FileManager.default.removeItem(at: directory)
      }
      let persistence = WorkbenchPersistence(
        fileURL: directory.appendingPathComponent(ScreenshotDemoDataService.persistenceFilename))
      _ = try persistence.save(ScreenshotDemoDataService().makeSnapshot())
      // Reproduce the state an interrupted run left in the shared system-temp
      // fixture: no primary marker, and a recovery store missing a document.
      try FileManager.default.removeItem(at: persistence.fileURL)
      let storeDirectory = try XCTUnwrap(
        FileManager.default.contentsOfDirectory(
          at: persistence.recordStoreDirectoryURL, includingPropertiesForKeys: nil
        ).first)
      let recoveryDocument = try XCTUnwrap(
        FileManager.default.contentsOfDirectory(
          at: storeDirectory.appendingPathComponent("RecoveryDocuments"),
          includingPropertiesForKeys: nil
        ).first)
      try FileManager.default.removeItem(at: recoveryDocument)
      XCTAssertThrowsError(
        try WorkbenchPersistence(fileURL: persistence.fileURL).loadWithRecovery())

      XCTAssertThrowsError(
        try ScreenshotDemoDataService.preparePersistence(
          WorkbenchPersistence(fileURL: persistence.fileURL),
          resetsDraftRecovery: false
        ),
        "Outside UI tests an unreadable workbench must be preserved for recovery."
      )
      try ScreenshotDemoDataService.preparePersistence(
        WorkbenchPersistence(fileURL: persistence.fileURL),
        resetsDraftRecovery: true,
        discardsUnreadableFixture: true
      )

      let reloaded = try WorkbenchPersistence(fileURL: persistence.fileURL).loadWithRecovery()
      XCTAssertNil(reloaded.recoveryMessage)
      XCTAssertTrue(
        reloaded.snapshot?.drafts.contains { $0.title == "RepoPress Studio 发布流程" } == true)
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
      XCTAssertEqual(store.publishActionMessage, "截图模式：仅本地草稿已载入。")

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
    func testRepositoryFixturePreservesMetadataThroughRealWritesAndRejectsExternalChanges() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "ScreenshotRepositoryWriteTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let key = ScreenshotDemoDataService.uiTestRepositoryRootEnvironmentKey
      let previousRoot = ProcessInfo.processInfo.environment[key]
      setenv(key, directory.appendingPathComponent("repository").path, 1)
      defer {
        if let previousRoot { setenv(key, previousRoot, 1) } else { unsetenv(key) }
        try? FileManager.default.removeItem(at: directory)
      }
      let persistence = WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workbench.json"))
      _ = try persistence.save(ScreenshotDemoDataService().makeSnapshot())
      let store = WorkbenchStore(persistence: persistence)
      ScreenshotDemoDataService.prepareRepositoryFixture(in: store, isUITest: true)
      let profile = store.activeProfile
      let root = try XCTUnwrap(profile.localRepositoryRootURL)
      var draft = try XCTUnwrap(store.drafts.first { $0.title == "RepoPress Studio 发布流程" })
      let originalPath = try XCTUnwrap(draft.repositoryPath)
      let originalURL = root.appendingPathComponent(originalPath)
      let original = try String(contentsOf: originalURL, encoding: .utf8)
      let renderer = FrontMatterRenderer()
      XCTAssertEqual(originalPath, profile.markdownPath(for: draft))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
      XCTAssertNotNil(draft.importedFrontMatter)
      XCTAssertNil(renderer.preservationIssue(draft: draft, profile: profile))
      XCTAssertEqual(original, renderer.renderDocument(draft: draft, profile: profile))
      XCTAssertEqual(
        draft.repositoryBinding?.projectFileContentDigest,
        ArticleDraft.repositoryDocumentDigest(original))
      XCTAssertEqual(
        draft.repositoryBinding?.projectFileRenderedContentDigest,
        draft.renderedRepositoryContentDigest(profile: profile))
      let originalTags = draft.tags
      let originalCategories = draft.categories
      let writer = SiteDraftFileStore()
      draft.bodyMarkdown += "\n\nSaved fixture body."
      draft.slug = "edited-fixture-slug"
      let result = try writer.write(draft: draft, profile: profile)
      let destination = root.appendingPathComponent(result.repositoryPath)
      let saved = try String(contentsOf: destination, encoding: .utf8)
      XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
      let imported = try LocalContentImportService().parseProjectDocument(
        saved, repositoryPath: result.repositoryPath, rootURL: root, profile: profile)
      XCTAssertEqual(imported.slug, draft.slug)
      XCTAssertEqual(imported.tags, originalTags)
      XCTAssertEqual(imported.categories, originalCategories)
      XCTAssertTrue(imported.bodyMarkdown.contains("Saved fixture body."))
      XCTAssertTrue(saved.contains("/images/2026/social-preview.png"))
      let external = saved + "\nExternal edit must survive.\n"
      try external.write(to: destination, atomically: true, encoding: .utf8)
      draft = imported
      draft.bodyMarkdown += "\nA concurrent app edit."
      XCTAssertThrowsError(try writer.write(draft: draft, profile: profile)) { error in
        guard case .projectFileChangedExternally = error as? SiteDraftFileStoreError else {
          return XCTFail("Expected external-change protection, got \(error)")
        }
      }
      XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), external)
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
