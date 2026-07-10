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
        privacySettings: PrivacyProtectionSettings(
          requiresUnlockOnLaunch: true,
          locksWhenInactive: false,
          masksPrivateContent: false
        )
      )
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "privacySettings")
    let json = try JSONSerialization.data(withJSONObject: object)

    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: json)

    XCTAssertFalse(snapshot.privacySettings.requiresUnlockOnLaunch)
    XCTAssertFalse(snapshot.privacySettings.locksWhenInactive)
    XCTAssertTrue(snapshot.privacySettings.masksPrivateContent)
  }

  func testStoreLocksOnLaunchAndInactiveWhenConfigured() throws {
    let url = try temporaryPersistenceURL()
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft(siteProfileID: profile.id, title: "Private", slug: "private")],
      releaseRecords: [],
      privacySettings: PrivacyProtectionSettings(
        requiresUnlockOnLaunch: true,
        locksWhenInactive: true,
        masksPrivateContent: true
      )
    )
    try WorkbenchPersistence(fileURL: url).save(snapshot)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    XCTAssertTrue(store.isPrivacyLocked)
    store.unlockPrivacy()
    XCTAssertFalse(store.isPrivacyLocked)
    store.lockPrivacyIfNeededForInactiveScene()
    XCTAssertTrue(store.isPrivacyLocked)
  }

  func testInactiveSceneDoesNotLockWhenSettingIsDisabled() throws {
    let url = try temporaryPersistenceURL()
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft(siteProfileID: profile.id, title: "Public", slug: "public")],
      releaseRecords: [],
      privacySettings: PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: false,
        masksPrivateContent: true
      )
    )
    try WorkbenchPersistence(fileURL: url).save(snapshot)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    XCTAssertFalse(store.isPrivacyLocked)
    store.lockPrivacyIfNeededForInactiveScene()
    XCTAssertFalse(store.isPrivacyLocked)
  }

  func testPrivacyProtectionEventsRecordLaunchInactiveManualUnlockAndSettings() throws {
    let url = try temporaryPersistenceURL()
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft(siteProfileID: profile.id, title: "Private", slug: "private")],
      releaseRecords: [],
      privacySettings: PrivacyProtectionSettings(
        requiresUnlockOnLaunch: true,
        locksWhenInactive: true,
        masksPrivateContent: true
      )
    )
    try WorkbenchPersistence(fileURL: url).save(snapshot)

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    XCTAssertEqual(store.privacyProtectionEvents.first?.kind, .lockedOnLaunch)
    store.unlockPrivacy()
    XCTAssertEqual(store.privacyProtectionEvents.first?.kind, .unlocked)
    store.lockPrivacyIfNeededForInactiveScene()
    XCTAssertEqual(store.privacyProtectionEvents.first?.kind, .lockedWhenInactive)
    store.unlockPrivacy()
    store.lockPrivacy(reason: "Manual review")
    XCTAssertEqual(store.privacyProtectionEvents.first?.kind, .manualLock)
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: true,
        locksWhenInactive: false,
        masksPrivateContent: true
      )
    )
    XCTAssertEqual(store.privacyProtectionEvents.first?.kind, .settingsUpdated)
  }

  func testPrivacyProtectionEventsPersistAcrossReloads() throws {
    let url = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    store.lockPrivacy(reason: "Manual review")
    store.unlockPrivacy()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))

    XCTAssertTrue(reloaded.privacyProtectionEvents.contains { $0.kind == .manualLock })
    XCTAssertTrue(reloaded.privacyProtectionEvents.contains { $0.kind == .unlocked })
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
    XCTAssertEqual(store.privacyProtectionStatus.title, "工作台已锁定")
    XCTAssertEqual(store.privacyProtectionStatus.detail, "Manual")

    store.unlockPrivacy()
    XCTAssertFalse(store.isPrivacyLocked)
    XCTAssertTrue(store.canUseProtectedWorkbench)
    XCTAssertEqual(store.privacyProtectionStatus.title, "工作台未锁定")
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
    XCTAssertEqual(store.publishActionMessage, "工作台已锁定，请先解锁后再继续。")
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
    XCTAssertEqual(store.aiActionMessage, "工作台已锁定，请先解锁后再继续。")
    XCTAssertEqual(store.aiChatMessage, "工作台已锁定，请先解锁后再继续。")
    XCTAssertEqual(store.imageActionMessage, "工作台已锁定，请先解锁后再继续。")
  }

  func testPrivacyProtectionStatusSummarizesEnabledProtections() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: true,
        locksWhenInactive: false,
        masksPrivateContent: true
      )
    )

    let status = store.privacyProtectionStatus

    XCTAssertFalse(status.isLocked)
    XCTAssertEqual(status.activeProtections, ["启动解锁", "私密内容遮挡"])
    XCTAssertTrue(status.detail.contains("可随时手动锁定"))
  }

  func testPrivacyProtectionStatusChecklistSummarizesReviewableBehavior() throws {
    let status = PrivacyProtectionStatus.make(
      settings: PrivacyProtectionSettings(
        requiresUnlockOnLaunch: true,
        locksWhenInactive: true,
        masksPrivateContent: true
      ),
      isLocked: true,
      reason: "启动保护已启用。"
    )

    let markdown = status.checklistMarkdown

    XCTAssertTrue(markdown.contains("# 隐私锁和私密内容保护"))
    XCTAssertTrue(markdown.contains("- 当前状态：工作台已锁定"))
    XCTAssertTrue(markdown.contains("启动解锁、后台自动锁定、私密内容遮挡"))
    XCTAssertTrue(markdown.contains("启动保护开启时"))
    XCTAssertTrue(markdown.contains("敏感操作不可用"))
    XCTAssertTrue(markdown.contains("主窗口、文章窗口和设置窗口都显示隐私锁遮罩"))
    XCTAssertTrue(markdown.contains("设置窗口锁定时禁用设置项"))
    XCTAssertTrue(markdown.contains("不暴露私密文章标题、摘要或路径"))
    XCTAssertTrue(markdown.contains("不得包含本地路径、Token、授权头或私密正文"))
  }

  func testPrivacyProtectionEvidencePackageSummarizesEventsWithoutPrivateMetadata() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: true,
        locksWhenInactive: true,
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
    store.lockPrivacyIfNeededForInactiveScene()

    let markdown = store.privacyProtectionEvidencePackage.checklistMarkdown

    XCTAssertTrue(markdown.contains("# 隐私锁证据包"))
    XCTAssertTrue(markdown.contains("## 最近隐私事件"))
    XCTAssertTrue(markdown.contains("后台自动锁定"))
    XCTAssertTrue(markdown.contains("swift test --filter PrivacyProtectionTests"))
    XCTAssertTrue(markdown.contains("bash script/check_privacy_support_copy.sh"))
    XCTAssertTrue(markdown.contains("bash script/check_screenshot_privacy.sh"))
    XCTAssertFalse(markdown.contains("Secret Launch Plan"))
    XCTAssertFalse(markdown.contains("secret-launch-plan"))
    XCTAssertFalse(markdown.contains("Hidden launch notes"))
    XCTAssertFalse(markdown.contains("Private body"))
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
    XCTAssertEqual(privateDisplay.title, "私密文章")
    XCTAssertFalse(privateDisplay.summary.contains("Hidden"))
    XCTAssertFalse(publicDisplay.isMasked)
    XCTAssertEqual(publicDisplay.title, "Public Plan")
  }

  func testPrivacyProtectedDraftSearchDoesNotMatchHiddenPrivateMetadata() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
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

    XCTAssertFalse(
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
  }

  func testPrivacyProtectedDraftSearchUsesRawMetadataWhenMaskingDisabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
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

  func testContentHealthSummariesMaskPrivateDraftTitleAndPathWhenEnabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
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

    XCTAssertEqual(summary.draftTitle, "私密文章")
    XCTAssertEqual(summary.markdownPath, "内容已遮挡，打开文章或关闭私密遮挡后查看。")
    XCTAssertFalse(summary.draftTitle.contains("Secret"))
    XCTAssertFalse(summary.markdownPath.contains("secret-launch-plan"))
  }

  func testContentHealthSummariesUseRawPrivateDraftMetadataWhenMaskingDisabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
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

  func testSEOSocialPublishPackageMasksPrivateDraftWhenProtectionEnabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
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

    let markdown = try XCTUnwrap(store.seoSocialPublishPackageMarkdown(for: privateDraft))

    XCTAssertTrue(markdown.contains("# SEO / Social 发布包已遮挡"))
    XCTAssertTrue(markdown.contains("- 文章：私密文章"))
    XCTAssertTrue(markdown.contains("私密内容遮挡已开启"))
    XCTAssertFalse(markdown.contains("Secret Launch Plan"))
    XCTAssertFalse(markdown.contains("secret-launch-plan"))
    XCTAssertFalse(markdown.contains("Hidden launch notes"))
    XCTAssertFalse(markdown.contains("Private body"))
  }

  func testGeneralDraftLibraryReportMasksPrivateDraftsAndAssetsWhenProtectionEnabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
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
    let asset = try XCTUnwrap(report.assets.first)
    let package = report.crossSiteMaterialPackageMarkdown

    XCTAssertEqual(item.title, "私密文章")
    XCTAssertEqual(item.slug, "")
    XCTAssertEqual(item.summary, "内容已遮挡，打开文章或关闭私密遮挡后查看。")
    XCTAssertEqual(item.tags, [])
    XCTAssertEqual(item.categories, [])
    XCTAssertEqual(item.bodyCharacterCount, 0)
    XCTAssertTrue(item.reuseChecklistMarkdown.contains("私密文章"))
    XCTAssertFalse(item.reuseChecklistMarkdown.contains("Secret Cross Site Plan"))

    XCTAssertEqual(asset.draftTitle, "私密文章")
    XCTAssertEqual(asset.originalFilename, "私密附件")
    XCTAssertEqual(asset.relativePublishPath, "内容已遮挡")
    XCTAssertEqual(asset.repositoryPath, "内容已遮挡")

    XCTAssertTrue(package.contains("[可复用候选] 私密文章"))
    XCTAssertTrue(package.contains("Slug：未设置"))
    XCTAssertTrue(package.contains("私密附件"))
    XCTAssertFalse(package.contains("Secret Cross Site Plan"))
    XCTAssertFalse(package.contains("secret-cross-site-plan"))
    XCTAssertFalse(package.contains("Hidden cross-site notes"))
    XCTAssertFalse(package.contains("Private reusable body"))
    XCTAssertFalse(package.contains("secret-diagram.png"))
    XCTAssertFalse(package.contains("static/private"))
    XCTAssertFalse(package.contains("internal"))
  }

  func testGeneralDraftLibraryReportUsesRawPrivateDraftsWhenMaskingDisabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
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
    XCTAssertEqual(report.items.first?.slug, "secret-cross-site-plan")
    XCTAssertEqual(report.assets.first?.originalFilename, "secret-diagram.png")
    XCTAssertTrue(report.crossSiteMaterialPackageMarkdown.contains("Secret Cross Site Plan"))
    XCTAssertTrue(report.crossSiteMaterialPackageMarkdown.contains("secret-diagram.png"))
  }

  func testPrivacyProtectionAuditFlagsVisiblePrivateDraftsWhenMaskingDisabled() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: false,
        locksWhenInactive: true,
        masksPrivateContent: false
      )
    )
    store.setDrafts([
      ArticleDraft(
        siteProfileID: store.activeProfileID,
        title: "Secret Roadmap",
        slug: "secret-roadmap",
        visibility: .private,
        summary: "Internal plan"
      )
    ])

    let audit = store.privacyProtectionAudit

    XCTAssertEqual(audit.level, .exposed)
    XCTAssertEqual(audit.privateDraftCount, 1)
    XCTAssertEqual(audit.maskedPrivateDraftCount, 0)
    XCTAssertEqual(audit.visiblePrivateDraftCount, 1)
    XCTAssertTrue(audit.message.contains("1 篇私密文章"))
    XCTAssertTrue(audit.recommendations.contains { $0.contains("私密内容遮挡") })
    XCTAssertTrue(audit.checklistMarkdown.contains("# 隐私保护体检"))
    XCTAssertTrue(audit.checklistMarkdown.contains("- 可见风险：1"))
  }

  func testPrivacyProtectionAuditCountsOnlyActiveProfilePrivateDrafts() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        requiresUnlockOnLaunch: true,
        locksWhenInactive: true,
        masksPrivateContent: true
      )
    )
    store.lockPrivacy(reason: "Manual")
    store.setDrafts([
      ArticleDraft(
        siteProfileID: store.activeProfileID,
        title: "Active Secret",
        slug: "active-secret",
        visibility: .private
      ),
      ArticleDraft(
        siteProfileID: UUID(),
        title: "Other Site Secret",
        slug: "other-secret",
        visibility: .private
      )
    ])

    let audit = store.privacyProtectionAudit

    XCTAssertEqual(audit.level, .protected)
    XCTAssertEqual(audit.privateDraftCount, 1)
    XCTAssertEqual(audit.maskedPrivateDraftCount, 1)
    XCTAssertEqual(audit.visiblePrivateDraftCount, 0)
    XCTAssertTrue(audit.recommendations.isEmpty)
    XCTAssertTrue(audit.message.contains("1 篇私密文章已在列表、搜索和概览中遮挡"))
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PrivacyProtectionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }
}
