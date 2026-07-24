import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreProfileTests: XCTestCase {
  func testDraftVisitHistoryReturnsAcrossSitesAfterFocusedNavigation() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let firstSite = store.activeProfile
    let secondSite = store.createProfile(named: "第二站点")
    let firstDraft = ArticleDraft(siteProfileID: firstSite.id, title: "来源文章", slug: "source")
    let secondDraft = ArticleDraft(siteProfileID: secondSite.id, title: "搜索结果", slug: "result")
    store.setDrafts([firstDraft, secondDraft])

    XCTAssertTrue(store.focusDraft(firstDraft.id, section: .writing))
    XCTAssertTrue(store.focusDraft(secondDraft.id, section: .writing))
    XCTAssertTrue(store.canNavigateBackwardInDraftHistory)
    XCTAssertTrue(store.navigateBackwardInDraftHistory())
    XCTAssertEqual(store.selectedDraftID, firstDraft.id)
    XCTAssertEqual(store.activeProfileID, firstSite.id)
    XCTAssertTrue(store.canNavigateForwardInDraftHistory)
    XCTAssertTrue(store.navigateForwardInDraftHistory())
    XCTAssertEqual(store.selectedDraftID, secondDraft.id)
    XCTAssertEqual(store.activeProfileID, secondSite.id)
  }

  func testCreateProfileSwitchesToAnEmptySiteProfile() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let originalProfileID = store.activeProfileID

    let profile = store.createProfile(named: "工程站")

    XCTAssertNotEqual(profile.id, originalProfileID)
    XCTAssertEqual(store.activeProfileID, profile.id)
    XCTAssertEqual(store.activeProfile.name, "工程站")
    XCTAssertEqual(store.visibleDrafts, [])
    XCTAssertNil(store.selectedDraftID)
    XCTAssertNil(store.selectedDraft)
    XCTAssertNil(store.publishPackage)
    XCTAssertNil(store.localPublishPreview)
  }

  func testEmptyProfileWithRepositoryStillCreatesLocalPreviewPlan() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try temporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let profile = store.createProfile(named: "工程站")
    store.updateActiveProfile { profile in
      profile.siteKind = .astro
      profile.localRepositoryRootPath = rootURL.path
    }

    store.refreshPublishPreview()

    let plan = try XCTUnwrap(store.localSitePreviewPlan)
    XCTAssertEqual(store.activeProfileID, profile.id)
    XCTAssertEqual(plan.rootPath, rootURL.path)
    XCTAssertEqual(URL(fileURLWithPath: plan.executablePath).lastPathComponent, "npm")
    XCTAssertEqual(plan.arguments, ["run", "dev"])
    XCTAssertEqual(plan.previewURL.absoluteString, "http://127.0.0.1:4321")
  }

  func testEnsureEditableDraftSelectedCreatesDraftForEmptyProfile() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let profile = store.createProfile(named: "工程站")
    store.setSelectedSection(.images)

    let draft = try XCTUnwrap(store.ensureEditableDraftSelected())

    XCTAssertEqual(draft.siteProfileID, profile.id)
    XCTAssertEqual(store.visibleDrafts.map(\.id), [draft.id])
    XCTAssertEqual(store.selectedDraftID, draft.id)
    XCTAssertEqual(store.selectedDraft?.id, draft.id)
    XCTAssertEqual(store.selectedSection, .images)
    XCTAssertTrue(draft.bodyMarkdown.contains("从这里开始写作"))
  }

  func testEnsureEditableDraftSelectedNormalizesStaleSelection() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let fallbackDraftID = try XCTUnwrap(store.visibleDrafts.first?.id)
    let staleDraftID = UUID()
    store.setSelectedDraftID(staleDraftID)

    XCTAssertEqual(store.selectedDraft?.id, fallbackDraftID)

    let draft = try XCTUnwrap(store.ensureEditableDraftSelected())

    XCTAssertEqual(draft.id, fallbackDraftID)
    XCTAssertEqual(store.selectedDraftID, fallbackDraftID)
  }

  func testUpdateDraftMarksWorkbenchUnsavedUntilExplicitSave() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    let draft = try XCTUnwrap(store.ensureEditableDraftSelected())
    store.save()
    await store.waitForPendingSave()

    var updated = draft
    updated.bodyMarkdown += "\nabc123"
    store.updateDraft(updated)

    XCTAssertEqual(store.lastSaveStatus, "有未保存修改")

    store.save()
    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertTrue(reloaded.drafts.first { $0.id == draft.id }?.bodyMarkdown.contains("abc123") == true)
  }

  func testDeleteDraftByIDRemovesTargetDraftAndPreservesValidSelection() async throws {
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    let profile = store.activeProfile
    let first = ArticleDraft(siteProfileID: profile.id, title: "First", slug: "first")
    let second = ArticleDraft(siteProfileID: profile.id, title: "Second", slug: "second")
    let third = ArticleDraft(siteProfileID: profile.id, title: "Third", slug: "third")
    store.setDrafts([first, second, third])
    store.setSelectedDraftID(first.id)

    store.deleteDraft(id: second.id)

    XCTAssertEqual(store.drafts.map(\.id), [first.id, third.id])
    XCTAssertEqual(store.selectedDraftID, first.id)

    store.deleteDraft(id: first.id)

    XCTAssertEqual(store.drafts.map(\.id), [third.id])
    XCTAssertEqual(store.selectedDraftID, third.id)
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.drafts.map(\.id), [third.id])
  }

  func testDeleteProfileKeepsRecentlyDeletedDraftsAvailableForUndo() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let originalProfileID = store.activeProfileID
    let deletedProfile = store.createProfile(named: "待删除站点")
    store.createDraft()
    let draft = try XCTUnwrap(store.selectedDraft)
    let snippet = try XCTUnwrap(MarkdownSnippetLibraryService.savingCustomSnippet(
      title: "待恢复片段",
      detail: "",
      kind: .snippet,
      markdown: "恢复内容",
      siteProfileID: deletedProfile.id,
      in: []
    ).first)
    store.saveCustomMarkdownSnippet(snippet)

    XCTAssertEqual(store.activeProfileDraftCount, 1)
    let recentlyDeleted = try XCTUnwrap(store.deleteActiveProfile())

    XCTAssertEqual(recentlyDeleted.profile.id, deletedProfile.id)
    XCTAssertEqual(recentlyDeleted.draftCount, 1)
    XCTAssertEqual(recentlyDeleted.customMarkdownSnippets.map(\.id), [snippet.id])
    XCTAssertFalse(store.profiles.contains { $0.id == deletedProfile.id })
    XCTAssertFalse(store.drafts.contains { $0.id == draft.id })
    XCTAssertFalse(store.customMarkdownSnippets.contains { $0.id == snippet.id })
    XCTAssertEqual(store.activeProfileID, originalProfileID)

    XCTAssertTrue(store.restoreRecentlyDeletedProfile())
    XCTAssertEqual(store.activeProfileID, deletedProfile.id)
    XCTAssertTrue(store.drafts.contains { $0.id == draft.id })
    XCTAssertTrue(store.customMarkdownSnippets.contains { $0.id == snippet.id })
    XCTAssertNil(store.recentlyDeletedProfile)
  }

  func testRelatedArticleSuggestionsReturnCurrentDraftOutgoingLinksOnly() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let profile = store.activeProfile
    let sourceID = UUID()
    let targetID = UUID()
    let unrelatedID = UUID()
    let source = ArticleDraft(
      id: sourceID,
      siteProfileID: profile.id,
      title: "Mac AI 发布",
      slug: "mac-ai-publishing",
      tags: ["AI", "Mac"],
      draft: false,
      bodyMarkdown: "正文还没有链接。",
      status: .published
    )
    let target = ArticleDraft(
      id: targetID,
      siteProfileID: profile.id,
      title: "Mac SEO 预览",
      slug: "mac-seo-preview",
      tags: ["AI"],
      draft: false,
      bodyMarkdown: "目标正文。",
      status: .published
    )
    let unrelated = ArticleDraft(
      id: unrelatedID,
      siteProfileID: profile.id,
      title: "独立主题",
      slug: "standalone",
      tags: ["Release"],
      draft: false,
      bodyMarkdown: "无关正文。",
      status: .published
    )
    store.setDrafts([source, target, unrelated])
    await store.refreshSiteMaintenanceSnapshot(force: true)

    let suggestions = store.relatedArticleSuggestions(for: source)

    XCTAssertEqual(suggestions.map(\.sourceDraftID), [sourceID])
    XCTAssertEqual(suggestions.map(\.targetDraftID), [targetID])
    XCTAssertTrue(suggestions.first?.targetPath.hasSuffix("/mac-seo-preview/") ?? false)
    XCTAssertEqual(store.relatedArticleSuggestions(for: unrelated), [])
  }

  func testSelectProfileRestoresDraftSelectionInsideThatProfile() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let firstProfileID = store.activeProfileID
    let firstDraftID = try XCTUnwrap(store.visibleDrafts.first?.id)

    let secondProfile = store.createProfile(named: "Second")
    store.createDraft()
    let secondDraftID = try XCTUnwrap(store.selectedDraftID)

    store.selectProfile(firstProfileID)
    XCTAssertEqual(store.selectedDraftID, firstDraftID)
    XCTAssertTrue(store.visibleDrafts.allSatisfy { $0.siteProfileID == firstProfileID })

    store.selectProfile(secondProfile.id)
    XCTAssertEqual(store.selectedDraftID, secondDraftID)
    XCTAssertTrue(store.visibleDrafts.allSatisfy { $0.siteProfileID == secondProfile.id })
  }

  func testActiveProfileReleaseLedgerExcludesOtherSiteRecordsAndKeepsLegacyRecords() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let firstProfileID = store.activeProfileID
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentStatusEndpointURL = "https://status.example.com/first"
    }

    let secondProfile = store.createProfile(named: "Second")
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .custom
      profile.deploymentStatusEndpointURL = "https://status.example.com/second"
    }
    store.selectProfile(firstProfileID)

    let activeRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "First Site Publish",
      summary: "first",
      siteProfileID: firstProfileID,
      commitSHA: "first-commit",
      createdAt: Date(timeIntervalSince1970: 3)
    )
    let otherRecord = ReleaseRecord(
      id: UUID(),
      kind: .remoteDirectCommit,
      title: "Second Site Publish",
      summary: "second",
      siteProfileID: secondProfile.id,
      commitSHA: "second-commit",
      createdAt: Date(timeIntervalSince1970: 4)
    )
    let legacyRecord = ReleaseRecord(
      id: UUID(),
      kind: .localWrite,
      title: "Legacy Local Write",
      summary: "legacy",
      siteProfileID: nil,
      createdAt: Date(timeIntervalSince1970: 1)
    )
    store.setReleaseRecords([otherRecord, activeRecord, legacyRecord])
    store.setDeploymentStatusSnapshots([
      activeRecord.id: DeploymentStatusSnapshot(
        profileID: firstProfileID,
        releaseRecordID: activeRecord.id,
        provider: .custom,
        level: .running,
        title: "First running",
        message: "first is deploying",
        siteURLText: "https://first.example.com",
        checkedAt: Date(timeIntervalSince1970: 5),
        signals: []
      ),
      otherRecord.id: DeploymentStatusSnapshot(
        profileID: secondProfile.id,
        releaseRecordID: otherRecord.id,
        provider: .custom,
        level: .failed,
        title: "Second failed",
        message: "second failed",
        siteURLText: "https://second.example.com",
        checkedAt: Date(timeIntervalSince1970: 6),
        signals: []
      ),
    ])

    let firstLedger = store.activeProfileReleaseLedger

    XCTAssertEqual(firstLedger.entries.map(\.id), [activeRecord.id, legacyRecord.id])
    XCTAssertEqual(firstLedger.summary.totalCount, 2)
    XCTAssertEqual(firstLedger.summary.failedCount, 0)
    XCTAssertEqual(firstLedger.summary.localPendingCount, 1)
    XCTAssertEqual(firstLedger.deploymentOverview.failedDeploymentCount, 0)
    XCTAssertEqual(store.activeProfileDeploymentStatusSnapshots.keys.sorted { $0.uuidString < $1.uuidString }, [activeRecord.id])
    XCTAssertEqual(store.deploymentPollingEligibleRecords.map(\.id), [activeRecord.id])

    store.selectProfile(secondProfile.id)

    let secondLedger = store.activeProfileReleaseLedger

    XCTAssertEqual(secondLedger.entries.map(\.id), [otherRecord.id, legacyRecord.id])
    XCTAssertEqual(secondLedger.summary.failedCount, 1)
    XCTAssertEqual(secondLedger.deploymentOverview.failedDeploymentCount, 1)
    XCTAssertEqual(store.deploymentPollingEligibleRecords, [])
  }

  func testDuplicateAndDeleteActiveProfileKeepDraftsScopedToExistingProfiles() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let originalProfileID = store.activeProfileID

    let duplicate = store.duplicateActiveProfile()
    XCTAssertEqual(store.activeProfileID, duplicate.id)
    XCTAssertTrue(store.activeProfile.name.hasPrefix("个人网站 副本"))
    XCTAssertEqual(store.visibleDrafts, [])

    store.createDraft()
    XCTAssertTrue(store.drafts.contains { $0.siteProfileID == duplicate.id })

    store.deleteActiveProfile()
    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.activeProfileID, originalProfileID)
    XCTAssertFalse(store.drafts.contains { $0.siteProfileID == duplicate.id })
  }

  func testCannotDeleteTheLastProfile() throws {
    let store = try TestWorkbenchFactory.makeStore()

    store.deleteActiveProfile()

    XCTAssertEqual(store.profiles.count, 1)
    XCTAssertEqual(store.publishActionMessage, "至少需要保留一个站点配置。")
  }

  func testCanDeferPreflightRefreshWhileEditing() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var draft = try XCTUnwrap(store.selectedDraft)
    store.setAutomaticallyRefreshPreflightOnEdit(false)
    store.setPreflightIssues([])

    draft.title = ""
    draft.slug = ""
    store.updateDraft(draft)

    XCTAssertEqual(store.preflightIssues, [])

    store.runPreflight()

    XCTAssertTrue(store.preflightIssues.contains { $0.field == "title" })
    XCTAssertTrue(store.preflightIssues.contains { $0.field == "slug" })
  }

  func testApplyDetectedRepositoryRemoteUpdatesReviewConfiguration() throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: "/tmp/site",
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 1,
      imageFileCount: 0,
      branchStatus: RepositoryBranchStatus(branchName: "production", upstreamName: "origin/production"),
      originRemote: RepositoryRemote(
        remoteURL: "https://gitlab.com/group/site.git",
        provider: .gitlab,
        repositoryBaseURL: "https://gitlab.com",
        owner: "group",
        name: "site"
      ),
      changedFiles: [],
      preflightIssues: []
    ))

    store.applyDetectedRepositoryRemote()

    XCTAssertEqual(store.activeProfile.repositoryProvider, .gitlab)
    XCTAssertEqual(store.activeProfile.repositoryBaseURL, "https://gitlab.com")
    XCTAssertEqual(store.activeProfile.repoOwner, "group")
    XCTAssertEqual(store.activeProfile.repoName, "site")
    XCTAssertEqual(store.activeProfile.branch, "production")
    XCTAssertEqual(store.publishActionMessage, "已使用 GitLab group/site 更新 PR/MR 配置。")
  }

  func testSetRepositoryProviderUpdatesDefaultBaseURL() throws {
    let store = try TestWorkbenchFactory.makeStore()

    XCTAssertEqual(store.activeProfile.repositoryProvider, .github)
    XCTAssertEqual(store.activeProfile.repositoryBaseURL, RepositoryProvider.github.defaultBaseURL)

    store.setRepositoryProvider(.gitlab)

    XCTAssertEqual(store.activeProfile.repositoryProvider, .gitlab)
    XCTAssertEqual(store.activeProfile.repositoryBaseURL, RepositoryProvider.gitlab.defaultBaseURL)
  }

  func testSetRepositoryProviderPreservesCustomBaseURL() throws {
    let store = try TestWorkbenchFactory.makeStore()
    store.updateActiveProfile { profile in
      profile.repositoryBaseURL = "https://git.example.com"
    }

    store.setRepositoryProvider(.gitlab)

    XCTAssertEqual(store.activeProfile.repositoryProvider, .gitlab)
    XCTAssertEqual(store.activeProfile.repositoryBaseURL, "https://git.example.com")
  }

  func testDraftScopedPublishingUsesDraftProfileWhenActiveProfileDiffers() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let originalProfileID = store.activeProfileID

    _ = store.createProfile(named: "Astro Site")
    store.applySiteKindDefaults(.astro)
    let astroProfileID = store.activeProfileID
    let draft = ArticleDraft(
      siteProfileID: astroProfileID,
      title: "Astro Article",
      date: fixedDate(),
      slug: "astro-article",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for draft-scoped publishing helpers."
    )
    store.setDrafts(store.drafts + [draft])

    store.selectProfile(originalProfileID)

    let package = store.publishingPackage(for: draft)
    let attachment = store.makeAttachment(
      from: URL(fileURLWithPath: "/tmp/cover.jpg"),
      draft: draft
    )
    let prompt = store.publishingAIPrompt(for: draft)

    XCTAssertEqual(store.activeProfileID, originalProfileID)
    XCTAssertEqual(package.markdownPath, "src/content/blog/astro-article.mdx")
    XCTAssertEqual(attachment.repositoryPath, "public/images/2026/cover.jpg")
    XCTAssertTrue(prompt.contains("发布路径：src/content/blog/astro-article.mdx"))
  }

  func testFocusDraftSwitchesProfileAndRefreshesPublishingContext() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let originalProfileID = store.activeProfileID

    _ = store.createProfile(named: "Jekyll Site")
    store.applySiteKindDefaults(.jekyll)
    let jekyllProfileID = store.activeProfileID
    let draft = ArticleDraft(
      siteProfileID: jekyllProfileID,
      title: "Jekyll Article",
      date: fixedDate(),
      slug: "jekyll-article",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for focused draft publishing context."
    )
    store.setDrafts(store.drafts + [draft])
    store.selectProfile(originalProfileID)

    let didFocus = store.focusDraft(draft.id, section: .contentHealth)
    await store.publishingStore.waitForPublishPreviewRefresh()

    XCTAssertTrue(didFocus)
    XCTAssertEqual(store.activeProfileID, jekyllProfileID)
    XCTAssertEqual(store.selectedDraftID, draft.id)
    XCTAssertEqual(store.selectedSection, .contentHealth)
    XCTAssertEqual(store.publishPackage?.markdownPath, "_posts/2026-08-29-jekyll-article.md")
  }

  func testWritingIgnoresStalePackageThenUsesSelectedDraftRepositoryRoot() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let originalProfileID = store.activeProfileID
    let astroRoot = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: astroRoot)
    }

    var astroProfile = store.createProfile(named: "Astro Site")
    astroProfile.applyPublishingDefaults(for: .astro)
    astroProfile.rememberLocalRepositoryRoot(astroRoot)
    store.updateActiveProfile(astroProfile)

    let draft = ArticleDraft(
      siteProfileID: astroProfile.id,
      title: "Astro Write",
      date: fixedDate(),
      slug: "astro-write",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for draft-scoped local repository writes."
    )
    store.setDrafts(store.drafts + [draft])
    store.selectProfile(originalProfileID)
    _ = store.focusDraft(draft.id)
    await store.scanRepositoryAsync()
    store.selectProfile(originalProfileID)
    store.refreshPublishPreview(for: draft)

    XCTAssertEqual(store.localPublishReadiness?.writeReadiness, .needsReview)
    XCTAssertEqual(store.localPublishReadiness?.canWrite, true)
    XCTAssertEqual(store.localPublishReadiness?.commitReadiness, .blocked)
    XCTAssertTrue(store.localPublishReadiness?.commitBlockingIssues.contains { $0.title == "未发现 .git" } == true)

    await store.writeSelectedDraftToLocalRepository()

    let writtenURL = astroRoot.appendingPathComponent("src/content/blog/astro-write.mdx")
    XCTAssertEqual(store.activeProfileID, originalProfileID)
    XCTAssertNotEqual(store.selectedDraftID, draft.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL.path))

    XCTAssertTrue(store.focusDraft(draft.id))
    await store.writeSelectedDraftToLocalRepository()

    XCTAssertEqual(store.activeProfileID, astroProfile.id)
    XCTAssertEqual(store.selectedDraftID, draft.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: writtenURL.path))
    XCTAssertTrue(store.releaseRecords.first?.changedPaths.contains("src/content/blog/astro-write.mdx") == true)
  }

  func testSingleDraftPublishCommandsRequireCommitReadiness() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Command Ready",
      date: fixedDate(),
      slug: "command-ready",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for command readiness to be driven by the repository state."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.refreshPublishPreview(for: draft)

    XCTAssertEqual(store.localPublishReadiness?.commitReadiness, .blocked)
    XCTAssertNil(store.localCommitCommandForSelectedDraft())
    XCTAssertTrue(store.reviewBranchCommandsForSelectedDraft().isEmpty)

    try git(["init", "-b", "main"], rootURL: rootURL)
    await store.scanRepositoryAsync()

    XCTAssertEqual(store.localPublishReadiness?.canCommit, true)
    XCTAssertTrue(store.localCommitCommandForSelectedDraft()?.contains("git add 'content/posts/command-ready.md'") == true)
    XCTAssertFalse(store.reviewBranchCommandsForSelectedDraft().isEmpty)

    let package = try XCTUnwrap(store.publishPackage)
    let markdownContent = try XCTUnwrap(package.markdownFile?.content)
    try markdownContent.write(
      to: rootURL.appendingPathComponent("content/posts/command-ready.md"),
      atomically: true,
      encoding: .utf8
    )

    XCTAssertNil(store.localCommitCommandForSelectedDraft())
    XCTAssertTrue(store.reviewBranchCommandsForSelectedDraft().isEmpty)
    XCTAssertEqual(store.localPublishReadiness?.commitReadiness, .unchanged)
  }

  func testRepositoryReportAccessorDoesNotTriggerImplicitScan() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)

    XCTAssertNil(store.repositoryReport(for: profile))
    XCTAssertNil(store.repositoryReport)
  }

  func testLocalRepositoryMutationsAreSingleFlight() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let first = try XCTUnwrap(
      store.publishingStore.beginLocalRepositoryMutation(profile: store.activeProfile)
    )

    XCTAssertTrue(store.isLocalRepositoryMutationRunning)
    XCTAssertNil(store.publishingStore.beginLocalRepositoryMutation(profile: store.activeProfile))

    store.publishingStore.finishLocalRepositoryMutation(first)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
    let second = try XCTUnwrap(
      store.publishingStore.beginLocalRepositoryMutation(profile: store.activeProfile)
    )
    store.publishingStore.finishLocalRepositoryMutation(second)
    XCTAssertFalse(store.isLocalRepositoryMutationRunning)
  }

  func testRepositoryBackupPurposeDoesNotBlockCommitReadinessOnMissingStaticSiteRoots() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.purpose = .publishing
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Backup Commit",
      date: Date(timeIntervalSince1970: 1_700_000_000),
      slug: "backup-commit",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so readiness is driven by profile purpose and static site roots."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    await store.scanRepositoryAsync()

    XCTAssertEqual(store.localPublishReadiness?.commitReadiness, .blocked)
    XCTAssertTrue(store.localPublishReadiness?.commitBlockingIssues.contains { $0.title == "内容目录不存在" } == true)

    profile.purpose = .repositoryBackup
    store.updateActiveProfile(profile)
    await store.scanRepositoryAsync()

    XCTAssertEqual(store.localPublishReadiness?.commitReadiness, .ready)
    XCTAssertFalse(store.localPublishReadiness?.commitBlockingIssues.contains { $0.title == "内容目录不存在" } == true)
  }

  func testPreferredPublishStrategyDirectCommitsOnCurrentBranch() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.repositoryPublishStrategy = .direct
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preferred Direct",
      date: fixedDate(),
      slug: "preferred-direct",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for preferred direct publishing."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    await store.scanRepositoryAsync()
    store.refreshPublishPreview(for: draft)

    await store.commitSelectedDraftUsingPreferredStrategy()

    XCTAssertEqual(store.localGitPublishResult?.mode, .directCommit)
    XCTAssertEqual(store.localGitPublishResult?.branchName, "main")
    XCTAssertEqual(store.releaseRecords.first?.kind, .directCommit)
    XCTAssertEqual(store.drafts.first?.repositoryPath, "content/posts/preferred-direct.md")
    XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], rootURL: rootURL), "main")
  }

  func testPreferredPublishStrategyCreatesReviewBranch() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.repositoryPublishStrategy = .reviewRequest
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Preferred Review",
      date: fixedDate(),
      slug: "preferred-review",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for preferred review branch publishing."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    await store.scanRepositoryAsync()
    store.refreshPublishPreview(for: draft)

    await store.commitSelectedDraftUsingPreferredStrategy()

    let result = try XCTUnwrap(
      store.localGitPublishResult,
      store.publishActionMessage ?? "本地 Review 提交未返回结果"
    )
    XCTAssertEqual(result.mode, .reviewBranch)
    XCTAssertEqual(result.branchName, "publish/preferred-review-20260829")
    XCTAssertEqual(store.releaseRecords.first?.kind, .reviewBranch)
    XCTAssertNil(store.drafts.first?.repositoryPath)
    XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], rootURL: rootURL), result.branchName)
  }

  func testWritingPackageBlocksPreflightErrorsBeforeRepositoryWrite() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)

    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = ""
    draft.slug = "blocked-write"
    draft.draft = false
    draft.bodyMarkdown = "This body is intentionally long enough so the blocking write test is driven by the title error."
    store.updateDraft(draft)
    store.refreshPublishPreview(for: draft)

    XCTAssertEqual(store.localPublishReadiness?.writeReadiness, .blocked)
    XCTAssertTrue(store.localPublishReadiness?.writeBlockingIssues.contains {
      $0.title == CoreL10n.text("标题为空")
    } == true)

    let initialRecordCount = store.releaseRecords.count
    await store.writeSelectedDraftToLocalRepository()

    let writtenURL = rootURL.appendingPathComponent("content/posts/blocked-write.md")
    XCTAssertFalse(FileManager.default.fileExists(atPath: writtenURL.path))
    XCTAssertEqual(store.releaseRecords.count, initialRecordCount)
    XCTAssertTrue(store.publishActionMessage?.contains("已停止写入") == true)
    XCTAssertTrue(store.publishActionMessage?.contains(CoreL10n.text("标题为空")) == true)
  }

  func testWritingPackageBlocksMissingImageSourceBeforePartialMarkdownWrite() async throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)

    let attachment = DraftAttachment(
      originalFilename: "missing-cover.jpg",
      relativePublishPath: "/images/2026/missing-cover.jpg",
      repositoryPath: "static/images/2026/missing-cover.jpg",
      altText: "Missing cover",
      sourceFilePath: rootURL.appendingPathComponent("missing-cover.jpg").path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Missing Image Source",
      slug: "missing-image-source",
      draft: false,
      bodyMarkdown: """
      This body is intentionally long enough so the local publish write test is driven by the missing image source.

      ![Missing cover](/images/2026/missing-cover.jpg)
      """,
      attachments: [attachment]
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.refreshPublishPreview(for: draft)

    XCTAssertEqual(store.localPublishReadiness?.writeReadiness, .blocked)
    XCTAssertTrue(
      store.localPublishReadiness?.writeBlockingIssues.contains {
        $0.title == CoreL10n.text("图片源文件缺失")
      } == true
    )

    let initialRecordCount = store.releaseRecords.count
    await store.writeSelectedDraftToLocalRepository()

    let markdownURL = rootURL.appendingPathComponent("content/posts/missing-image-source.md")
    let imageURL = rootURL.appendingPathComponent("static/images/2026/missing-cover.jpg")
    XCTAssertFalse(FileManager.default.fileExists(atPath: markdownURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    XCTAssertEqual(store.releaseRecords.count, initialRecordCount)
    XCTAssertTrue(store.publishActionMessage?.contains("已停止写入") == true)
    XCTAssertTrue(store.publishActionMessage?.contains(CoreL10n.text("图片源文件缺失")) == true)
  }

  func testPublishReadinessWarnsWhenRemoteChangedFileMatchesPackagePath() throws {
    let store = try TestWorkbenchFactory.makeStore()
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }

    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Remote Same Path",
      slug: "remote-same-path",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so remote same-path readiness is driven by upstream changes."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: profile.siteKind,
      expectedKind: profile.siteKind,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [],
      remoteChangedFiles: [
        RepositoryChangedFile(status: "M", path: "content/posts/remote-same-path.md", kind: .modified)
      ],
      preflightIssues: []
    ))

    store.refreshPublishPreview(for: draft)

    XCTAssertEqual(store.localPublishReadiness?.writeReadiness, .needsReview)
    XCTAssertEqual(store.localPublishReadiness?.commitReadiness, .needsReview)
    XCTAssertTrue(store.localPublishReadiness?.warningIssues.contains { issue in
      issue.title == "远端同路径变更"
        && issue.message.contains("content/posts/remote-same-path.md")
    } == true)
  }
}
