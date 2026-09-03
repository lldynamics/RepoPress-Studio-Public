import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchPersistenceTests: XCTestCase {
  func testPreloadedSnapshotAvoidsReadingCorruptPersistenceOnMainActor() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("{ corrupt persistence".utf8).write(to: url)
    var snapshot = makeSnapshot()
    snapshot.drafts[0].title = "后台预加载的工作台"

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: url),
      initialSnapshotSource: .preloaded(
        WorkbenchSnapshotLoadResult(snapshot: snapshot)
      )
    )

    XCTAssertEqual(store.selectedDraft?.title, "后台预加载的工作台")
    XCTAssertFalse(store.isPersistenceRecoveryWriteProtected)
    XCTAssertNil(store.persistenceRecoveryMessage)
    XCTAssertEqual(try Data(contentsOf: url), Data("{ corrupt persistence".utf8))
  }

  func testDuplicateCachedSnapshotsKeepNewestValueWithoutCrashingStoreLoad() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft.empty(profile: profile)
    let releaseRecordID = UUID()
    let olderDeployment = DeploymentStatusSnapshot(
      profileID: profile.id,
      releaseRecordID: releaseRecordID,
      provider: .custom,
      level: .running,
      title: "Older",
      message: "Older status",
      siteURLText: nil,
      checkedAt: Date(timeIntervalSince1970: 1),
      signals: []
    )
    let newerDeployment = DeploymentStatusSnapshot(
      profileID: profile.id,
      releaseRecordID: releaseRecordID,
      provider: .custom,
      level: .success,
      title: "Newer",
      message: "Newer status",
      siteURLText: nil,
      checkedAt: Date(timeIntervalSince1970: 2),
      signals: []
    )
    let olderSEO = SEOSocialPreviewSnapshot(
      draftID: draft.id,
      signature: "older",
      markdownPath: "content/older.md",
      canonicalURLText: "https://example.com/older",
      titleCharacterCount: 5,
      descriptionCharacterCount: 5,
      imagePath: nil,
      cards: [],
      findings: [],
      generatedAt: Date(timeIntervalSince1970: 1)
    )
    let newerSEO = SEOSocialPreviewSnapshot(
      draftID: draft.id,
      signature: "newer",
      markdownPath: "content/newer.md",
      canonicalURLText: "https://example.com/newer",
      titleCharacterCount: 5,
      descriptionCharacterCount: 5,
      imagePath: nil,
      cards: [],
      findings: [],
      generatedAt: Date(timeIntervalSince1970: 2)
    )
    let persistence = WorkbenchPersistence(fileURL: url)
    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [draft],
        releaseRecords: [],
        seoSocialPreviewSnapshots: [olderSEO, newerSEO],
        deploymentStatusSnapshots: [olderDeployment, newerDeployment]
      )
    )

    let store = WorkbenchStore(persistence: persistence)

    XCTAssertEqual(store.deploymentStatusSnapshots[releaseRecordID]?.title, "Newer")
    XCTAssertEqual(store.seoSocialPreviewSnapshots[draft.id]?.signature, "newer")
  }

  func testSnapshotKeepsAIConversationsForLiveAndRecycledDraftsButDropsOrphans() throws {
    let profile = SiteProfile.defaultProfile
    let liveDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Live",
      slug: "live"
    )
    let recycledDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Recycled",
      slug: "recycled"
    )
    let liveConversation = AIConversation(draftID: liveDraft.id, title: "Live")
    let recycledConversation = AIConversation(draftID: recycledDraft.id, title: "Recycled")
    let orphanConversation = AIConversation(draftID: UUID(), title: "Orphan")
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [liveDraft],
      recycledDrafts: [RecycledDraft(draft: recycledDraft)],
      releaseRecords: [],
      aiConversations: [liveConversation, recycledConversation, orphanConversation],
      activeAIConversationIDsByDraftID: [
        liveDraft.id: liveConversation.id,
        recycledDraft.id: recycledConversation.id,
        try XCTUnwrap(orphanConversation.draftID): orphanConversation.id,
      ]
    )

    XCTAssertEqual(
      Set(snapshot.aiConversations.map(\.id)),
      Set([liveConversation.id, recycledConversation.id])
    )
    XCTAssertEqual(
      snapshot.activeAIConversationIDsByDraftID,
      [
        liveDraft.id: liveConversation.id,
        recycledDraft.id: recycledConversation.id,
      ]
    )

    var encodedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(snapshot)) as? [String: Any]
    )
    encodedObject["aiConversations"] = try JSONSerialization.jsonObject(
      with: JSONEncoder.workbench.encode([
        liveConversation,
        recycledConversation,
        orphanConversation,
      ])
    )
    encodedObject["activeAIConversationIDsByDraftID"] = try JSONSerialization.jsonObject(
      with: JSONEncoder.workbench.encode([
        liveDraft.id: liveConversation.id,
        recycledDraft.id: recycledConversation.id,
        try XCTUnwrap(orphanConversation.draftID): orphanConversation.id,
      ])
    )

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: JSONSerialization.data(withJSONObject: encodedObject)
    )

    XCTAssertEqual(
      Set(decoded.aiConversations.map(\.id)),
      Set([liveConversation.id, recycledConversation.id])
    )
    XCTAssertEqual(
      decoded.activeAIConversationIDsByDraftID,
      [
        liveDraft.id: liveConversation.id,
        recycledDraft.id: recycledConversation.id,
      ]
    )
  }

  func testSoftwareGuideSeedPolicyCreatesSafeGuidesForFreshWorkspace() async {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)

    let store = WorkbenchStore(
      persistence: persistence,
      freshWorkspaceSeedPolicy: .softwareGuides
    )

    XCTAssertEqual(
      store.drafts.map(\.slug),
      [
        "personal-site-publisher-getting-started",
        "personal-site-publisher-writing-preview",
        "personal-site-publisher-ai-assistant",
        "personal-site-publisher-knowledge-library",
        "personal-site-publisher-rss-reading",
        "personal-site-publisher-safe-publishing",
        "personal-site-publisher-maintenance",
      ]
    )
    XCTAssertEqual(store.selectedDraft?.id, store.drafts.first?.id)
    XCTAssertEqual(store.draftListContentScope, .general)
    XCTAssertTrue(store.drafts.allSatisfy(\.isGeneralDraft))
    XCTAssertTrue(store.drafts.allSatisfy(\.draft))
    XCTAssertTrue(store.drafts.allSatisfy { $0.status == .draft })
    XCTAssertTrue(store.drafts.allSatisfy { $0.repositoryPath == nil && $0.repositorySHA == nil })
    XCTAssertTrue(
      store.drafts.allSatisfy {
        $0.softwareGuideTemplateVersion == ArticleDraft.currentSoftwareGuideSeedVersion
      }
    )
    XCTAssertEqual(Set(store.drafts.map(\.slug)).count, store.drafts.count)
    XCTAssertEqual(Set(store.drafts.compactMap(\.softwareGuideID)).count, store.drafts.count)

    let initialIDs = store.drafts.map(\.id)
    await store.waitForPendingSave()
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    let reloaded = WorkbenchStore(
      persistence: persistence,
      freshWorkspaceSeedPolicy: .softwareGuides
    )
    XCTAssertEqual(reloaded.drafts.map(\.id), initialIDs)
  }

  func testSoftwareGuidesFollowPreferredChineseAndEnglishLanguage() throws {
    let profile = SiteProfile.defaultProfile
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let chinese = ArticleDraft.samples(
      profile: profile,
      preferredLanguage: "zh-Hans",
      now: now
    )
    let english = ArticleDraft.samples(
      profile: profile,
      preferredLanguage: "en-US",
      now: now
    )

    XCTAssertEqual(chinese.map(\.slug), english.map(\.slug))
    XCTAssertEqual(chinese.map(\.softwareGuideID), english.map(\.softwareGuideID))
    XCTAssertEqual(chinese.count, 7)
    XCTAssertEqual(chinese.first?.title, "开始使用：认识发布工作台")
    XCTAssertEqual(english.first?.title, "Getting Started: Meet Your Publishing Workbench")
    let chineseByID = Dictionary(
      uniqueKeysWithValues: chinese.compactMap { guide in
        guide.softwareGuideID.map { ($0, guide) }
      }
    )
    let englishByID = Dictionary(
      uniqueKeysWithValues: english.compactMap { guide in
        guide.softwareGuideID.map { ($0, guide) }
      }
    )
    let chineseGettingStarted = try XCTUnwrap(chineseByID["getting-started"])
    let englishGettingStarted = try XCTUnwrap(englishByID["getting-started"])
    let chineseWriting = try XCTUnwrap(chineseByID["writing-preview"])
    let englishWriting = try XCTUnwrap(englishByID["writing-preview"])
    let chineseAI = try XCTUnwrap(chineseByID["ai-assistant"])
    let englishAI = try XCTUnwrap(englishByID["ai-assistant"])
    let chineseLibrary = try XCTUnwrap(chineseByID["knowledge-library"])
    let englishLibrary = try XCTUnwrap(englishByID["knowledge-library"])
    let chineseRSS = try XCTUnwrap(chineseByID["rss-reading"])
    let englishRSS = try XCTUnwrap(englishByID["rss-reading"])
    let chinesePublishing = try XCTUnwrap(chineseByID["safe-publishing"])
    let englishPublishing = try XCTUnwrap(englishByID["safe-publishing"])
    let chineseMaintenance = try XCTUnwrap(chineseByID["maintenance-recovery"])
    let englishMaintenance = try XCTUnwrap(englishByID["maintenance-recovery"])

    XCTAssertTrue(chineseGettingStarted.bodyMarkdown.contains("写作、资料库、RSS 阅读、站点、检查"))
    XCTAssertTrue(
      englishGettingStarted.bodyMarkdown.contains("Writing, Library, RSS, Site, and Checks")
    )
    XCTAssertTrue(chineseGettingStarted.bodyMarkdown.contains("通用草稿（General Drafts）"))
    XCTAssertTrue(englishGettingStarted.bodyMarkdown.contains("General Drafts"))
    XCTAssertTrue(chineseWriting.bodyMarkdown.contains("新建通用草稿"))
    XCTAssertTrue(englishWriting.bodyMarkdown.contains("New General Draft"))
    XCTAssertTrue(chineseWriting.bodyMarkdown.contains("本地预览"))
    XCTAssertTrue(englishWriting.bodyMarkdown.contains("Local Preview"))
    XCTAssertTrue(chineseAI.bodyMarkdown.contains("ChatGPT 登录"))
    XCTAssertTrue(chineseAI.bodyMarkdown.contains("本地模型"))
    XCTAssertTrue(chineseAI.bodyMarkdown.contains("允许发送给远程 AI"))
    XCTAssertTrue(englishAI.bodyMarkdown.contains("ChatGPT Sign-In"))
    XCTAssertTrue(englishAI.bodyMarkdown.contains("Local Model"))
    XCTAssertTrue(englishAI.bodyMarkdown.contains("Allow Sending to Remote AI"))
    XCTAssertTrue(chineseLibrary.bodyMarkdown.contains("不包含在 App 包内"))
    XCTAssertTrue(englishLibrary.bodyMarkdown.contains("Chrome extension is not included"))
    XCTAssertTrue(chineseLibrary.bodyMarkdown.contains("资料需先固定到 AI"))
    XCTAssertTrue(englishLibrary.bodyMarkdown.contains("Pin a source to AI first"))
    XCTAssertTrue(chineseRSS.bodyMarkdown.contains("发现并添加"))
    XCTAssertTrue(chineseRSS.bodyMarkdown.contains("订阅迁移"))
    XCTAssertTrue(chineseRSS.bodyMarkdown.contains("Apple 本机翻译"))
    XCTAssertTrue(chineseRSS.bodyMarkdown.contains("当前 AI 服务"))
    XCTAssertTrue(chineseRSS.bodyMarkdown.contains("新建灵感草稿"))
    XCTAssertTrue(chineseRSS.bodyMarkdown.contains("其中包含 RSS 数据，但不包含 API Key"))
    XCTAssertTrue(englishRSS.bodyMarkdown.contains("Discover and Add"))
    XCTAssertTrue(englishRSS.bodyMarkdown.contains("Subscription Migration"))
    XCTAssertTrue(englishRSS.bodyMarkdown.contains("Apple On-Device Translation"))
    XCTAssertTrue(englishRSS.bodyMarkdown.contains("Current AI Service"))
    XCTAssertTrue(englishRSS.bodyMarkdown.contains("New Idea Draft"))
    XCTAssertTrue(englishRSS.bodyMarkdown.contains("It includes RSS data but excludes API keys"))
    XCTAssertTrue(chineseGettingStarted.bodyMarkdown.contains("审阅并发布所有文件"))
    XCTAssertTrue(englishGettingStarted.bodyMarkdown.contains("Review and Publish All Files"))
    XCTAssertTrue(chinesePublishing.bodyMarkdown.contains("发布仓库全部文件"))
    XCTAssertTrue(englishPublishing.bodyMarkdown.contains("Publish All Repository Files"))
    XCTAssertTrue(chinesePublishing.bodyMarkdown.contains("推送成功不等于生产站点已上线"))
    XCTAssertTrue(englishPublishing.bodyMarkdown.contains("not proof that production is live"))
    XCTAssertTrue(chineseMaintenance.bodyMarkdown.contains("检查 → 站点维护"))
    XCTAssertTrue(englishMaintenance.bodyMarkdown.contains("Checks → Site Maintenance"))
    XCTAssertFalse(chinese.contains { $0.bodyMarkdown.contains("仓库与发布") })
    XCTAssertFalse(chinese.contains { $0.bodyMarkdown.contains("内容健康") })
    XCTAssertFalse(english.contains { $0.bodyMarkdown.contains("Repository & Publish") })
    XCTAssertFalse(english.contains { $0.bodyMarkdown.contains("Content Health") })
    XCTAssertTrue(
      (chinese + english).allSatisfy { !$0.summary.isEmpty && !$0.bodyMarkdown.isEmpty })
    XCTAssertTrue((chinese + english).allSatisfy { $0.authors == [profile.defaultAuthor] })
    XCTAssertTrue((chinese + english).allSatisfy(\.isGeneralDraft))
  }

  func testSoftwareGuideVersionFiveRefreshesManagedVersionFourGuideInGeneralDrafts()
    async throws
  {
    XCTAssertEqual(ArticleDraft.currentSoftwareGuideSeedVersion, 5)
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let profile = SiteProfile.defaultProfile
    let currentTemplate = try XCTUnwrap(
      ArticleDraft.samples(profile: profile).first { $0.softwareGuideID == "safe-publishing" }
    )
    var versionFourGuide = currentTemplate
    versionFourGuide.assignToSite(profile.id)
    versionFourGuide.bodyMarkdown = "# Version 4 publishing guide\n"
    versionFourGuide.softwareGuideTemplateVersion = 4
    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [versionFourGuide],
        softwareGuideSeedVersion: 4,
        releaseRecords: []
      )
    )

    let store = WorkbenchStore(
      persistence: persistence,
      freshWorkspaceSeedPolicy: .softwareGuides
    )

    let refreshedGuide = try XCTUnwrap(
      store.drafts.first { $0.softwareGuideID == "safe-publishing" }
    )
    let newlyInstalledRSSGuide = try XCTUnwrap(
      store.drafts.first { $0.softwareGuideID == "rss-reading" }
    )
    XCTAssertEqual(store.drafts.count, 2)
    XCTAssertEqual(refreshedGuide.id, versionFourGuide.id)
    XCTAssertTrue(refreshedGuide.isGeneralDraft)
    XCTAssertNil(refreshedGuide.repositoryPath)
    XCTAssertNil(refreshedGuide.repositorySHA)
    XCTAssertEqual(refreshedGuide.bodyMarkdown, currentTemplate.bodyMarkdown)
    XCTAssertEqual(refreshedGuide.softwareGuideTemplateVersion, 5)
    XCTAssertTrue(newlyInstalledRSSGuide.isGeneralDraft)
    XCTAssertNil(newlyInstalledRSSGuide.repositoryPath)
    XCTAssertNil(newlyInstalledRSSGuide.repositorySHA)
    XCTAssertEqual(newlyInstalledRSSGuide.softwareGuideTemplateVersion, 5)
    XCTAssertFalse(store.drafts.contains { $0.softwareGuideID == "writing-preview" })
    XCTAssertEqual(store.softwareGuideSeedVersion, 5)
    await store.waitForPendingSave()
  }

  func testSoftwareGuideVersionUpgradeRefreshesManagedGuidesAndAddsNewGuides() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let profile = SiteProfile.defaultProfile
    var legacyGuides = ArticleDraft.samples(
      profile: profile,
      preferredLanguage: "zh-Hans"
    ).filter {
      $0.softwareGuideID != "ai-assistant" && $0.softwareGuideID != "rss-reading"
    }
    let legacyIDs = legacyGuides.map(\.id)
    for index in legacyGuides.indices {
      legacyGuides[index].assignToSite(profile.id)
      legacyGuides[index].title = "旧版指南"
      legacyGuides[index].bodyMarkdown = "# 旧版指南\n"
      legacyGuides[index].softwareGuideTemplateVersion = 1
    }
    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: legacyGuides,
        softwareGuideSeedVersion: 1,
        releaseRecords: []
      )
    )

    let store = WorkbenchStore(
      persistence: persistence,
      freshWorkspaceSeedPolicy: .softwareGuides
    )

    XCTAssertEqual(Set(store.drafts.compactMap(\.softwareGuideID)).count, 7)
    XCTAssertEqual(
      store.drafts.compactMap(\.softwareGuideID),
      [
        "getting-started",
        "writing-preview",
        "ai-assistant",
        "knowledge-library",
        "rss-reading",
        "safe-publishing",
        "maintenance-recovery",
      ]
    )
    XCTAssertTrue(legacyIDs.allSatisfy { legacyID in store.drafts.contains { $0.id == legacyID } })
    XCTAssertTrue(store.drafts.contains { $0.softwareGuideID == "ai-assistant" })
    XCTAssertTrue(store.drafts.contains { $0.softwareGuideID == "rss-reading" })
    XCTAssertTrue(store.drafts.allSatisfy(\.isGeneralDraft))
    XCTAssertNotEqual(
      try XCTUnwrap(
        store.drafts.first { $0.softwareGuideID == "getting-started" }
      ).bodyMarkdown,
      "# 旧版指南\n"
    )
    XCTAssertTrue(
      store.drafts.allSatisfy {
        $0.softwareGuideTemplateVersion == ArticleDraft.currentSoftwareGuideSeedVersion
      }
    )
    await store.waitForPendingSave()
  }

  func testSoftwareGuideVersionUpgradePreservesCustomizedAndRemovedGuides() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let profile = SiteProfile.defaultProfile
    var customizedGuide = ArticleDraft.samples(
      profile: profile,
      preferredLanguage: "zh-Hans"
    )[0]
    customizedGuide.bodyMarkdown = "# 我的发布手册\n"
    customizedGuide.softwareGuideTemplateVersion = 0
    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [customizedGuide],
        softwareGuideSeedVersion: 4,
        releaseRecords: []
      )
    )

    let store = WorkbenchStore(
      persistence: persistence,
      freshWorkspaceSeedPolicy: .softwareGuides
    )
    let guideIDs = Set(store.drafts.compactMap(\.softwareGuideID))

    XCTAssertEqual(guideIDs, Set(["getting-started", "rss-reading"]))
    XCTAssertFalse(guideIDs.contains("writing-preview"))
    XCTAssertFalse(guideIDs.contains("ai-assistant"))
    XCTAssertEqual(
      store.drafts.first { $0.softwareGuideID == "getting-started" }?.bodyMarkdown,
      "# 我的发布手册\n"
    )
    XCTAssertEqual(
      store.drafts.first { $0.softwareGuideID == "getting-started" }?
        .softwareGuideTemplateVersion,
      0
    )
  }

  func testSoftwareGuideSeedPolicyInstallsGuidesOnceForExistingEmptySnapshot() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let profile = SiteProfile.defaultProfile
    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [],
        releaseRecords: []
      )
    )

    let store = WorkbenchStore(
      persistence: persistence,
      freshWorkspaceSeedPolicy: .softwareGuides
    )

    XCTAssertEqual(Set(store.drafts.compactMap(\.softwareGuideID)).count, 7)
    XCTAssertEqual(store.selectedDraft?.softwareGuideID, "getting-started")
    XCTAssertEqual(store.draftListContentScope, .general)
    XCTAssertTrue(store.drafts.allSatisfy(\.isGeneralDraft))
    XCTAssertEqual(
      store.softwareGuideSeedVersion,
      ArticleDraft.currentSoftwareGuideSeedVersion
    )
    await store.waitForPendingSave()

    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [],
        softwareGuideSeedVersion: ArticleDraft.currentSoftwareGuideSeedVersion,
        releaseRecords: []
      )
    )

    let reopenedAfterUserRemoval = WorkbenchStore(
      persistence: persistence,
      freshWorkspaceSeedPolicy: .softwareGuides
    )
    XCTAssertEqual(reopenedAfterUserRemoval.drafts.count, 1)
    XCTAssertEqual(reopenedAfterUserRemoval.selectedDraft?.title, "未命名文章")
    XCTAssertFalse(reopenedAfterUserRemoval.drafts.contains { $0.softwareGuideID != nil })
  }

  func testInstallingSoftwareGuidesIsIdempotentAndPreservesExistingDraft() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    let originalDraftID = store.drafts[0].id

    XCTAssertEqual(store.installSoftwareGuides(), 7)
    await store.waitForPendingSave()

    XCTAssertEqual(store.drafts.count, 8)
    XCTAssertTrue(store.drafts.contains { $0.id == originalDraftID })
    XCTAssertEqual(store.selectedDraft?.softwareGuideID, "getting-started")
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.draftListContentScope, .general)
    XCTAssertTrue(
      store.drafts.filter { $0.softwareGuideID != nil }.allSatisfy(\.isGeneralDraft)
    )
    XCTAssertEqual(
      store.softwareGuideSeedVersion,
      ArticleDraft.currentSoftwareGuideSeedVersion
    )

    XCTAssertEqual(store.installSoftwareGuides(), 0)
    XCTAssertEqual(store.drafts.count, 8)
    XCTAssertEqual(Set(store.drafts.map(\.slug)).count, store.drafts.count)

    var customizedGuide = try XCTUnwrap(
      store.drafts.first { $0.softwareGuideID == "getting-started" }
    )
    customizedGuide.bodyMarkdown = "# My customized guide\n"
    store.updateDraft(customizedGuide)
    XCTAssertEqual(
      store.drafts.first { $0.id == customizedGuide.id }?.softwareGuideTemplateVersion,
      0
    )
    XCTAssertEqual(store.installSoftwareGuides(), 0)
    XCTAssertEqual(
      store.drafts.first { $0.id == customizedGuide.id }?.bodyMarkdown,
      "# My customized guide\n"
    )
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertEqual(reloaded.drafts.count, 8)
    XCTAssertEqual(Set(reloaded.drafts.compactMap(\.softwareGuideID)).count, 7)
  }

  func testInstallingSoftwareGuidesResolvesUserSlugCollisionWithoutMisidentification() async throws
  {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    var userDraft = store.drafts[0]
    userDraft.title = "User-owned article"
    userDraft.slug = "personal-site-publisher-getting-started"
    store.updateDraft(userDraft)

    XCTAssertEqual(store.installSoftwareGuides(), 7)
    await store.waitForPendingSave()

    let preservedUserDraft = try XCTUnwrap(store.drafts.first(where: { $0.id == userDraft.id }))
    XCTAssertNil(preservedUserDraft.softwareGuideID)
    XCTAssertEqual(preservedUserDraft.slug, "personal-site-publisher-getting-started")
    let installedGuide = try XCTUnwrap(
      store.drafts.first(where: { $0.softwareGuideID == "getting-started" })
    )
    XCTAssertEqual(installedGuide.slug, "personal-site-publisher-getting-started-2")
    XCTAssertEqual(store.selectedDraft?.id, installedGuide.id)
    XCTAssertEqual(store.installSoftwareGuides(), 0)
  }

  func testInstallingSoftwareGuidesCompletesPartialGuideSet() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let profile = SiteProfile.defaultProfile
    let existingGuide = try XCTUnwrap(ArticleDraft.samples(profile: profile).first)
    _ = try persistence.save(
      WorkbenchSnapshot(
        profiles: [profile],
        activeProfileID: profile.id,
        drafts: [ArticleDraft.empty(profile: profile), existingGuide],
        releaseRecords: []
      )
    )
    let store = WorkbenchStore(persistence: persistence)

    XCTAssertEqual(store.installSoftwareGuides(), 6)
    await store.waitForPendingSave()

    XCTAssertEqual(Set(store.drafts.compactMap(\.softwareGuideID)).count, 7)
    XCTAssertEqual(
      store.drafts.filter { $0.softwareGuideID == existingGuide.softwareGuideID }.count, 1)
    XCTAssertEqual(store.selectedDraft?.softwareGuideID, "getting-started")
  }

  func testReleaseHistoryIsBoundedInMemoryAndDuringSnapshotMigration() throws {
    let profile = SiteProfile.defaultProfile
    let records = (0..<(ReleaseRecord.maximumRetainedRecords + 25)).map { index in
      ReleaseRecord(
        title: "Release \(index)",
        summary: "Summary \(index)",
        siteProfileID: profile.id,
        createdAt: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft.empty(profile: profile)],
      releaseRecords: records
    )

    XCTAssertEqual(snapshot.releaseRecords.count, ReleaseRecord.maximumRetainedRecords)
    XCTAssertEqual(snapshot.releaseRecords.first?.title, "Release 0")

    var encodedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(snapshot)) as? [String: Any]
    )
    encodedObject["releaseRecords"] = try JSONSerialization.jsonObject(
      with: JSONEncoder.workbench.encode(records)
    )
    let migrated = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: JSONSerialization.data(withJSONObject: encodedObject)
    )

    XCTAssertEqual(migrated.releaseRecords.count, ReleaseRecord.maximumRetainedRecords)
    XCTAssertEqual(migrated.releaseRecords.first?.title, "Release 0")

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: temporaryPersistenceURL()))
    store.setReleaseRecords(records)
    XCTAssertEqual(store.releaseRecords.count, ReleaseRecord.maximumRetainedRecords)
  }

  func testReleaseHistoryKeepsCallerOrderForEqualTimestamps() {
    let profile = SiteProfile.defaultProfile
    let timestamp = Date(timeIntervalSince1970: 1_900_000_000)
    let records = ["Running", "Failed", "Success"].map { title in
      ReleaseRecord(
        title: title,
        summary: title,
        siteProfileID: profile.id,
        createdAt: timestamp
      )
    }

    XCTAssertEqual(
      ReleaseRecord.limitedHistory(records).map(\.title), ["Running", "Failed", "Success"])
  }

  func testImageOptimizationCachePrunesOnlyUnreferencedBatchFolders() throws {
    let persistence = WorkbenchPersistence(fileURL: temporaryPersistenceURL())
    let rootURL = persistence.imageOptimizationDirectoryURL
    let referencedBatch = rootURL.appendingPathComponent(
      ".image-batch-referenced", isDirectory: true)
    let abandonedBatch = rootURL.appendingPathComponent(".image-batch-abandoned", isDirectory: true)
    let userFolder = rootURL.appendingPathComponent("manual-assets", isDirectory: true)
    try FileManager.default.createDirectory(at: referencedBatch, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: abandonedBatch, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
    let referencedImage = referencedBatch.appendingPathComponent("image.jpg")
    try Data([1, 2, 3]).write(to: referencedImage)
    try Data([4, 5, 6]).write(to: abandonedBatch.appendingPathComponent("old.jpg"))

    let removedCount = persistence.pruneUnreferencedImageOptimizationBatches(
      referencedSourceFilePaths: [referencedImage.path, "/tmp/not-in-cache.jpg"]
    )

    XCTAssertEqual(removedCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: referencedBatch.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedBatch.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: userFolder.path))
  }

  func testCorruptPrimaryRecoversLastKnownGoodSnapshot() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let snapshot = makeSnapshot()

    XCTAssertEqual(try persistence.save(snapshot), .saved)
    XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.lastKnownGoodURL.path))
    try "{ not valid JSON".write(to: url, atomically: true, encoding: .utf8)

    let result = try persistence.loadWithRecovery()
    XCTAssertEqual(result.snapshot?.drafts.first?.id, snapshot.drafts.first?.id)
    XCTAssertEqual(result.snapshot?.drafts.first?.title, snapshot.drafts.first?.title)
    XCTAssertNotNil(result.recoveryMessage)
  }

  func testSemanticallyInvalidPrimaryRecoversLastKnownGoodSnapshot() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let snapshot = makeSnapshot()
    _ = try persistence.save(snapshot)
    var invalidSnapshot = snapshot
    invalidSnapshot.drafts.append(snapshot.drafts[0])
    try JSONEncoder.workbench.encode(invalidSnapshot).write(to: url, options: .atomic)

    let result = try persistence.loadWithRecovery()

    XCTAssertEqual(result.snapshot?.drafts.map(\.id), snapshot.drafts.map(\.id))
    XCTAssertNotNil(result.recoveryMessage)
  }

  func testSemanticallyInvalidPrimaryAndBackupAreUnrecoverable() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    var invalidSnapshot = makeSnapshot()
    invalidSnapshot.drafts.append(invalidSnapshot.drafts[0])
    let invalidData = try JSONEncoder.workbench.encode(invalidSnapshot)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try invalidData.write(to: url, options: .atomic)
    try invalidData.write(to: persistence.lastKnownGoodURL, options: .atomic)

    XCTAssertThrowsError(try persistence.loadWithRecovery()) { error in
      guard case WorkbenchPersistenceError.unrecoverableSnapshot(let primary, let backup) = error
      else {
        return XCTFail("Expected unrecoverable snapshot, got \(error)")
      }
      XCTAssertTrue(primary.contains("重复"))
      XCTAssertTrue(backup?.contains("重复") == true)
    }
  }

  func testOversizedPrimaryRecoversBackupWithoutReadingWholeFile() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let snapshot = makeSnapshot()
    _ = try persistence.save(snapshot)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(
      atOffset: UInt64(WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount) + 1
    )
    try handle.close()

    let result = try persistence.loadWithRecovery()

    XCTAssertEqual(result.snapshot?.drafts.map(\.id), snapshot.drafts.map(\.id))
    XCTAssertNotNil(result.recoveryMessage)
  }

  func testMissingPrimaryRecoversBackupWithoutInstallingSoftwareGuides() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    var snapshot = makeSnapshot()
    snapshot.drafts[0].title = "Only backup copy"
    _ = try persistence.save(snapshot)
    try FileManager.default.removeItem(at: url)

    let result = try persistence.loadWithRecovery()
    XCTAssertEqual(result.snapshot?.drafts.first?.title, "Only backup copy")
    XCTAssertNotNil(result.recoveryMessage)

    let store = WorkbenchStore(
      persistence: persistence,
      freshWorkspaceSeedPolicy: .softwareGuides
    )
    XCTAssertEqual(store.drafts.count, 1)
    XCTAssertEqual(store.selectedDraft?.title, "Only backup copy")
    XCTAssertNotNil(store.persistenceRecoveryMessage)
    XCTAssertFalse(store.drafts.contains { $0.softwareGuideID != nil })
  }

  func testUnrecoverableSnapshotWriteProtectsOriginalFilesUntilExplicitReset() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let primaryData = Data("{ corrupt primary".utf8)
    let backupData = Data("{ corrupt backup".utf8)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try primaryData.write(to: url, options: .atomic)
    try backupData.write(to: persistence.lastKnownGoodURL, options: .atomic)

    let store = WorkbenchStore(persistence: persistence)
    XCTAssertTrue(store.isPersistenceRecoveryWriteProtected)
    XCTAssertNotNil(store.persistenceRecoveryMessage)

    var edited = try XCTUnwrap(store.selectedDraft)
    edited.title = "Must not overwrite corrupt recovery files"
    store.updateDraft(edited)
    store.save()
    await store.waitForPendingSave()
    try await Task.sleep(nanoseconds: 900_000_000)

    XCTAssertTrue(
      store.flushPendingChanges(),
      "Recovery protection should allow quitting without overwriting data")
    XCTAssertEqual(try Data(contentsOf: url), primaryData)
    XCTAssertEqual(try Data(contentsOf: persistence.lastKnownGoodURL), backupData)
    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertEqual(store.lastSaveStatus, "恢复保护中：原始数据尚未被覆盖")
  }

  func testExplicitResetArchivesCorruptFilesBeforeSavingBlankWorkspace() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let primaryData = Data("{ corrupt primary".utf8)
    let backupData = Data("{ corrupt backup".utf8)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try primaryData.write(to: url, options: .atomic)
    try backupData.write(to: persistence.lastKnownGoodURL, options: .atomic)

    let store = WorkbenchStore(persistence: persistence)
    let archiveURL = try XCTUnwrap(store.resetPersistenceAfterUnrecoverableSnapshot())
    await store.waitForPendingSave()

    XCTAssertFalse(store.isPersistenceRecoveryWriteProtected)
    XCTAssertNil(store.persistenceRecoveryMessage)
    XCTAssertEqual(
      try Data(contentsOf: archiveURL.appendingPathComponent(url.lastPathComponent)),
      primaryData
    )
    XCTAssertEqual(
      try Data(
        contentsOf: archiveURL.appendingPathComponent(
          persistence.lastKnownGoodURL.lastPathComponent)),
      backupData
    )
    XCTAssertNotNil(try persistence.load())
  }

  func testInstallingChosenRecoverySnapshotArchivesCorruptFilesAndReplacesBothCopies() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let primaryData = Data("{ corrupt primary".utf8)
    let backupData = Data("{ corrupt backup".utf8)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try primaryData.write(to: url, options: .atomic)
    try backupData.write(to: persistence.lastKnownGoodURL, options: .atomic)
    var recoverySnapshot = makeSnapshot()
    recoverySnapshot.drafts[0].title = "Recovered snapshot"
    let chosenURL = url.deletingLastPathComponent().appendingPathComponent("chosen-recovery.json")
    try JSONEncoder.workbench.encode(recoverySnapshot).write(to: chosenURL, options: .atomic)

    let archiveURL = try persistence.installRecoverySnapshot(from: chosenURL)

    XCTAssertEqual(try persistence.load()?.drafts.first?.title, "Recovered snapshot")
    XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: persistence.lastKnownGoodURL))
    XCTAssertEqual(
      try Data(contentsOf: archiveURL.appendingPathComponent(url.lastPathComponent)),
      primaryData
    )
    XCTAssertEqual(
      try Data(
        contentsOf: archiveURL.appendingPathComponent(
          persistence.lastKnownGoodURL.lastPathComponent)),
      backupData
    )
  }

  func testExportingRecoveryFilesCopiesPrimaryAndBackupWithoutMutatingThem() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let primaryData = Data("{ corrupt primary".utf8)
    let backupData = Data("{ corrupt backup".utf8)
    let exportRoot = url.deletingLastPathComponent().appendingPathComponent(
      "Export", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try primaryData.write(to: url, options: .atomic)
    try backupData.write(to: persistence.lastKnownGoodURL, options: .atomic)

    let exportURL = try persistence.exportRecoveryFiles(to: exportRoot)

    XCTAssertEqual(
      try Data(contentsOf: exportURL.appendingPathComponent(url.lastPathComponent)), primaryData)
    XCTAssertEqual(
      try Data(
        contentsOf: exportURL.appendingPathComponent(persistence.lastKnownGoodURL.lastPathComponent)
      ),
      backupData
    )
    XCTAssertEqual(try Data(contentsOf: url), primaryData)
    XCTAssertEqual(try Data(contentsOf: persistence.lastKnownGoodURL), backupData)
  }

  func testLegacySnapshotWithoutFormatVersionMigratesOnLoad() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let encoded = try JSONEncoder.workbench.encode(makeSnapshot())
    var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "formatVersion")
    object.removeValue(forKey: "softwareGuideSeedVersion")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

    let loaded = try XCTUnwrap(persistence.load())
    XCTAssertEqual(loaded.formatVersion, WorkbenchSnapshot.currentFormatVersion)
    XCTAssertEqual(loaded.softwareGuideSeedVersion, 0)
  }

  func testSavingV2SnapshotArchivesRetiredFeatureDataBeforeUpgrade() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let legacyData = try makeV2SnapshotDataWithRetiredFields()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try legacyData.write(to: url, options: .atomic)

    let loadedSnapshot = try XCTUnwrap(persistence.load())
    XCTAssertEqual(loadedSnapshot.formatVersion, WorkbenchSnapshot.currentFormatVersion)
    XCTAssertEqual(try Data(contentsOf: url), legacyData)

    XCTAssertEqual(try persistence.save(loadedSnapshot), .saved)

    let upgradedObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    XCTAssertEqual(upgradedObject["formatVersion"] as? Int, WorkbenchSnapshot.currentFormatVersion)
    XCTAssertNil(upgradedObject["contentPerformanceSnapshots"])
    XCTAssertNil(upgradedObject["externalVerificationEvidenceRecords"])

    let archiveURLs = try FileManager.default.contentsOfDirectory(
      at: persistence.retiredFeatureArchiveDirectoryURL,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(archiveURLs.count, 1)
    let archiveObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(archiveURLs.first)))
        as? [String: Any]
    )
    XCTAssertEqual(archiveObject["sourceFormatVersion"] as? Int, 2)
    let retiredFields = try XCTUnwrap(archiveObject["retiredFields"] as? [String: Any])
    let performanceRecords = try XCTUnwrap(
      retiredFields["contentPerformanceSnapshots"] as? [[String: Any]])
    let evidenceRecords = try XCTUnwrap(
      retiredFields["externalVerificationEvidenceRecords"] as? [[String: Any]])
    XCTAssertEqual(performanceRecords.first?["pageViews"] as? Int, 321)
    XCTAssertEqual(evidenceRecords.first?["summary"] as? String, "Redacted release evidence")
    XCTAssertEqual(evidenceRecords.first?["url"] as? String, "https://example.com/review/42")

    XCTAssertEqual(try persistence.save(loadedSnapshot), .saved)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: persistence.retiredFeatureArchiveDirectoryURL,
        includingPropertiesForKeys: nil
      ).count,
      1
    )
  }

  func testRetiredFeatureArchiveFailureDoesNotOverwriteV2Snapshot() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let legacyData = try makeV2SnapshotDataWithRetiredFields()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try legacyData.write(to: url, options: .atomic)
    let loadedSnapshot = try XCTUnwrap(persistence.load())
    try "blocks archive directory".write(
      to: persistence.retiredFeatureArchiveDirectoryURL,
      atomically: true,
      encoding: .utf8
    )

    XCTAssertThrowsError(try persistence.save(loadedSnapshot))
    XCTAssertEqual(try Data(contentsOf: url), legacyData)
  }

  func testSnapshotRejectsFutureFormatVersion() throws {
    let encoded = try JSONEncoder.workbench.encode(makeSnapshot())
    var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["formatVersion"] = WorkbenchSnapshot.currentFormatVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: object)

    XCTAssertThrowsError(try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: futureData))
  }

  func testStoreKeepsDirtyStateAndShowsFailureWhenPrimaryWriteFails() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PersonalSitePublisherMacPersistenceFailure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let blockingURL = directoryURL.appendingPathComponent("not-a-directory")
    try "blocking file".write(to: blockingURL, atomically: true, encoding: .utf8)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: blockingURL.appendingPathComponent("workbench.json")))

    store.save()
    await store.waitForPendingSave()

    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertNotNil(store.lastSaveError)
    XCTAssertTrue(store.lastSaveStatus.hasPrefix("保存失败："))
  }

  func testImmediateSaveDoesNotBlockMainActorWhileCommitIsInFlight() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let commitGate = ControlledPersistenceCommit()
    let persistenceStore = WorkbenchPersistenceStore(
      persistence: persistence,
      commitBackgroundSave: { persistence, preparedSave in
        try commitGate.commit(preparedSave, persistence: persistence)
      }
    )
    let probeReachedMainActor = DispatchSemaphore(value: 0)

    persistenceStore.saveImmediately(snapshot: makeSnapshot())
    let didStartCommit = await waitForSignal(commitGate.commitStarted)
    XCTAssertTrue(didStartCommit)

    Task { @MainActor in
      probeReachedMainActor.signal()
    }
    let didReachMainActor = await waitForSignal(probeReachedMainActor)
    XCTAssertTrue(didReachMainActor)
    XCTAssertTrue(persistenceStore.hasUnsavedChanges)
    XCTAssertEqual(persistenceStore.status, "正在后台保存…")

    commitGate.allowNextCommit()
    await persistenceStore.waitForCurrentBackgroundSave()
    XCTAssertFalse(persistenceStore.hasUnsavedChanges)
    XCTAssertFalse(commitGate.commitRanOnMainThread)
  }

  func testDraftEditsAutosaveAfterDebounceAndClearDirtyState() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    var firstEdit = try XCTUnwrap(store.selectedDraft)
    firstEdit.title = "First edit"
    store.updateDraft(firstEdit)
    var finalEdit = try XCTUnwrap(store.selectedDraft)
    finalEdit.title = "Final debounced edit"
    store.updateDraft(finalEdit)

    XCTAssertTrue(store.hasUnsavedChanges)
    await store.waitForPendingSave()

    XCTAssertFalse(store.hasUnsavedChanges)
    XCTAssertEqual(store.lastSaveStatus, "已保存")
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertEqual(reloaded.selectedDraft?.title, "Final debounced edit")
  }

  func testEditDuringBackgroundSaveKeepsDirtyStateUntilLatestSnapshotIsSaved() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let preparationStarted = DispatchSemaphore(value: 0)
    let allowPreparation = DispatchSemaphore(value: 0)
    let persistenceStore = WorkbenchPersistenceStore(
      persistence: persistence,
      prepareBackgroundSave: { persistence, snapshot in
        preparationStarted.signal()
        allowPreparation.wait()
        return try persistence.prepareSave(snapshot, reclaimUnreferencedAttachments: false)
      }
    )
    var firstSnapshot = makeSnapshot()
    firstSnapshot.drafts[0].title = "First in-flight edit"
    var latestSnapshot = firstSnapshot
    latestSnapshot.drafts[0].title = "Latest edit"

    persistenceStore.scheduleAutosave { firstSnapshot }
    let didStartFirstSave = await waitForSignal(preparationStarted)
    XCTAssertTrue(didStartFirstSave)

    persistenceStore.scheduleAutosave { latestSnapshot }
    allowPreparation.signal()
    await persistenceStore.waitForCurrentBackgroundSave()

    XCTAssertTrue(persistenceStore.hasUnsavedChanges)
    XCTAssertEqual(persistenceStore.status, "有未保存修改")

    let didStartLatestSave = await waitForSignal(preparationStarted)
    XCTAssertTrue(didStartLatestSave)
    allowPreparation.signal()
    await persistenceStore.waitForCurrentBackgroundSave()

    XCTAssertFalse(persistenceStore.hasUnsavedChanges)
    XCTAssertEqual(persistenceStore.status, "已保存")
    XCTAssertEqual(try persistence.load()?.drafts.first?.title, "Latest edit")
  }

  func testBackgroundCommitDoesNotBlockMainActorOrClearNewerRevision() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let commitGate = ControlledPersistenceCommit()
    let mainActorProbe = DispatchSemaphore(value: 0)
    let probeSucceeded = DispatchSemaphore(value: 0)
    let probeFinished = DispatchSemaphore(value: 0)
    let persistenceStore = WorkbenchPersistenceStore(
      persistence: persistence,
      commitBackgroundSave: { persistence, preparedSave in
        try commitGate.commit(preparedSave, persistence: persistence)
      }
    )
    var firstSnapshot = makeSnapshot()
    firstSnapshot.drafts[0].title = "First commit in flight"
    var latestSnapshot = firstSnapshot
    latestSnapshot.drafts[0].title = "Latest snapshot wins"

    DispatchQueue.global(qos: .userInitiated).async {
      guard commitGate.firstCommitStartedForProbe.wait(timeout: .now() + 2) == .success else {
        commitGate.allowNextCommit()
        probeFinished.signal()
        return
      }
      if mainActorProbe.wait(timeout: .now() + 0.4) == .success {
        probeSucceeded.signal()
      }
      commitGate.allowNextCommit()
      probeFinished.signal()
    }

    persistenceStore.scheduleAutosave { firstSnapshot }
    let didStartFirstCommit = await waitForSignal(commitGate.commitStarted)
    XCTAssertTrue(didStartFirstCommit)

    // This edit must be accepted while the first atomic commit is deliberately
    // blocked. If commit still runs on MainActor, the probe times out first.
    persistenceStore.scheduleAutosave { latestSnapshot }
    mainActorProbe.signal()
    let didFinishProbe = await waitForSignal(probeFinished)
    XCTAssertTrue(didFinishProbe)
    XCTAssertEqual(probeSucceeded.wait(timeout: .now()), .success)
    await persistenceStore.waitForCurrentBackgroundSave()

    XCTAssertFalse(commitGate.commitRanOnMainThread)
    XCTAssertTrue(persistenceStore.hasUnsavedChanges)
    XCTAssertEqual(persistenceStore.status, "有未保存修改")

    let didStartLatestCommit = await waitForSignal(commitGate.commitStarted)
    XCTAssertTrue(didStartLatestCommit)
    commitGate.allowNextCommit()
    await persistenceStore.waitForCurrentBackgroundSave()

    XCTAssertFalse(persistenceStore.hasUnsavedChanges)
    XCTAssertEqual(persistenceStore.status, "已保存")
    XCTAssertEqual(try persistence.load()?.drafts.first?.title, "Latest snapshot wins")
  }

  func testAutosaveNormalizesFrozenInputOffMainActor() async throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: url)
    let sourceStore = WorkbenchStore(
      persistence: persistence,
      safeMode: true
    )
    let frozenInput = persistence.snapshotInput(from: sourceStore)
    let preparationProbe = PersistencePreparationProbe()
    let persistenceStore = WorkbenchPersistenceStore(
      persistence: persistence,
      prepareBackgroundSave: { persistence, snapshot in
        preparationProbe.record()
        return try persistence.prepareSave(snapshot, reclaimUnreferencedAttachments: false)
      }
    )

    persistenceStore.scheduleAutosave(input: { frozenInput })
    try await Task.sleep(nanoseconds: 900_000_000)
    await persistenceStore.waitForCurrentBackgroundSave()

    XCTAssertTrue(preparationProbe.didRun)
    XCTAssertFalse(preparationProbe.ranOnMainThread)
    XCTAssertFalse(persistenceStore.hasUnsavedChanges)
  }

  func testFlushPendingChangesWritesImmediatelyBeforeExit() throws {
    let url = temporaryPersistenceURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    var edited = try XCTUnwrap(store.selectedDraft)
    edited.bodyMarkdown = "# Flush before exit"
    store.updateDraft(edited)

    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertTrue(store.flushPendingChanges())
    XCTAssertFalse(store.hasUnsavedChanges)
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertEqual(reloaded.selectedDraft?.bodyMarkdown, "# Flush before exit")
  }

  private func makeSnapshot() -> WorkbenchSnapshot {
    let profile = SiteProfile.defaultProfile
    return WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft.empty(profile: profile)],
      releaseRecords: []
    )
  }

  private func temporaryPersistenceURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PersonalSitePublisherMacPersistenceTests-\(UUID().uuidString)", isDirectory: true
      )
      .appendingPathComponent("workbench.json")
  }

  private func makeV2SnapshotDataWithRetiredFields() throws -> Data {
    let encoded = try JSONEncoder.workbench.encode(makeSnapshot())
    var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["formatVersion"] = 2
    object["contentPerformanceSnapshots"] = [
      [
        "draftID": "11111111-1111-1111-1111-111111111111",
        "pageViews": 321,
        "visitors": 123,
      ]
    ]
    object["externalVerificationEvidenceRecords"] = [
      [
        "summary": "Redacted release evidence",
        "url": "https://example.com/review/42",
      ]
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success)
      }
    }
  }
}

