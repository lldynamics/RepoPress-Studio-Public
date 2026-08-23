import Foundation
import XCTest
@testable import PublishingWorkbenchCore

extension WorkbenchStoreProfileTests {
  func testDirectRemotePublishPersistsAttachmentVersionsForNextPublish() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    let attachment = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png",
      sourceFilePath: "/tmp/cover.png"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Versioned Attachment",
      slug: "versioned-attachment",
      bodyMarkdown: "Long enough body content for attachment lifecycle coverage.",
      attachments: [attachment]
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    store.setDrafts([draft])

    store.publishingStore.confirmDirectRemotePublishLifecycle(
      packages: [package],
      result: RemoteRepositoryPublishResult(
        provider: .github,
        mode: .directCommit,
        branchName: "main",
        targetBranch: "main",
        changedPaths: [package.markdownPath, attachment.repositoryPath],
        commitSHA: "commit-sha",
        remoteVersionsByPath: [
          package.markdownPath: "markdown-sha",
          attachment.repositoryPath: "image-sha",
        ]
      )
    )

    let confirmedDraft = try XCTUnwrap(store.drafts.first)
    XCTAssertEqual(confirmedDraft.repositorySHA, "markdown-sha")
    XCTAssertEqual(confirmedDraft.attachments.first?.repositorySHA, "image-sha")
    let nextPackage = PublishPackageBuilder().build(draft: confirmedDraft, profile: profile)
    XCTAssertEqual(nextPackage.files.first { $0.kind == .image }?.expectedRemoteSHA, "image-sha")
  }

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
    XCTAssertEqual(preview.remoteRiskState, .conflict)
    XCTAssertEqual(preview.readiness, .blocked)
    XCTAssertFalse(preview.canPublish)
    XCTAssertTrue(preview.checklistMarkdown.contains(CoreL10n.text("## 远端冲突预览")))
    XCTAssertTrue(store.publishActionMessage?.contains("已停止线上发布") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("远端同路径变更") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("content/posts/online-direct-conflict.md") == true)

    let cachedPreview = try XCTUnwrap(store.remotePublishPreviewSnapshot)
    XCTAssertEqual(cachedPreview.changedPaths, preview.changedPaths)
    XCTAssertEqual(cachedPreview.remoteConflictPaths, preview.remoteConflictPaths)
  }

  func testRemotePublishRiskAssessmentDistinguishesUnknownCleanAndConflict() {
    let package = PublishPackage(
      draftID: UUID(),
      title: "Remote Risk",
      markdownPath: "content/posts/remote-risk.md",
      files: [
        PublishPackageFile(
          kind: .markdown,
          repositoryPath: "content/posts/remote-risk.md",
          content: "body"
        )
      ],
      commitMessage: "Publish remote risk",
      reviewBranchName: "publish/remote-risk",
      reviewTitle: "Remote Risk",
      reviewChecklist: []
    )
    let service = RemotePublishRiskService()

    XCTAssertEqual(
      service.assessment(package: package, repositoryReport: nil).state,
      .unknown
    )

    let cleanReport = RepositoryScanReport(
      rootPath: "/tmp/site",
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 1,
      imageFileCount: 0,
      branchStatus: RepositoryBranchStatus(
        branchName: "main",
        upstreamName: "origin/main"
      ),
      changedFiles: [],
      remoteChangedFiles: [],
      preflightIssues: []
    )
    XCTAssertEqual(
      service.assessment(package: package, repositoryReport: cleanReport).state,
      .clean
    )

    var staleReport = cleanReport
    staleReport.scannedAt = Date().addingTimeInterval(-301)
    XCTAssertEqual(
      service.assessment(package: package, repositoryReport: staleReport).state,
      .unknown
    )

    var conflictingReport = cleanReport
    conflictingReport.remoteChangedFiles = [
      RepositoryChangedFile(
        status: "M",
        path: "content/posts/remote-risk.md",
        kind: .modified
      )
    ]
    let conflict = service.assessment(
      package: package,
      repositoryReport: conflictingReport
    )
    XCTAssertEqual(conflict.state, .conflict)
    XCTAssertEqual(conflict.conflictPaths, ["content/posts/remote-risk.md"])
  }

  func testOnlineDirectPublishMarksDraftPublishedAndRecordsDeploymentStatus() async throws {
    let publishTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"content":{"path":"content/posts/online-direct-success.md","sha":"online-direct-content-sha"},"commit":{"sha":"online-direct-commit"}}"#),
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
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
        message: "自动检查远端已扫描：发现 2 个远端待拉取变化。"
      )
    )

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()

    XCTAssertEqual(result?.commitSHA, "online-direct-commit")
    XCTAssertEqual(store.drafts.first?.status, .published)
    XCTAssertFalse(store.drafts.first?.draft ?? true)
    XCTAssertEqual(store.drafts.first?.repositoryPath, "content/posts/online-direct-success.md")
    XCTAssertEqual(store.drafts.first?.repositorySHA, "online-direct-content-sha")
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
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
    XCTAssertEqual(store.publishActionMessage, CoreL10n.format("线上回滚完成：%@", "rollback"))
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
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
    XCTAssertEqual(store.publishActionMessage, CoreL10n.format("线上 Review 已撤回：#%@", "9"))
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

  func testReviewRecoveryReplacesPartialFailureWithoutRepeatingPublishingWork() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"remote-branch-sha"}}"#),
      workbenchRemoteResponse(json: #"[]"#),
      workbenchRemoteResponse(json: #"{"html_url":"https://github.com/owner/site/pull/22"}"#),
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    let original = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "批量线上 PR/MR 失败",
      summary: "GitHub 内容已写入，创建 PR 失败",
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: ["content/posts/one.md"],
      repositoryProvider: .github,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: "owner",
      repoName: "site",
      branchName: "publish/batch-recovery",
      targetBranch: "main",
      commitSHA: "recorded-sha"
    )
    store.setReleaseRecords([original])
    XCTAssertEqual(store.activeProfileReleaseLedger.entries.first?.status, .pendingRemoteRecovery)

    let result = await store.resumeRemoteReview(original)

    XCTAssertEqual(result?.reviewURL, "https://github.com/owner/site/pull/22")
    XCTAssertEqual(store.releaseRecords.count, 1)
    let recovered = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(recovered.id, original.id)
    XCTAssertEqual(recovered.kind, .remoteReviewRequest)
    XCTAssertEqual(recovered.commitSHA, "remote-branch-sha")
    XCTAssertEqual(recovered.reviewURL, "https://github.com/owner/site/pull/22")
    XCTAssertEqual(store.activeProfileReleaseLedger.entries.first?.status, .pendingReview)
    XCTAssertEqual(store.activeProfileReleaseLedger.summary.remoteRecoveryPendingCount, 0)
    XCTAssertEqual(store.activeProfileReleaseLedger.summary.reviewPendingCount, 1)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/contents/") == true })
  }

  func testReviewRecoveryPersistsPrecisePullRequestPermissionFailure() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"remote-branch-sha"}}"#),
      workbenchRemoteResponse(json: #"[]"#),
      workbenchRemoteResponse(
        statusCode: 403,
        json: #"{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/pulls/pulls#create-a-pull-request"}"#
      ),
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    let original = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "批量线上 PR/MR 失败",
      summary: "GitHub 内容已写入，创建 PR 失败",
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: ["content/posts/one.md"],
      repositoryProvider: .github,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: "owner",
      repoName: "site",
      branchName: "publish/batch-recovery",
      targetBranch: "main",
      commitSHA: "recorded-sha"
    )
    store.setReleaseRecords([original])

    let result = await store.resumeRemoteReview(original)

    XCTAssertNil(result)
    XCTAssertEqual(store.releaseRecords.count, 1)
    XCTAssertEqual(store.releaseRecords.first?.id, original.id)
    XCTAssertEqual(store.releaseRecords.first?.kind, .remotePublishFailure)
    XCTAssertTrue(store.releaseRecords.first?.summary.contains("Pull requests: Read and write") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("Pull requests: Read and write") == true)
    XCTAssertEqual(store.activeProfileReleaseLedger.entries.first?.status, .pendingRemoteRecovery)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
    XCTAssertFalse(requests.contains { $0.url?.path.contains("/contents/") == true })
  }

  func testReviewRecoveryBusyGuardRunsBeforeRepositoryTokenRead() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "http://insecure.example.test"
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    store.updateActiveProfile(profile)

    let original = ReleaseRecord(
      kind: .remotePublishFailure,
      title: "批量线上 PR/MR 失败",
      summary: "GitHub 内容已写入，创建 PR 失败",
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: ["content/posts/one.md"],
      repositoryProvider: .github,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: "owner",
      repoName: "site",
      branchName: "publish/batch-recovery",
      targetBranch: "main",
      commitSHA: "recorded-sha"
    )
    store.setReleaseRecords([original])
    store.publishingStore.remoteRepositoryMutationContext =
      RemoteRepositoryOperationContext(profile: profile)

    let result = await store.resumeRemoteReview(original)

    XCTAssertNil(result)
    XCTAssertEqual(
      store.publishActionMessage,
      CoreL10n.text("已有远端仓库操作正在运行，请等待完成。")
    )
    XCTAssertFalse(store.publishActionMessage?.contains("http://insecure.example.test") == true)
    let requests = await transport.capturedRequests()
    XCTAssertTrue(requests.isEmpty)
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
    XCTAssertEqual(preview.remoteRiskState, .conflict)
    XCTAssertEqual(preview.accessSummary, CoreL10n.text("Token 可写"))
    XCTAssertEqual(preview.readiness, .ready)
    XCTAssertTrue(preview.canPublish)
    XCTAssertTrue(preview.warningIssues.contains { $0.title == "远端同路径变更" })
    XCTAssertTrue(preview.blockingIssues.isEmpty)
    XCTAssertTrue(preview.checklistMarkdown.contains(CoreL10n.text("# GitHub/GitLab 线上发布核对包")))
    XCTAssertTrue(preview.checklistMarkdown.contains("- 平台：GitLab"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- 发布模式：线上 PR/MR"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [x] 已确认 Token 对 group/site 具备内容写入权限"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [ ] 已确认远端同路径变更"))
    XCTAssertTrue(preview.checklistMarkdown.contains(CoreL10n.text("## 远端冲突预览")))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [警告] 远端同路径变更"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- content/posts/online-review-preview.md"))
  }

  func testRemoteRepositoryPublishPreviewAllowsInvalidNonEmptySlugAsWarning() throws {
    let store = try TestWorkbenchFactory.makeStore()

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
      apiBaseURL: "https://api.github.com",
      defaultBranch: "main",
      canRead: true,
      canWrite: true,
      message: "GitHub Token 具备仓库写入权限。"
    ))

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Existing Article",
      slug: "Existing Article",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough to verify publishing with an invalid slug warning."
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
      remoteChangedFiles: [],
      preflightIssues: []
    ))

    let preview = store.remoteRepositoryPublishPreview(for: draft)

    XCTAssertTrue(preview.canPublish)
    XCTAssertFalse(preview.blockingIssues.contains { $0.title == "Slug 格式非法" })
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
    XCTAssertEqual(preview.accessSummary, CoreL10n.text("未保存 Token"))
    XCTAssertFalse(preview.canPublish)
    XCTAssertEqual(preview.changedPaths, ["content/posts/token-required.md"])
    XCTAssertEqual(preview.mode, .directCommit)
    XCTAssertEqual(preview.branchName, "main")
    XCTAssertTrue(preview.checklistMarkdown.contains("- Token：未保存"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [ ] 已保存 GitHub Token"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [ ] 已确认 Token 对 owner/site 具备内容写入权限"))
  }

  func testRemoteRepositoryPublishPreviewBlocksTokenAccessFailureWithoutReportingMissingToken() throws {
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
    store.setRepositoryTokenAvailability(
      KeychainTokenAvailability(
        hasToken: false,
        accessFailureMessage: "Keychain interaction is not allowed"
      )
    )

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Keychain Failure",
      slug: "keychain-failure",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for online publish preview Keychain failure coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let preview = store.remoteRepositoryPublishPreview(for: draft)

    XCTAssertEqual(preview.readiness, .blocked)
    XCTAssertFalse(preview.canPublish)
    XCTAssertEqual(
      preview.tokenAccessFailureMessage,
      "Keychain interaction is not allowed"
    )
    XCTAssertTrue(preview.blockingIssues.contains { issue in
      issue.field == "repositoryToken"
        && issue.title == CoreL10n.text("Token 状态读取失败")
    })
    XCTAssertFalse(preview.accessSummary.contains(CoreL10n.text("未保存 Token")))
  }

  func testBatchRemoteRepositoryPublishPreviewBlocksTokenAccessFailureWithoutReportingMissingToken() throws {
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
      title: "Batch Keychain Failure",
      slug: "batch-keychain-failure",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for batch online publish preview Keychain failure coverage."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Keychain Failure Two",
      slug: "batch-keychain-failure-two",
      draft: false,
      bodyMarkdown: "This second body is intentionally long enough to make the Keychain failure preview a real batch publish plan."
    )
    store.setDrafts([draft, secondDraft])
    store.setSelectedDraftID(draft.id)
    store.refreshBatchPublishPlan()

    let plan = try XCTUnwrap(store.batchPublishPlan)
    XCTAssertFalse(
      plan.remotePublishableItems.isEmpty,
      "Expected a remote-publishable batch plan, got: \(plan)"
    )
    store.setRepositoryTokenAvailability(
      KeychainTokenAvailability(
        hasToken: false,
        accessFailureMessage: "Keychain interaction is not allowed"
      )
    )
    let preview = try XCTUnwrap(store.remoteRepositoryPublishPreview(for: plan))

    XCTAssertEqual(preview.readiness, .blocked)
    XCTAssertFalse(preview.canPublish)
    XCTAssertEqual(
      preview.tokenAccessFailureMessage,
      "Keychain interaction is not allowed"
    )
    XCTAssertTrue(preview.blockingIssues.contains { issue in
      issue.field == "repositoryToken"
        && issue.title == CoreL10n.text("Token 状态读取失败")
    })
    XCTAssertFalse(preview.accessSummary.contains(CoreL10n.text("未保存 Token")))
    XCTAssertFalse(preview.checklistMarkdown.contains("- Token：\(CoreL10n.text("未保存"))"))
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
    XCTAssertEqual(preview.accessSummary, CoreL10n.text("Token 已保存，尚未检查权限"))
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
    XCTAssertEqual(store.publishActionMessage, CoreL10n.text("仓库访问 Token 已保存到 Keychain。"))
    XCTAssertEqual(store.publishActionFeedback?.status, .success)
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
    XCTAssertEqual(preview.accessSummary, CoreL10n.text("Token 已保存，尚未检查权限"))
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
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
    XCTAssertEqual(store.publishActionFeedback?.status, .success)
    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      repositoryTokenStore: tokenStore
    )
    XCTAssertTrue(reloaded.repositoryTokenAvailability.hasToken)
    XCTAssertEqual(reloaded.activeRemoteRepositoryAccessCheck?.repositoryName, "owner/site")
    XCTAssertTrue(reloaded.activeRemoteRepositoryAccessCheck?.canWrite == true)

    let preview = reloaded.remoteRepositoryPublishPreview(for: draft)
    XCTAssertEqual(preview.remoteRiskState, .unknown)
    XCTAssertEqual(preview.readiness, .needsRemoteCheck)
    XCTAssertTrue(preview.canPublish)
    XCTAssertEqual(preview.accessSummary, CoreL10n.text("Token 可写"))
    XCTAssertFalse(preview.checklistMarkdown.contains(CoreL10n.text("PR 创建权限将在实际创建时验证")))
    XCTAssertTrue(preview.warningIssues.contains { $0.title == CoreL10n.text("远端状态待确认") })
    XCTAssertTrue(preview.checklistMarkdown.contains(CoreL10n.text("## 远端状态待确认")))
  }

  func testPermissionCheckFillsMissingRepositoryConfigurationFromDetectedOrigin() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json: #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true}}"#
      ),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let persistenceURL = try temporaryPersistenceURL(prefix: "DetectedOriginPermission")
    let rootURL = try preparedGitRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    let storeProfileForCleanup = profile
    defer { try? tokenStore.deleteRepositoryToken(for: storeProfileForCleanup) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 1,
      imageFileCount: 0,
      branchStatus: RepositoryBranchStatus(branchName: "production", upstreamName: "origin/production"),
      originRemote: RepositoryRemote(
        remoteURL: "https://github.com/owner/site.git",
        provider: .github,
        repositoryBaseURL: RepositoryProvider.github.defaultBaseURL,
        owner: "owner",
        name: "site"
      ),
      changedFiles: [],
      preflightIssues: []
    ))
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Detected Origin",
      slug: "detected-origin",
      draft: false,
      bodyMarkdown: "This body is long enough to exercise the detected-origin permission check."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let check = await store.checkRepositoryTokenAccess()

    XCTAssertTrue(check?.canWrite == true)
    XCTAssertEqual(store.activeProfile.repoOwner, "owner")
    XCTAssertEqual(store.activeProfile.repoName, "site")
    XCTAssertEqual(store.activeProfile.repositoryProvider, .github)
    XCTAssertEqual(store.activeProfile.branch, "production")
    XCTAssertTrue(store.remotePublishPreviewSnapshot?.accessCheck?.canWrite == true)
    XCTAssertTrue(store.batchRemotePublishPreviewSnapshot?.accessCheck?.canWrite == true)
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      repositoryTokenStore: tokenStore
    )
    XCTAssertEqual(reloaded.activeProfile.repoOwner, "owner")
    XCTAssertEqual(reloaded.activeProfile.repoName, "site")
    XCTAssertTrue(reloaded.activeRemoteRepositoryAccessCheck?.canWrite == true)
  }

  func testPermissionCheckDoesNotReplaceCompleteRepositoryConfigurationWithDetectedOrigin() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json: #"{"full_name":"detected/site","default_branch":"main","permissions":{"push":true}}"#
      ),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let rootURL = try preparedGitRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "CompleteRepositoryConfiguration"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "configured"
    profile.repoName = "site"
    profile.branch = "release"
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteRepositoryToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 1,
      imageFileCount: 0,
      originRemote: RepositoryRemote(
        remoteURL: "https://github.com/detected/site.git",
        provider: .github,
        repositoryBaseURL: RepositoryProvider.github.defaultBaseURL,
        owner: "detected",
        name: "site"
      ),
      changedFiles: [],
      preflightIssues: []
    ))

    let check = await store.checkRepositoryTokenAccess()

    XCTAssertTrue(check?.canWrite == true)
    XCTAssertEqual(store.activeProfile.repoOwner, "configured")
    XCTAssertEqual(store.activeProfile.repoName, "site")
    XCTAssertEqual(store.activeProfile.branch, "release")
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.first?.url?.path, "/repos/configured/site")
  }

  func testPermissionCheckLeavesMismatchedPartialConfigurationUntouched() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let tokenStore = repositoryTokenStoreForTest()
    let rootURL = try preparedGitRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "PartialRepositoryConfiguration"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )

    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(rootURL)
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "configured"
    profile.repoName = ""
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteRepositoryToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRepositoryReport(RepositoryScanReport(
      rootPath: rootURL.path,
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 1,
      imageFileCount: 0,
      originRemote: RepositoryRemote(
        remoteURL: "https://gitlab.com/detected/site.git",
        provider: .gitlab,
        repositoryBaseURL: "https://gitlab.com",
        owner: "detected",
        name: "site"
      ),
      changedFiles: [],
      preflightIssues: []
    ))

    let check = await store.checkRepositoryTokenAccess()

    XCTAssertNil(check)
    XCTAssertEqual(store.activeProfile.repositoryProvider, .github)
    XCTAssertEqual(store.activeProfile.repositoryBaseURL, RepositoryProvider.github.defaultBaseURL)
    XCTAssertEqual(store.activeProfile.repoOwner, "configured")
    XCTAssertTrue(store.activeProfile.repoName.isEmpty)
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testRepositoryPermissionCheckFailureUsesStructuredFailureStatus() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        statusCode: 403,
        json: #"{"message":"token rejected"}"#
      )
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
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)

    let check = await store.checkRepositoryTokenAccess()

    XCTAssertNil(check)
    XCTAssertEqual(store.publishActionFeedback?.status, .failure)
    XCTAssertNotNil(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)

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
    XCTAssertEqual(preview.accessSummary, CoreL10n.text("Token 已保存，尚未检查权限"))
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
    XCTAssertEqual(preview.accessSummary, CoreL10n.text("Token 已保存，尚未检查权限"))
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

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
    XCTAssertEqual(
      store.publishActionMessage,
      CoreL10n.format("请先检查 %@ Token 权限，确认具备写入权限后再线上发布。", "GitHub")
    )
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
    XCTAssertEqual(preview.remoteRiskState, .conflict)
    XCTAssertEqual(preview.accessSummary, CoreL10n.text("内容可写，PR 权限待创建时验证"))
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
      issue.title == "Batch Needs Review Draft：\(CoreL10n.text("正文偏短"))"
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
    XCTAssertEqual(store.publishActionMessage, CoreL10n.text("Token 无写入权限，无法线上发布。"))
    XCTAssertEqual(store.publishActionFeedback?.status, .failure)
  }

  func testCreateGitHubRepositoryForActiveProfileDefaultsToPrivateAndUpdatesProfile() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"login":"owner"}"#),
      workbenchRemoteResponse(json: #"{"full_name":"owner/site","default_branch":"main","ssh_url":"git@github.com:owner/site.git","clone_url":"https://github.com/owner/site.git","html_url":"https://github.com/owner/site","private":true}"#),
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

    let result = await store.createGitHubRepositoryForActiveProfile()

    XCTAssertEqual(result?.repositoryName, "owner/site")
    XCTAssertEqual(result?.privateRepository, true)
    XCTAssertEqual(store.remoteRepositoryCreationResult?.htmlURL, "https://github.com/owner/site")
    XCTAssertEqual(store.activeProfile.repoOwner, "owner")
    XCTAssertEqual(store.activeProfile.repoName, "site")
    XCTAssertEqual(store.repositoryTokenAvailability.hasToken, true)
    XCTAssertTrue(store.publishActionMessage?.contains("GitHub 仓库已创建：owner/site") == true)
    XCTAssertEqual(store.publishActionFeedback?.status, .success)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests[0].url?.path, "/user")
    XCTAssertEqual(requests[1].url?.path, "/user/repos")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
    let body = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: Any]
    )
    XCTAssertEqual(body["private"] as? Bool, true)
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
    try tokenStore.saveRepositoryToken("gitlab-token", for: profile)
    store.refreshRepositoryTokenAvailability()

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

  func testOnlineAtomicPublishFailureRequiresNoPartialRecovery() async throws {
    let rootURL = try temporaryDirectoryURL()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let imageURL = rootURL.appendingPathComponent("partial-cover.png")
    try Data([1, 2, 3, 4]).write(to: imageURL)

    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      workbenchRemoteResponse(json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[]}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"markdown-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"image-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 500, json: #"{"message":"tree creation failed"}"#),
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
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
    XCTAssertTrue(store.publishActionMessage?.contains("tree creation failed") == true)
    XCTAssertFalse(store.publishActionMessage?.contains("部分完成后失败") == true)
    let record = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(record.kind, .remotePublishFailure)
    XCTAssertEqual(record.changedPaths, ["content/posts/partial-failure.md", "static/images/partial-cover.png"])
    XCTAssertNil(record.commitSHA)
    XCTAssertEqual(store.releaseLedger.entries.first?.status, .failed)
    XCTAssertEqual(store.releaseLedger.summary.remoteRecoveryPendingCount, 0)
    XCTAssertEqual(store.releaseLedger.summary.failedCount, 1)
    XCTAssertEqual(store.releaseLedger.actionItems.first?.kind, .failedRelease)
    XCTAssertNil(store.deploymentStatusSnapshot(for: record))
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertTrue(deploymentRequests.isEmpty)
  }

  func testCancelledOnlinePublishStopsAfterTransportCancellation() async throws {
    let transport = CountingRemoteRepositoryTransport(failureCode: .cancelled)
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
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
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

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Cancelled Publish",
      slug: "cancelled-publish",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough for cancellation coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertEqual(requestCount, 1)
  }

  func testBatchOnlineDirectPublishUsesGitHubAPIAndRecordsBatchRelease() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      workbenchRemoteResponse(json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[]}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"batch-one-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"batch-two-blob-sha"}"#),
      workbenchRemoteResponse(json: #"{"sha":"batch-tree-sha"}"#),
      workbenchRemoteResponse(json: #"{"sha":"batch-commit-sha","tree":{"sha":"batch-tree-sha"},"parents":[{"sha":"base-commit-sha"}]}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"batch-commit-sha"}}"#),
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
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
        message: "自动检查远端已扫描：发现 3 个远端待拉取变化。"
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
    XCTAssertEqual(result.commitSHA, "batch-commit-sha")
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
    XCTAssertEqual(store.publishActionFeedback?.status, .success)
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
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "POST", "GET", "POST", "POST", "POST", "PATCH"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site/git/ref/heads/main")
    XCTAssertEqual(requests[6].url?.path, "/repos/owner/site/git/trees")
    XCTAssertEqual(requests[7].url?.path, "/repos/owner/site/git/commits")
    XCTAssertEqual(requests[8].url?.path, "/repos/owner/site/git/refs/heads/main")
    XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")

    let commitBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[7].httpBody)) as? [String: Any])
    XCTAssertEqual(commitBody["message"] as? String, "Publish: 2 articles")
    XCTAssertEqual(commitBody["parents"] as? [String], ["base-commit-sha"])
  }

  func testBatchOnlineAtomicFailureRequiresNoPartialRecovery() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      workbenchRemoteResponse(json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[]}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"first-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"second-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 500, json: #"{"message":"tree creation failed"}"#),
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
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
    XCTAssertFalse(store.publishActionMessage?.contains("部分完成后失败") == true)
    XCTAssertEqual(store.publishActionFeedback?.status, .failure)

    let record = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(record.kind, .remotePublishFailure)
    XCTAssertEqual(record.title, "批量线上直接提交失败：\(profile.name)")
    XCTAssertEqual(record.batchItems.map(\.draftID), [firstDraft.id, secondDraft.id])
    XCTAssertEqual(record.batchItems.map(\.draftTitle), ["Batch Partial One", "Batch Partial Two"])
    XCTAssertEqual(record.batchItems.first?.changedPaths, ["content/posts/batch-partial-one.md"])
    XCTAssertEqual(record.batchItems.last?.changedPaths, ["content/posts/batch-partial-two.md"])
    XCTAssertEqual(record.changedPaths, ["content/posts/batch-partial-one.md", "content/posts/batch-partial-two.md"])
    XCTAssertNil(record.commitSHA)
    XCTAssertTrue(record.summary.contains("2 篇文章未完成线上发布"))
    XCTAssertTrue(record.summary.contains("tree creation failed"))

    let entry = try XCTUnwrap(store.releaseLedger.entries.first)
    XCTAssertEqual(entry.status, .failed)
    XCTAssertEqual(store.releaseLedger.summary.remoteRecoveryPendingCount, 0)
    XCTAssertEqual(store.releaseLedger.summary.failedCount, 1)
    XCTAssertEqual(store.releaseLedger.actionItems.first?.kind, .failedRelease)
    XCTAssertNil(store.deploymentStatusSnapshot(for: record))
    XCTAssertFalse(entry.recoveryPackage.clipboardMarkdown.contains("git revert"))
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertTrue(deploymentRequests.isEmpty)
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

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
    XCTAssertEqual(
      store.publishActionMessage,
      CoreL10n.format("请先检查 %@ Token 权限，确认具备写入权限后再批量线上发布。", "GitHub")
    )
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
    XCTAssertTrue(store.repositoryAutoSyncState.message.contains("其中 2 篇文章可手动导入"))

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
  private let failureCode: URLError.Code

  init(failureCode: URLError.Code = .badServerResponse) {
    self.failureCode = failureCode
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    throw URLError(failureCode)
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
