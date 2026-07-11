import Foundation
import XCTest
@testable import PublishingWorkbenchCore

extension WorkbenchStoreProfileTests {
  func testOnlineDirectPublishBlocksRemoteSamePathConflictBeforeCallingAPI() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport)
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Online Direct Conflict",
      slug: "online-direct-conflict",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so online API publish conflict handling is driven by upstream changes."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: "/tmp/site",
      detectedKind: profile.siteKind,
      expectedKind: profile.siteKind,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [],
      remoteChangedFiles: [
        RepositoryChangedFile(status: "M", path: "content/posts/online-direct-conflict.md", kind: .modified)
      ],
      preflightIssues: []
    ))
    store.setPublishPackage(store.publishingPackage(for: draft))

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
    let preview = store.remoteRepositoryPublishPreview(for: draft)
    XCTAssertEqual(preview.remoteConflictPaths, ["content/posts/online-direct-conflict.md"])
    XCTAssertEqual(preview.readiness, .blocked)
    XCTAssertFalse(preview.canPublish)
    XCTAssertTrue(preview.checklistMarkdown.contains("## 远端冲突预览"))
    XCTAssertTrue(store.publishActionMessage?.contains("已停止线上发布") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("远端同路径变更") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("content/posts/online-direct-conflict.md") == true)

    let cachedPreview = try XCTUnwrap(store.remotePublishPreviewSnapshot)
    XCTAssertEqual(cachedPreview.changedPaths, preview.changedPaths)
    XCTAssertEqual(cachedPreview.remoteConflictPaths, preview.remoteConflictPaths)
  }

  func testOnlineDirectPublishMarksDraftPublishedAndRecordsDeploymentStatus() async throws {
    let publishTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"content":{"path":"content/posts/online-direct-success.md"},"commit":{"sha":"online-direct-commit"}}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 200, json: #"{"status":"ok","message":"Site is live"}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: publishTransport),
      deploymentStatusService: DeploymentStatusService(transport: deploymentTransport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/site"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))
    store.applyProEntitlement(source: .localOverride)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Online Direct Success",
      slug: "online-direct-success",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for online direct success publishing.",
      status: .ready
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))
    store.setRepositoryAutoSyncState(
      RepositoryAutoSyncState(
        status: .scanned,
        lastRunAt: Date(timeIntervalSince1970: 1_800_000_000),
        nextRunAt: Date(timeIntervalSince1970: 1_800_000_300),
        remoteChangedFileCount: 2,
        remoteChangedPaths: [
          "content/posts/online-direct-success.md",
          "content/posts/remote-only.md",
        ],
        importableRemoteArticleCount: 2,
        nonArticleRemoteChangedFileCount: 0,
        message: "自动同步已扫描：发现 2 个远端待拉取变化。"
      )
    )

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()

    XCTAssertEqual(result?.commitSHA, "online-direct-commit")
    XCTAssertEqual(store.drafts.first?.status, .published)
    XCTAssertFalse(store.drafts.first?.draft ?? true)
    let record = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(record.kind, .remoteDirectCommit)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .success)
    XCTAssertEqual(store.releaseLedger.entries.first?.status, .succeeded)
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedPaths, ["content/posts/remote-only.md"])
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedFileCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.importableRemoteArticleCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishProvider, .github)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishMode, .directCommit)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishPaths, ["content/posts/online-direct-success.md"])
    XCTAssertTrue(store.repositoryAutoSyncState.message.contains("已从远端同步队列移除 1 个同路径项"))
    XCTAssertTrue(store.repositoryAutoSyncReviewMarkdown.contains("## 最近线上写入"))
    XCTAssertTrue(store.repositoryAutoSyncReviewMarkdown.contains("- content/posts/online-direct-success.md"))

    let publishRequests = await publishTransport.capturedRequests()
    XCTAssertEqual(publishRequests.map(\.httpMethod), ["GET", "PUT"])
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertEqual(deploymentRequests.count, 1)
    XCTAssertEqual(deploymentRequests.first?.url?.absoluteString, "https://status.example.com/site")
  }

  func testOnlineReviewPublishWaitsForMergeWithoutDeploymentStatusRefresh() async throws {
    let publishTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-sha"}}"#),
      workbenchRemoteResponse(json: #"{"ref":"refs/heads/publish/online-review-20260829","object":{"sha":"base-sha"}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"content":{"path":"content/posts/online-review.md"},"commit":{"sha":"review-commit-sha"}}"#),
      workbenchRemoteResponse(json: #"{"html_url":"https://github.com/owner/site/pull/12"}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 200, json: #"{"status":"ok","message":"Main site is still live"}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: publishTransport),
      deploymentStatusService: DeploymentStatusService(transport: deploymentTransport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/site"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))
    store.applyProEntitlement(source: .localOverride)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Online Review",
      date: fixedDate(),
      slug: "online-review",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for online review publishing to create a PR without deployment verification."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()

    XCTAssertEqual(result?.mode, .reviewRequest)
    XCTAssertEqual(result?.reviewURL, "https://github.com/owner/site/pull/12")
    let record = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(record.kind, .remoteReviewRequest)
    XCTAssertEqual(record.reviewURL, "https://github.com/owner/site/pull/12")
    XCTAssertNil(store.deploymentStatusSnapshot(for: record))
    XCTAssertEqual(store.activeProfileReleaseLedger.entries.first?.status, .pendingReview)
    XCTAssertEqual(store.activeProfileReleaseLedger.summary.reviewPendingCount, 1)
    XCTAssertEqual(store.activeProfileReleaseLedger.deploymentOverview.checkedRecordCount, 0)

    let publishRequests = await publishTransport.capturedRequests()
    XCTAssertEqual(publishRequests.map(\.httpMethod), ["GET", "POST", "GET", "PUT", "POST"])
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertEqual(deploymentRequests.count, 0)
  }

  func testRemoteRollbackCreatesRollbackRecordFromReleaseHistory() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"sha":"published-sha","tree":{"sha":"published-tree"},"parents":[{"sha":"parent-sha"}]}"#),
      workbenchRemoteResponse(json: #"{"sha":"parent-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"grandparent-sha"}]}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"published-sha"}}"#),
      workbenchRemoteResponse(json: #"{"sha":"rollback-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"published-sha"}]}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"rollback-sha"}}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 200, json: #"{"status":"ok","message":"Rollback commit is live"}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      deploymentStatusService: DeploymentStatusService(transport: deploymentTransport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/rollback"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.applyProEntitlement(source: .localOverride)

    let original = ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "线上提交：Rollback Me",
      summary: "GitHub · main · 1 个文件 · published",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftTitle: "Rollback Me",
      markdownPath: "content/posts/rollback-me.md",
      changedPaths: ["content/posts/rollback-me.md"],
      repositoryProvider: .github,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: "owner",
      repoName: "site",
      branchName: "main",
      targetBranch: "main",
      commitSHA: "published-sha"
    )
    store.setReleaseRecords([original])

    let result = await store.rollbackRemoteRelease(original)

    XCTAssertEqual(result?.rollbackCommitSHA, "rollback-sha")
    XCTAssertEqual(store.remoteRepositoryRollbackResult?.rollbackCommitSHA, "rollback-sha")
    XCTAssertEqual(store.publishActionMessage, "线上回滚完成：rollback")
    let rollbackRecord = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(rollbackRecord.kind, .remoteRollback)
    XCTAssertEqual(rollbackRecord.commitSHA, "rollback-sha")
    XCTAssertEqual(rollbackRecord.changedPaths, ["content/posts/rollback-me.md"])
    XCTAssertEqual(store.deploymentStatusSnapshot(for: rollbackRecord)?.level, .success)
    XCTAssertTrue(
      store.deploymentStatusSnapshot(for: rollbackRecord)?.signals.contains {
        $0.message == "Rollback commit is live"
      } == true
    )
    XCTAssertEqual(store.releaseRecords.dropFirst().first?.id, original.id)
    XCTAssertEqual(store.activeProfileReleaseLedger.entries.first?.status, .succeeded)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "PATCH"])
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertEqual(deploymentRequests.count, 1)
    XCTAssertEqual(deploymentRequests.first?.url?.absoluteString, "https://status.example.com/rollback")
  }

  func testRemoteReviewWithdrawalCreatesReleaseRecordFromReleaseHistory() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"state":"closed","html_url":"https://github.com/owner/site/pull/9"}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.applyProEntitlement(source: .localOverride)

    let original = ReleaseRecord(
      kind: .remoteReviewRequest,
      title: "线上 PR/MR：Review Me",
      summary: "GitHub · publish/review-me -> main · 1 个文件",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftTitle: "Review Me",
      markdownPath: "content/posts/review-me.md",
      changedPaths: ["content/posts/review-me.md"],
      repositoryProvider: .github,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: "owner",
      repoName: "site",
      branchName: "publish/review-me",
      targetBranch: "main",
      commitSHA: "review-commit-sha",
      reviewURL: "https://github.com/owner/site/pull/9",
      reviewTitle: "Publish Review Me"
    )
    store.setReleaseRecords([original])

    let result = await store.withdrawRemoteReview(original)

    XCTAssertEqual(result?.reviewNumber, 9)
    XCTAssertEqual(result?.state, "closed")
    XCTAssertEqual(store.remoteRepositoryReviewWithdrawalResult?.reviewURL, "https://github.com/owner/site/pull/9")
    XCTAssertEqual(store.publishActionMessage, "线上 Review 已撤回：#9")
    let withdrawalRecord = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(withdrawalRecord.kind, .remoteReviewWithdrawal)
    XCTAssertEqual(withdrawalRecord.reviewURL, "https://github.com/owner/site/pull/9")
    XCTAssertEqual(withdrawalRecord.branchName, "publish/review-me")
    XCTAssertEqual(withdrawalRecord.targetBranch, "main")
    XCTAssertEqual(store.releaseRecords.dropFirst().first?.id, original.id)
    XCTAssertEqual(store.activeProfileReleaseLedger.entries.first?.status, .succeeded)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["PATCH"])
    XCTAssertEqual(requests.first?.url?.path, "/repos/owner/site/pulls/9")
  }

  func testRemoteRepositoryPublishPreviewSummarizesReviewRequestAndRemoteRisk() throws {
    let store = try TestWorkbenchFactory.makeStore()

    var profile = store.activeProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = RepositoryProvider.gitlab.defaultBaseURL
    profile.repoOwner = "group"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .gitlab,
      repositoryName: "group/site",
      apiBaseURL: "https://gitlab.com/api/v4",
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitLab Token 具备项目写入权限。"
    ))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Online Review Preview",
      slug: "online-review-preview",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for remote preview coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: "/tmp/site",
      detectedKind: profile.siteKind,
      expectedKind: profile.siteKind,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [],
      remoteChangedFiles: [
        RepositoryChangedFile(status: "M", path: "content/posts/online-review-preview.md", kind: .modified)
      ],
      preflightIssues: []
    ))

    let preview = store.remoteRepositoryPublishPreview(for: draft)

    XCTAssertEqual(preview.provider, .gitlab)
    XCTAssertEqual(preview.repositoryName, "group/site")
    XCTAssertEqual(preview.mode, .reviewRequest)
    XCTAssertEqual(preview.targetBranch, "main")
    XCTAssertTrue(preview.branchName.hasPrefix("publish/online-review-preview-"))
    XCTAssertEqual(preview.changedPaths, ["content/posts/online-review-preview.md"])
    XCTAssertEqual(preview.remoteConflictPaths, ["content/posts/online-review-preview.md"])
    XCTAssertEqual(preview.accessSummary, "Token 可写")
    XCTAssertEqual(preview.readiness, .ready)
    XCTAssertTrue(preview.canPublish)
    XCTAssertTrue(preview.warningIssues.contains { $0.title == "远端同路径变更" })
    XCTAssertTrue(preview.blockingIssues.isEmpty)
    XCTAssertTrue(preview.checklistMarkdown.contains("# GitHub/GitLab 线上发布核对包"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- 平台：GitLab"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- 发布模式：线上 PR/MR"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [x] 已确认 Token 对 group/site 具备写入权限"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [ ] 已确认远端同路径变更"))
    XCTAssertTrue(preview.checklistMarkdown.contains("## 远端冲突预览"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [警告] 远端同路径变更"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- content/posts/online-review-preview.md"))
  }

  func testRemoteRepositoryPublishPreviewRequiresTokenBeforeOnlinePublish() throws {
    let store = try TestWorkbenchFactory.makeStore()

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: false))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Token Required",
      slug: "token-required",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for online publish preview token coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let preview = store.remoteRepositoryPublishPreview(for: draft)

    XCTAssertEqual(preview.readiness, .needsToken)
    XCTAssertEqual(preview.accessSummary, "未保存 Token")
    XCTAssertFalse(preview.canPublish)
    XCTAssertEqual(preview.changedPaths, ["content/posts/token-required.md"])
    XCTAssertEqual(preview.mode, .directCommit)
    XCTAssertEqual(preview.branchName, "main")
    XCTAssertTrue(preview.checklistMarkdown.contains("- Token：未保存"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [ ] 已保存 GitHub Token"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [ ] 已确认 Token 对 owner/site 具备写入权限"))
  }

  func testRemoteRepositoryPublishPreviewRequiresPermissionCheckBeforePublish() throws {
    let store = try TestWorkbenchFactory.makeStore()

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Permission Check Required",
      slug: "permission-check-required",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for online publish preview permission check coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let preview = store.remoteRepositoryPublishPreview(for: draft)

    XCTAssertEqual(preview.readiness, .needsPermissionCheck)
    XCTAssertEqual(preview.accessSummary, "Token 已保存，尚未检查权限")
    XCTAssertFalse(preview.canPublish)
    XCTAssertTrue(preview.warningIssues.contains { $0.title == "Token 权限未检查" })
  }

  func testSavingRepositoryTokenInvalidatesPreviousPermissionCheck() throws {
    let tokenStore = repositoryTokenStoreForTest()
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }

    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))

    store.saveRepositoryAccessToken("new-github-token")

    XCTAssertNil(store.remoteRepositoryAccessCheck)
    XCTAssertTrue(store.repositoryTokenAvailability.hasToken)
    XCTAssertEqual(store.publishActionMessage, "仓库访问 Token 已保存到 Keychain。")
    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      repositoryTokenStore: tokenStore
    )
    XCTAssertNil(reloaded.remoteRepositoryAccessCheck)
    XCTAssertNil(reloaded.activeRemoteRepositoryAccessCheck)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Token Recheck Required",
      slug: "token-recheck-required",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for repository token permission cache invalidation coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let preview = store.remoteRepositoryPublishPreview(for: draft)

    XCTAssertEqual(preview.readiness, .needsPermissionCheck)
    XCTAssertNil(preview.accessCheck)
    XCTAssertFalse(preview.canPublish)
    XCTAssertEqual(preview.accessSummary, "Token 已保存，尚未检查权限")
    XCTAssertTrue(preview.warningIssues.contains { $0.title == "Token 权限未检查" })
  }

  func testRepositoryPermissionCheckPersistsAcrossRelaunch() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json: #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true,"maintain":false,"admin":false}}"#
      ),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let persistenceURL = try temporaryPersistenceURL()
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Persisted Permission",
      slug: "persisted-permission",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for persisted repository permission check coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let check = await store.checkRepositoryTokenAccess()

    XCTAssertEqual(check?.repositoryName, "owner/site")
    XCTAssertTrue(check?.canWrite == true)
    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      repositoryTokenStore: tokenStore
    )
    XCTAssertTrue(reloaded.repositoryTokenAvailability.hasToken)
    XCTAssertEqual(reloaded.activeRemoteRepositoryAccessCheck?.repositoryName, "owner/site")
    XCTAssertTrue(reloaded.activeRemoteRepositoryAccessCheck?.canWrite == true)

    let preview = reloaded.remoteRepositoryPublishPreview(for: draft)
    XCTAssertEqual(preview.readiness, .ready)
    XCTAssertTrue(preview.canPublish)
    XCTAssertEqual(preview.accessSummary, "Token 可写")
  }

  func testRepositoryPermissionCheckDiscardsResultAfterRepositoryConfigurationChanges() async throws {
    let transport = SuspendedWorkbenchRemoteRepositoryTransport(
      response: workbenchRemoteResponse(
        json: #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true}}"#
      )
    )
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveToken("github-token", for: profile)

    let checkTask = Task { await store.checkRepositoryTokenAccess() }
    await transport.waitUntilRequestArrives()
    var changedProfile = store.activeProfile
    changedProfile.repoName = "different-site"
    store.updateActiveProfile(changedProfile)
    await transport.resume()
    let check = await checkTask.value

    XCTAssertNil(check)
    XCTAssertNil(store.remoteRepositoryAccessCheck)
    XCTAssertFalse(store.isRemoteRepositoryChecking)
  }

  func testRemoteRepositoryPublishPreviewRejectsAccessCheckFromDifferentOwner() throws {
    let store = try TestWorkbenchFactory.makeStore()

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "new-owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "old-owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Owner Switched",
      slug: "owner-switched",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for stale repository owner access-check coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let preview = store.remoteRepositoryPublishPreview(for: draft)

    XCTAssertEqual(preview.repositoryName, "new-owner/site")
    XCTAssertEqual(preview.readiness, .needsPermissionCheck)
    XCTAssertEqual(preview.accessSummary, "Token 已保存，尚未检查权限")
    XCTAssertNil(preview.accessCheck)
    XCTAssertFalse(preview.canPublish)
    XCTAssertNil(store.activeRemoteRepositoryAccessCheck)
    XCTAssertTrue(store.hasStaleRemoteRepositoryAccessCheckForActiveProfile)
  }

  func testRemoteRepositoryPublishPreviewRejectsAccessCheckFromDifferentAPIBaseURL() throws {
    let store = try TestWorkbenchFactory.makeStore()

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://github.enterprise.example/api/v3"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Endpoint Switched",
      slug: "endpoint-switched",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for stale repository API endpoint access-check coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let preview = store.remoteRepositoryPublishPreview(for: draft)

    XCTAssertEqual(preview.repositoryName, "owner/site")
    XCTAssertEqual(preview.readiness, .needsPermissionCheck)
    XCTAssertEqual(preview.accessSummary, "Token 已保存，尚未检查权限")
    XCTAssertNil(preview.accessCheck)
    XCTAssertFalse(preview.canPublish)
    XCTAssertNil(store.activeRemoteRepositoryAccessCheck)
    XCTAssertTrue(store.hasStaleRemoteRepositoryAccessCheckForActiveProfile)
  }

  func testOnlinePublishBlocksMissingPermissionCheckBeforeCallingAPI() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.applyProEntitlement(source: .localOverride)

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Blocked Permission Check",
      slug: "blocked-permission-check",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so permission checks block before online API publishing."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let initialReleaseRecordCount = store.releaseRecords.count
    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    XCTAssertEqual(store.releaseRecords.count, initialReleaseRecordCount)
    XCTAssertEqual(requestCount, 0)
    XCTAssertTrue(store.publishActionMessage?.contains("请先检查 GitHub Token 权限") == true)
  }

  func testBatchRemoteRepositoryPublishPreviewIncludesReviewableRemoteConflicts() throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let store = try TestWorkbenchFactory.makeStore()

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Review Conflict",
      slug: "batch-review-conflict",
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so batch review preview can focus on remote conflict warnings."
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
        RepositoryChangedFile(status: "M", path: "content/posts/batch-review-conflict.md", kind: .modified)
      ],
      preflightIssues: []
    ))
    store.refreshBatchPublishPlan()

    let plan = try XCTUnwrap(store.batchPublishPlan)
    XCTAssertEqual(plan.writableItems, [])
    XCTAssertEqual(plan.remotePublishableItems.map(\.draftID), [draft.id])

    let preview = try XCTUnwrap(store.remoteRepositoryPublishPreview(for: plan))
    let cachedPreview = try XCTUnwrap(store.batchRemotePublishPreviewSnapshot)

    XCTAssertEqual(preview.provider, .github)
    XCTAssertEqual(preview.repositoryName, "owner/site")
    XCTAssertEqual(preview.mode, .reviewRequest)
    XCTAssertEqual(preview.targetBranch, "main")
    XCTAssertTrue(preview.branchName.hasPrefix("publish/batch-"))
    XCTAssertEqual(preview.changedPaths, ["content/posts/batch-review-conflict.md"])
    XCTAssertEqual(preview.remoteConflictPaths, ["content/posts/batch-review-conflict.md"])
    XCTAssertEqual(preview.accessSummary, "Token 可写")
    XCTAssertEqual(preview.readiness, .ready)
    XCTAssertTrue(preview.canPublish)
    XCTAssertTrue(preview.warningIssues.contains { $0.title == "远端同路径变更" })
    XCTAssertTrue(preview.blockingIssues.isEmpty)
    XCTAssertEqual(cachedPreview.changedPaths, preview.changedPaths)
    XCTAssertEqual(cachedPreview.remoteConflictPaths, preview.remoteConflictPaths)
  }

  func testBatchRemoteRepositoryPublishPreviewIncludesWarningsFromEveryPublishableDraft() throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let store = try TestWorkbenchFactory.makeStore()

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))

    let readyDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Ready Draft",
      slug: "batch-ready-draft",
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so the batch preview has one clean article."
    )
    let needsReviewDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Needs Review Draft",
      slug: "batch-needs-review-draft",
      draft: false,
      bodyMarkdown: "Too short."
    )
    store.setDrafts([readyDraft, needsReviewDraft])
    store.setSelectedDraftID(readyDraft.id)
    store.refreshBatchPublishPlan()

    let plan = try XCTUnwrap(store.batchPublishPlan)
    XCTAssertEqual(plan.remotePublishableItems.map(\.draftID), [readyDraft.id, needsReviewDraft.id])

    let preview = try XCTUnwrap(store.remoteRepositoryPublishPreview(for: plan))

    XCTAssertEqual(preview.readiness, .ready)
    XCTAssertTrue(preview.canPublish)
    XCTAssertEqual(
      preview.changedPaths,
      [
        "content/posts/batch-ready-draft.md",
        "content/posts/batch-needs-review-draft.md",
      ]
    )
    XCTAssertTrue(preview.warningIssues.contains { issue in
      issue.title == "Batch Needs Review Draft：正文偏短"
        && issue.message == "正文少于 80 个字符，发布前建议确认内容完整。"
    })
    XCTAssertTrue(preview.blockingIssues.isEmpty)
  }

  func testOnlinePublishBlocksKnownReadOnlyRepositoryTokenBeforeCallingAPI() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport)
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true))
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: false,
      message: "GitHub Token 可读取仓库，但未确认写入权限。"
    ))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Read Only Token",
      slug: "read-only-token",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for read only token blocking."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    XCTAssertEqual(requestCount, 0)
    XCTAssertTrue(store.publishActionMessage?.contains("Token 无写入权限") == true)
  }

  func testCreateGitHubRepositoryForActiveProfileUsesAPIAndUpdatesProfile() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"login":"owner"}"#),
      workbenchRemoteResponse(json: #"{"full_name":"owner/site","default_branch":"main","ssh_url":"git@github.com:owner/site.git","clone_url":"https://github.com/owner/site.git","html_url":"https://github.com/owner/site","private":false}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.name = "Personal Site"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.applyProEntitlement(productID: "test.pro", source: .storeKit)

    let result = await store.createGitHubRepositoryForActiveProfile(privateRepository: false)

    XCTAssertEqual(result?.repositoryName, "owner/site")
    XCTAssertEqual(store.remoteRepositoryCreationResult?.htmlURL, "https://github.com/owner/site")
    XCTAssertEqual(store.activeProfile.repoOwner, "owner")
    XCTAssertEqual(store.activeProfile.repoName, "site")
    XCTAssertEqual(store.repositoryTokenAvailability.hasToken, true)
    XCTAssertTrue(store.publishActionMessage?.contains("GitHub 仓库已创建：owner/site") == true)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/user")
    XCTAssertEqual(requests[1].url?.path, "/user/repos")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
  }

  func testCreateRemoteRepositoryForActiveProfilePreservesCustomGitLabBaseURL() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"id":42,"full_path":"group/subgroup"}"#),
      workbenchRemoteResponse(json: #"{"path_with_namespace":"group/subgroup/site","default_branch":"main","ssh_url_to_repo":"git@gitlab.internal.example:group/subgroup/site.git","http_url_to_repo":"https://gitlab.internal.example/group/subgroup/site.git","web_url":"https://gitlab.internal.example/group/subgroup/site","visibility":"private"}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .gitlab
    profile.repositoryBaseURL = "https://gitlab.internal.example"
    profile.repoOwner = "group/subgroup"
    profile.repoName = "site"
    profile.name = "Self Hosted Site"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("gitlab-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.applyProEntitlement(productID: "test.pro", source: .storeKit)

    let result = await store.createRemoteRepositoryForActiveProfile(privateRepository: true)

    XCTAssertEqual(result?.repositoryName, "group/subgroup/site")
    XCTAssertEqual(store.remoteRepositoryCreationResult?.htmlURL, "https://gitlab.internal.example/group/subgroup/site")
    XCTAssertEqual(store.activeProfile.repositoryProvider, .gitlab)
    XCTAssertEqual(store.activeProfile.repositoryBaseURL, "https://gitlab.internal.example")
    XCTAssertEqual(store.activeProfile.repoOwner, "group/subgroup")
    XCTAssertEqual(store.activeProfile.repoName, "site")
    XCTAssertEqual(store.repositoryTokenAvailability.hasToken, true)
    XCTAssertTrue(store.publishActionMessage?.contains("GitLab 仓库已创建：group/subgroup/site") == true)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests[0].url?.absoluteString, "https://gitlab.internal.example/api/v4/groups/group%2Fsubgroup")
    XCTAssertEqual(requests[1].url?.absoluteString, "https://gitlab.internal.example/api/v4/projects")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
  }

  func testOnlinePublishFailureRecordsOnlyActuallyWrittenPartialPaths() async throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let imageURL = rootURL.appendingPathComponent("partial-cover.png")
    try Data([1, 2, 3, 4]).write(to: imageURL)

    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"content":{"path":"content/posts/partial-failure.md"},"commit":{"sha":"partial-store-commit"}}"#),
      workbenchRemoteResponse(statusCode: 500, json: #"{"message":"server error"}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 200, json: #"{"status":"building","message":"Partial publish deployment is still running"}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      deploymentStatusService: DeploymentStatusService(transport: deploymentTransport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/partial"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))
    store.applyProEntitlement(source: .localOverride)

    let attachment = DraftAttachment(
      originalFilename: "partial-cover.png",
      relativePublishPath: "/images/partial-cover.png",
      repositoryPath: "static/images/partial-cover.png",
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Partial Failure",
      slug: "partial-failure",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for partial online publishing failure coverage.",
      attachments: [attachment]
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    XCTAssertTrue(store.publishActionMessage?.contains("部分完成后失败") == true)
    let record = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(record.kind, .remotePublishFailure)
    XCTAssertEqual(record.changedPaths, ["content/posts/partial-failure.md"])
    XCTAssertEqual(record.commitSHA, "partial-store-commit")
    XCTAssertTrue(record.summary.contains("1 个文件已写入 main"))
    XCTAssertEqual(store.releaseLedger.entries.first?.status, .pendingRemoteRecovery)
    XCTAssertEqual(store.releaseLedger.summary.remoteRecoveryPendingCount, 1)
    XCTAssertEqual(store.releaseLedger.actionItems.first?.kind, .recoverPartialRemotePublish)
    XCTAssertTrue(store.releaseLedger.actionItems.first?.commandLines.contains("git revert --no-edit 'partial-store-commit'") == true)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .running)
    XCTAssertEqual(store.releaseLedger.entries.first?.status, .pendingRemoteRecovery)
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertEqual(deploymentRequests.count, 1)
    XCTAssertEqual(deploymentRequests.first?.url?.absoluteString, "https://status.example.com/partial")
  }

  func testBatchOnlineDirectPublishUsesGitHubAPIAndRecordsBatchRelease() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"content":{"path":"content/posts/batch-one.md"},"commit":{"sha":"batch-commit-1"}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"content":{"path":"content/posts/batch-two.md"},"commit":{"sha":"batch-commit-2"}}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))
    store.applyProEntitlement(source: .localOverride)

    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch One",
      slug: "batch-one",
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so batch online publishing can focus on GitHub API behavior for the first item."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Two",
      slug: "batch-two",
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so batch online publishing can focus on GitHub API behavior for the second item."
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)
    store.setRepositoryAutoSyncState(
      RepositoryAutoSyncState(
        status: .scanned,
        remoteChangedFileCount: 3,
        remoteChangedPaths: [
          "content/posts/batch-one.md",
          "content/posts/batch-two.md",
          "config.toml",
        ],
        importableRemoteArticleCount: 2,
        nonArticleRemoteChangedFileCount: 1,
        message: "自动同步已扫描：发现 3 个远端待拉取变化。"
      )
    )

    let publishResult = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()
    let result = try XCTUnwrap(publishResult)

    XCTAssertEqual(result.provider, .github)
    XCTAssertEqual(result.mode, .directCommit)
    XCTAssertEqual(result.branchName, "main")
    XCTAssertEqual(result.targetBranch, "main")
    XCTAssertEqual(result.changedPaths, [
      "content/posts/batch-one.md",
      "content/posts/batch-two.md",
    ])
    XCTAssertEqual(result.commitSHA, "batch-commit-2")
    XCTAssertEqual(store.remoteRepositoryPublishResult, result)
    XCTAssertEqual(store.releaseRecords.first?.kind, .remoteDirectCommit)
    XCTAssertNil(store.releaseRecords.first?.draftID)
    XCTAssertEqual(store.releaseRecords.first?.batchItems.map(\.draftID), [firstDraft.id, secondDraft.id])
    XCTAssertEqual(store.releaseRecords.first?.batchItems.map(\.draftTitle), ["Batch One", "Batch Two"])
    XCTAssertEqual(store.releaseRecords.first?.batchItems.first?.changedPaths, ["content/posts/batch-one.md"])
    XCTAssertEqual(store.releaseRecords.first?.batchItems.last?.changedPaths, ["content/posts/batch-two.md"])
    XCTAssertTrue(store.releaseRecords.first?.title.contains("批量线上提交") == true)
    XCTAssertTrue(store.releaseRecords.first?.summary.contains("2 篇文章") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("批量线上直接提交完成") == true)
    XCTAssertEqual(store.drafts.map(\.status), [.published, .published])
    XCTAssertTrue(store.drafts.allSatisfy { !$0.draft })
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedPaths, ["config.toml"])
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedFileCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.importableRemoteArticleCount, 0)
    XCTAssertEqual(store.repositoryAutoSyncState.nonArticleRemoteChangedFileCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishProvider, .github)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishMode, .directCommit)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishPaths, [
      "content/posts/batch-one.md",
      "content/posts/batch-two.md",
    ])

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT", "GET", "PUT"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/contents/content/posts/batch-one.md")
    XCTAssertEqual(requests[2].url?.path, "/repos/owner/site/contents/content/posts/batch-two.md")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")

    let firstPutBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: Any])
    XCTAssertEqual(firstPutBody["branch"] as? String, "main")
    XCTAssertEqual(firstPutBody["message"] as? String, "Publish: 2 articles")
  }

  func testBatchOnlinePublishPartialFailureRecordsRecoveryLedgerEntry() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"content":{"path":"content/posts/batch-partial-one.md"},"commit":{"sha":"batch-partial-commit-1"}}"#),
      workbenchRemoteResponse(statusCode: 500, json: #"{"message":"server error"}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 200, json: #"{"status":"building","message":"Batch partial publish deployment is still running"}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      deploymentStatusService: DeploymentStatusService(transport: deploymentTransport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.deploymentProvider = .custom
    profile.deploymentStatusEndpointURL = "https://status.example.com/batch-partial"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))
    store.applyProEntitlement(source: .localOverride)

    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Partial One",
      slug: "batch-partial-one",
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so batch partial online publishing records only completed files."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Partial Two",
      slug: "batch-partial-two",
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so the second remote write can fail after the first commit."
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)

    let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    XCTAssertTrue(store.publishActionMessage?.contains("批量线上直接提交失败") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("部分完成后失败") == true)

    let record = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(record.kind, .remotePublishFailure)
    XCTAssertEqual(record.title, "批量线上直接提交失败：\(profile.name)")
    XCTAssertEqual(record.batchItems.map(\.draftID), [firstDraft.id, secondDraft.id])
    XCTAssertEqual(record.batchItems.map(\.draftTitle), ["Batch Partial One", "Batch Partial Two"])
    XCTAssertEqual(record.batchItems.first?.changedPaths, ["content/posts/batch-partial-one.md"])
    XCTAssertEqual(record.batchItems.last?.changedPaths, ["content/posts/batch-partial-two.md"])
    XCTAssertEqual(record.changedPaths, ["content/posts/batch-partial-one.md"])
    XCTAssertEqual(record.commitSHA, "batch-partial-commit-1")
    XCTAssertTrue(record.summary.contains("2 篇文章未完成线上发布"))
    XCTAssertTrue(record.summary.contains("1 个文件已写入 main"))

    let entry = try XCTUnwrap(store.releaseLedger.entries.first)
    XCTAssertEqual(entry.status, .pendingRemoteRecovery)
    XCTAssertEqual(store.releaseLedger.summary.remoteRecoveryPendingCount, 1)
    XCTAssertEqual(store.releaseLedger.summary.failedCount, 0)
    XCTAssertEqual(store.releaseLedger.actionItems.first?.kind, .recoverPartialRemotePublish)
    XCTAssertTrue(store.releaseLedger.actionItems.first?.commandLines.contains("git revert --no-edit 'batch-partial-commit-1'") == true)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .running)
    XCTAssertEqual(store.releaseLedger.entries.first?.status, .pendingRemoteRecovery)
    XCTAssertTrue(entry.recoveryPackage.clipboardMarkdown.contains("- content/posts/batch-partial-one.md"))
    XCTAssertTrue(entry.recoveryPackage.clipboardMarkdown.contains("git revert --no-edit 'batch-partial-commit-1'"))
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertEqual(deploymentRequests.count, 1)
    XCTAssertEqual(deploymentRequests.first?.url?.absoluteString, "https://status.example.com/batch-partial")
  }

  func testBatchOnlinePublishBlocksMissingPermissionCheckBeforeCallingAPI() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let transport = CountingRemoteRepositoryTransport()
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.applyProEntitlement(source: .localOverride)

    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Permission One",
      slug: "batch-permission-one",
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so batch permission checks block before publishing."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Permission Two",
      slug: "batch-permission-two",
      draft: false,
      bodyMarkdown: "This article body is intentionally longer than the preflight minimum so batch permission checks block every API call."
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)

    let initialReleaseRecordCount = store.releaseRecords.count
    let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    XCTAssertEqual(store.releaseRecords.count, initialReleaseRecordCount)
    XCTAssertEqual(requestCount, 0)
    XCTAssertTrue(store.publishActionMessage?.contains("请先检查 GitHub Token 权限") == true)
  }

  func testImportsRemoteArticleDraftFromUpstreamSnapshot() async throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try """
    ---
    title: "Remote Draft"
    slug: remote-draft
    description: "Imported from upstream."
    ---

    Remote body for review.
    """.write(
      to: rootURL.appendingPathComponent("content/posts/remote.md"),
      atomically: true,
      encoding: .utf8
    )
    try git(["add", "content/posts/remote.md"], rootURL: rootURL)
    try git(["commit", "-m", "Remote draft"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)
    let remoteBlobSHA = try git(["rev-parse", "\(remoteCommit):content/posts/remote.md"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)

    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    store.updateActiveProfile(profile)
    await store.scanRepositoryAsync()

    let summary = store.importRemoteDraftFromRepository(repositoryPath: "content/posts/remote.md")

    XCTAssertEqual(summary.insertedCount, 1)
    XCTAssertEqual(summary.updatedCount, 0)
    let imported = try XCTUnwrap(store.drafts.first { $0.repositoryPath == "content/posts/remote.md" })
    XCTAssertEqual(imported.title, "Remote Draft")
    XCTAssertEqual(imported.summary, "Imported from upstream.")
    XCTAssertEqual(imported.bodyMarkdown, "Remote body for review.")
    XCTAssertEqual(imported.repositorySHA, remoteBlobSHA)
    XCTAssertEqual(store.selectedDraftID, imported.id)
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.publishActionMessage, "已从 origin/main 导入远端文章 content/posts/remote.md。")
  }

  func testImportsRemoteChangedArticleDraftsFromUpstreamQueue() async throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )

    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)

    try git(["switch", "-c", "remote-work"], rootURL: rootURL)
    try "remote readme\n".write(to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try remoteArticle(title: "Remote One", slug: "remote-one", body: "Remote one body.")
      .write(
        to: rootURL.appendingPathComponent("content/posts/remote-one.md"),
        atomically: true,
        encoding: .utf8
      )
    try remoteArticle(title: "Remote Two", slug: "remote-two", body: "Remote two body.")
      .write(
        to: rootURL.appendingPathComponent("content/posts/remote-two.md"),
        atomically: true,
        encoding: .utf8
      )
    try git(["add", "README.md", "content/posts/remote-one.md", "content/posts/remote-two.md"], rootURL: rootURL)
    try git(["commit", "-m", "Remote drafts"], rootURL: rootURL)
    let remoteCommit = try git(["rev-parse", "HEAD"], rootURL: rootURL)

    try git(["switch", "main"], rootURL: rootURL)
    try git(["remote", "add", "origin", "https://example.invalid/site.git"], rootURL: rootURL)
    try git(["update-ref", "refs/remotes/origin/main", remoteCommit], rootURL: rootURL)
    try git(["config", "branch.main.remote", "origin"], rootURL: rootURL)
    try git(["config", "branch.main.merge", "refs/heads/main"], rootURL: rootURL)

    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.contentRoot = "content"
    store.updateActiveProfile(profile)
    await store.scanRepositoryAsync()
    store.updateRepositoryAutoSyncSettings(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 5, fetchBeforeScan: false)
    )
    await store.runRepositoryAutoSync(now: Date(timeIntervalSince1970: 1_800_000_000))

    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedFileCount, 3)
    XCTAssertEqual(store.repositoryAutoSyncState.importableRemoteArticleCount, 2)
    XCTAssertEqual(store.repositoryAutoSyncState.nonArticleRemoteChangedFileCount, 1)
    XCTAssertTrue(store.repositoryAutoSyncState.message.contains("其中 2 篇文章可导入"))

    let summary = store.importRemoteChangedArticleDraftsFromRepository()

    XCTAssertEqual(summary.insertedCount, 2)
    XCTAssertEqual(summary.updatedCount, 0)
    XCTAssertTrue(store.drafts.contains { $0.repositoryPath == "content/posts/remote-one.md" && $0.title == "Remote One" })
    XCTAssertTrue(store.drafts.contains { $0.repositoryPath == "content/posts/remote-two.md" && $0.title == "Remote Two" })
    XCTAssertEqual(store.selectedSection, .writing)
    XCTAssertEqual(store.publishActionMessage, "已从远端文章变更导入 2 篇、更新 0 篇。")
  }
}