private final class ControlledPersistenceCommit: @unchecked Sendable {
  let commitStarted = DispatchSemaphore(value: 0)
  let firstCommitStartedForProbe = DispatchSemaphore(value: 0)

  private let allowCommit = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var commitCount = 0
  private var didRunOnMainThread = false

  var commitRanOnMainThread: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didRunOnMainThread
  }

  func allowNextCommit() {
    allowCommit.signal()
  }

  func commit(
    _ preparedSave: WorkbenchPreparedPersistenceSave,
    persistence: WorkbenchPersistence
  ) throws -> WorkbenchPersistenceSaveResult {
    lock.lock()
    commitCount += 1
    let isFirstCommit = commitCount == 1
    didRunOnMainThread = didRunOnMainThread || Thread.isMainThread
    lock.unlock()

    commitStarted.signal()
    if isFirstCommit {
      firstCommitStartedForProbe.signal()
    }
    _ = allowCommit.wait(timeout: .now() + 3)
    return try persistence.commit(preparedSave)
  }
}

private final class PersistencePreparationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var didRunValue = false
  private var ranOnMainThreadValue = false

  var didRun: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didRunValue
  }

  var ranOnMainThread: Bool {
    lock.lock()
    defer { lock.unlock() }
    return ranOnMainThreadValue
  }

  func record() {
    lock.lock()
    didRunValue = true
    ranOnMainThreadValue = Thread.isMainThread
    lock.unlock()
  }
}
