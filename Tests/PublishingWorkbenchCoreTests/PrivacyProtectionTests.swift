import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class PrivacyProtectionTests: XCTestCase {
  func testLegacySnapshotDecodesWithDefaultPrivacySettings() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Legacy", slug: "legacy")
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [draft],
        releaseRecords: [],
        privacySettings: PrivacyProtectionSettings(masksPrivateContent: false)
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "privacySettings")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertTrue(snapshot.privacySettings.masksPrivateContent)
  }

  func testLegacyAutomaticLockSettingsAreIgnored() throws {
    let url = try temporaryPersistenceURL()
    let profile = SiteProfile.defaultProfile
    let encoded = try JSONEncoder.workbench.encode(WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft(siteProfileID: profile.id, title: "Private", slug: "private")],
      releaseRecords: [],
      privacySettings: PrivacyProtectionSettings(masksPrivateContent: true)
    ))
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var privacySettings = try XCTUnwrap(object["privacySettings"] as? [String: Any])
    privacySettings["requiresUnlockOnLaunch"] = true
    privacySettings["locksWhenInactive"] = true
    object["privacySettings"] = privacySettings
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    try legacyData.write(to: url, options: .atomic)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    XCTAssertFalse(store.isPrivacyLocked)
    XCTAssertTrue(store.privacySettings.masksPrivateContent)
  }

  func testManualQuickHideAndReturnToWorkbench() throws {
    let url = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    XCTAssertFalse(store.isPrivacyLocked)
    store.lockPrivacy(reason: "Manual review")
    XCTAssertTrue(store.isPrivacyLocked)
    store.unlockPrivacy()
    XCTAssertFalse(store.isPrivacyLocked)
  }

  func testPrivacyProtectionEventsAreNotPersisted() async throws {
    let url = try temporaryPersistenceURL()
    let persistence = WorkbenchPersistence(fileURL: url)
    let profile = SiteProfile.defaultProfile
    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [ArticleDraft(siteProfileID: profile.id, title: "Private", slug: "private")],
        releaseRecords: [],
        privacyProtectionEvents: [PrivacyProtectionEvent(kind: .manualLock, message: "Legacy")]
      )
    )
    let store = WorkbenchStore(persistence: persistence)
    store.lockPrivacy(reason: "Manual review")
    store.unlockPrivacy()
    await store.waitForPendingSave()

    let snapshot = try XCTUnwrap(try persistence.load())
    XCTAssertTrue(snapshot.privacyProtectionEvents.isEmpty)
  }

  func testLegacySnapshotDecodesWithEmptyPrivacyProtectionEvents() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(siteProfileID: profile.id, title: "Legacy", slug: "legacy")
    let encoded = try JSONEncoder.workbench.encode(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [draft],
        releaseRecords: [],
        privacyProtectionEvents: [
          PrivacyProtectionEvent(kind: .manualLock, message: "Manual")
        ]
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "privacyProtectionEvents")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertTrue(snapshot.privacyProtectionEvents.isEmpty)
  }

  func testProtectedWorkbenchAvailabilityFollowsPrivacyLockState() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.setAIPublishingAssistantPresented(true)

    XCTAssertTrue(store.canUseProtectedWorkbench)

    store.lockPrivacy(reason: "Manual")
    XCTAssertTrue(store.isPrivacyLocked)
    XCTAssertFalse(store.canUseProtectedWorkbench)
    XCTAssertFalse(store.isAIPublishingAssistantPresented)
    XCTAssertEqual(store.privacyProtectionStatus.title, "工作台内容已隐藏")
    XCTAssertEqual(store.privacyProtectionStatus.detail, "Manual")

    store.unlockPrivacy()
    XCTAssertFalse(store.isPrivacyLocked)
    XCTAssertTrue(store.canUseProtectedWorkbench)
    XCTAssertEqual(store.privacyProtectionStatus.title, "工作台内容可见")
  }

  func testPrivacyLockBlocksRemotePublishingBeforeQuotaOrAPIUse() async throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.lockPrivacy(reason: "Manual")

    let selectedResult = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let batchResult = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()
    let accessCheck = await store.checkRepositoryTokenAccess()
    let creationResult = await store.createGitHubRepositoryForActiveProfile()

    XCTAssertNil(selectedResult)
    XCTAssertNil(batchResult)
    XCTAssertNil(accessCheck)
    XCTAssertNil(creationResult)
    XCTAssertEqual(store.publishActionMessage, "工作台内容已隐藏，请返回工作台后再继续。")
    XCTAssertEqual(store.monetizationState.freeUsage.onlinePublishAttemptCount, 0)
    XCTAssertEqual(store.monetizationState.freeUsage.batchPublishCount, 0)
    XCTAssertFalse(store.isRemoteRepositoryPublishing)
    XCTAssertFalse(store.isRemoteRepositoryChecking)
  }

  func testPrivacyLockBlocksAIRequestsBeforeQuotaOrConversationChanges() async throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let draft = try XCTUnwrap(store.selectedDraft)
    store.lockPrivacy(reason: "Manual")

    let action = await store.performAIAction(.privacyReview, draft: draft)
    let metadataSuggestion = await store.generateAIMetadataSuggestions(draft: draft)
    let chatReply = await store.sendAIChatMessage("检查标题", draft: draft)
    let imageSuggestions = await store.generateAIImageTextSuggestions(draft: draft)

    XCTAssertNil(action)
    XCTAssertNil(metadataSuggestion)
    XCTAssertNil(chatReply)
    XCTAssertTrue(imageSuggestions.isEmpty)
    XCTAssertEqual(store.monetizationState.freeUsage.aiRequestCount, 0)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertFalse(store.isAIActionRunning)
    XCTAssertFalse(store.isAIMetadataSuggestionRunning)
    XCTAssertFalse(store.isAIChatRunning)
    XCTAssertFalse(store.isAIImageTextRunning)
    XCTAssertEqual(store.aiActionMessage, "工作台内容已隐藏，请返回工作台后再继续。")
    XCTAssertEqual(store.aiChatMessage, "工作台内容已隐藏，请返回工作台后再继续。")
    XCTAssertEqual(store.imageActionMessage, "工作台内容已隐藏，请返回工作台后再继续。")
  }

  func testPrivacyProtectionStatusSummarizesEnabledProtections() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: true
      )
    )

    let status = store.privacyProtectionStatus

    XCTAssertFalse(status.isLocked)
    XCTAssertEqual(status.activeProtections, ["私密内容遮挡"])
    XCTAssertTrue(status.detail.contains("手动快速隐藏"))
  }

  func testPrivacyProtectionStatusChecklistSummarizesReviewableBehavior() throws {
    let status = PrivacyProtectionStatus.make(
      settings: PrivacyProtectionSettings(
        masksPrivateContent: true
      ),
      isLocked: true,
      reason: "已手动快速隐藏。"
    )

    let markdown = status.checklistMarkdown

    XCTAssertTrue(markdown.contains("# 快速隐藏和私密内容保护"))
    XCTAssertTrue(markdown.contains("- 当前状态：工作台内容已隐藏"))
    XCTAssertTrue(markdown.contains("私密内容遮挡"))
    XCTAssertTrue(markdown.contains("手动快速隐藏后"))
    XCTAssertTrue(markdown.contains("写作、AI、同步和发布操作不可用"))
    XCTAssertTrue(markdown.contains("主窗口和设置窗口都遮挡工作台内容"))
    XCTAssertTrue(markdown.contains("标题仍可辨认"))
    XCTAssertTrue(markdown.contains("不暴露摘要、正文或路径"))
    XCTAssertTrue(markdown.contains("不得包含本地路径、Token、授权头或私密正文"))
  }


  func testPrivateContentDisplayMasksOnlyPrivateDraftsWhenEnabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var settings = store.privacySettings
    settings.masksPrivateContent = true
    store.updatePrivacySettings(settings)

    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Secret Plan",
      slug: "secret",
      visibility: .private,
      summary: "Hidden details"
    )
    let publicDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Public Plan",
      slug: "public",
      summary: "Visible details"
    )

    let privateDisplay = store.privateContentDisplay(for: privateDraft)
    let publicDisplay = store.privateContentDisplay(for: publicDraft)

    XCTAssertTrue(privateDisplay.isMasked)
    XCTAssertEqual(privateDisplay.title, "Secret Plan")
    XCTAssertFalse(privateDisplay.summary.contains("Hidden"))
    XCTAssertFalse(publicDisplay.isMasked)
    XCTAssertEqual(publicDisplay.title, "Public Plan")
  }

  func testPrivacyProtectedDraftSearchMatchesTitleButNotHiddenPrivateMetadata() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: true
      )
    )
    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Secret Migration Plan",
      slug: "secret-migration",
      tags: ["internal"],
      visibility: .private,
      summary: "Hidden token rotation notes"
    )

    XCTAssertTrue(
      store.matchesPrivacyProtectedDraftSearch(
        privateDraft,
        query: "Migration",
        profile: store.activeProfile
      )
    )
    XCTAssertFalse(
      store.matchesPrivacyProtectedDraftSearch(
        privateDraft,
        query: "secret-migration",
        profile: store.activeProfile
      )
    )
    XCTAssertTrue(
      store.matchesPrivacyProtectedDraftSearch(
        privateDraft,
        query: "私密",
        profile: store.activeProfile
      )
    )

    let protectedSearchDraft = store.privacyProtectedSearchDraft(for: privateDraft)
    let titleHits = DraftFullTextSearchService().search(
      query: "title:Migration is:private",
      drafts: [protectedSearchDraft]
    )
    let hiddenMetadataHits = DraftFullTextSearchService().search(
      query: "rotation",
      drafts: [protectedSearchDraft]
    )
    XCTAssertEqual(titleHits.first?.draftTitle, "Secret Migration Plan")
    XCTAssertTrue(hiddenMetadataHits.isEmpty)
  }

  func testPrivacyProtectedDraftSearchUsesRawMetadataWhenMaskingDisabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: false
      )
    )
    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Secret Migration Plan",
      slug: "secret-migration",
      tags: ["internal"],
      visibility: .private,
      summary: "Hidden token rotation notes"
    )

    XCTAssertTrue(
      store.matchesPrivacyProtectedDraftSearch(
        privateDraft,
        query: "Migration",
        profile: store.activeProfile
      )
    )
    XCTAssertTrue(
      store.matchesPrivacyProtectedDraftSearch(
        privateDraft,
        query: "secret-migration",
        profile: store.activeProfile
      )
    )
  }

  func testContentHealthSummariesShowPrivateDraftTitleButMaskPathWhenEnabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: true
      )
    )
    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Secret Launch Plan",
      slug: "secret-launch-plan",
      visibility: .private,
      summary: "Hidden launch notes",
      bodyMarkdown: "Private body"
    )
    store.setDrafts([privateDraft])

    let summary = try XCTUnwrap(store.contentHealthSummaries.first)

    XCTAssertEqual(summary.draftTitle, "Secret Launch Plan")
    XCTAssertEqual(summary.markdownPath, "内容已遮挡，打开文章或关闭私密遮挡后查看。")
    XCTAssertTrue(summary.draftTitle.contains("Secret"))
    XCTAssertFalse(summary.markdownPath.contains("secret-launch-plan"))
  }

  func testContentHealthSummariesUseRawPrivateDraftMetadataWhenMaskingDisabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: false
      )
    )
    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Secret Launch Plan",
      slug: "secret-launch-plan",
      visibility: .private,
      summary: "Hidden launch notes",
      bodyMarkdown: "Private body"
    )
    store.setDrafts([privateDraft])

    let summary = try XCTUnwrap(store.contentHealthSummaries.first)

    XCTAssertEqual(summary.draftTitle, "Secret Launch Plan")
    XCTAssertTrue(summary.markdownPath.contains("secret-launch-plan"))
  }

  func testSEOSocialPublishPackageMasksPrivateDraftWhenProtectionEnabled() async throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: true
      )
    )
    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Secret Launch Plan",
      slug: "secret-launch-plan",
      visibility: .private,
      summary: "Hidden launch notes",
      bodyMarkdown: "Private body"
    )
    store.setDrafts([privateDraft])
    store.prepareSEOSocialPreview(for: privateDraft)

    let generatedMarkdown = await store.seoSocialPublishPackageMarkdown(for: privateDraft)
    let markdown = try XCTUnwrap(generatedMarkdown)

    XCTAssertTrue(markdown.contains("# SEO / Social 发布包已遮挡"))
    XCTAssertTrue(markdown.contains("- 文章：私密文章"))
    XCTAssertTrue(markdown.contains("私密内容遮挡已开启"))
    XCTAssertFalse(markdown.contains("Secret Launch Plan"))
    XCTAssertFalse(markdown.contains("secret-launch-plan"))
    XCTAssertFalse(markdown.contains("Hidden launch notes"))
    XCTAssertFalse(markdown.contains("Private body"))
  }

  func testCrossSiteCopyListShowsPrivateDraftTitlesWhenProtectionEnabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: true
      )
    )
    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Secret Cross Site Plan",
      slug: "secret-cross-site-plan",
      tags: ["internal"],
      categories: ["Private"],
      visibility: .private,
      summary: "Hidden cross-site notes",
      bodyMarkdown: "Private reusable body",
      attachments: [
        DraftAttachment(
          originalFilename: "secret-diagram.png",
          relativePublishPath: "/private/secret-diagram.png",
          repositoryPath: "static/private/secret-diagram.png",
          altText: "Secret alt",
          caption: "Secret caption",
          byteSize: 2048
        )
      ]
    )
    store.setDrafts([privateDraft])

    let report = store.generalDraftLibraryReport
    let item = try XCTUnwrap(report.items.first)
    XCTAssertEqual(item.title, "Secret Cross Site Plan")
  }

  func testCrossSiteCopyListUsesPrivateDraftTitleWhenMaskingDisabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: false
      )
    )
    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Secret Cross Site Plan",
      slug: "secret-cross-site-plan",
      tags: ["internal"],
      visibility: .private,
      summary: "Hidden cross-site notes",
      attachments: [
        DraftAttachment(
          originalFilename: "secret-diagram.png",
          relativePublishPath: "/private/secret-diagram.png",
          repositoryPath: "static/private/secret-diagram.png",
          byteSize: 2048
        )
      ]
    )
    store.setDrafts([privateDraft])

    let report = store.generalDraftLibraryReport

    XCTAssertEqual(report.items.first?.title, "Secret Cross Site Plan")
  }



  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PrivacyProtectionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }
}