private actor CountingRemoteRepositoryTransport: RemoteRepositoryHTTPTransport {
  private var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    throw URLError(.badServerResponse)
  }

  func requestCount() -> Int {
    requests.count
  }
}

private actor SequencedWorkbenchRemoteRepositoryTransport: RemoteRepositoryHTTPTransport {
  private var responses: [WorkbenchRemoteRepositoryTransportResponse]
  private var requests: [URLRequest] = []

  init(responses: [WorkbenchRemoteRepositoryTransportResponse]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard !responses.isEmpty else {
      XCTFail("Unexpected remote repository request: \(request.url?.absoluteString ?? "")")
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      )
    }

    let response = responses.removeFirst()
    return (
      response.data,
      HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
    )
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }
}

private actor SuspendedWorkbenchRemoteRepositoryTransport: RemoteRepositoryHTTPTransport {
  private let response: WorkbenchRemoteRepositoryTransportResponse
  private var responseContinuation: CheckedContinuation<Void, Never>?
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var requestArrived = false

  init(response: WorkbenchRemoteRepositoryTransportResponse) {
    self.response = response
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requestArrived = true
    requestWaiters.forEach { $0.resume() }
    requestWaiters.removeAll()
    await withCheckedContinuation { continuation in
      responseContinuation = continuation
    }
    return (
      response.data,
      HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
    )
  }

  func waitUntilRequestArrives() async {
    guard !requestArrived else { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func resume() {
    responseContinuation?.resume()
    responseContinuation = nil
  }
}

private struct WorkbenchRemoteRepositoryTransportResponse {
  var statusCode: Int
  var data: Data
}

private func workbenchRemoteResponse(
  statusCode: Int = 200,
  json: String
) -> WorkbenchRemoteRepositoryTransportResponse {
  WorkbenchRemoteRepositoryTransportResponse(statusCode: statusCode, data: Data(json.utf8))
}
