import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreRemotePublishingBatchTests: WorkbenchStoreRemotePublishingTestCase {
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
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum so batch review preview can focus on remote conflict warnings."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setRepositoryReport(
      RepositoryScanReport(
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
          RepositoryChangedFile(
            status: "M", path: "content/posts/batch-review-conflict.md", kind: .modified)
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
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum so the batch preview has one clean article."
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
    XCTAssertEqual(
      plan.remotePublishableItems.map(\.draftID), [readyDraft.id, needsReviewDraft.id])

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
    XCTAssertTrue(
      preview.warningIssues.contains { issue in
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
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
      bodyMarkdown: "This body is intentionally long enough for read only token blocking.",
      repositoryPath: "content/posts/read-only-token.md"
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
      workbenchRemoteResponse(
        json:
          #"{"full_name":"owner/site","default_branch":"main","ssh_url":"git@github.com:owner/site.git","clone_url":"https://github.com/owner/site.git","html_url":"https://github.com/owner/site","private":true}"#
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
      workbenchRemoteResponse(
        json:
          #"{"path_with_namespace":"group/subgroup/site","default_branch":"main","ssh_url_to_repo":"git@gitlab.internal.example:group/subgroup/site.git","http_url_to_repo":"https://gitlab.internal.example/group/subgroup/site.git","web_url":"https://gitlab.internal.example/group/subgroup/site","visibility":"private"}"#
      ),
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
    XCTAssertEqual(
      store.remoteRepositoryCreationResult?.htmlURL,
      "https://gitlab.internal.example/group/subgroup/site")
    XCTAssertEqual(store.activeProfile.repositoryProvider, .gitlab)
    XCTAssertEqual(store.activeProfile.repositoryBaseURL, "https://gitlab.internal.example")
    XCTAssertEqual(store.activeProfile.repoOwner, "group/subgroup")
    XCTAssertEqual(store.activeProfile.repoName, "site")
    XCTAssertEqual(store.repositoryTokenAvailability.hasToken, true)
    XCTAssertTrue(store.publishActionMessage?.contains("GitLab 仓库已创建：group/subgroup/site") == true)

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(
      requests[0].url?.absoluteString,
      "https://gitlab.internal.example/api/v4/groups/group%2Fsubgroup")
    XCTAssertEqual(
      requests[1].url?.absoluteString, "https://gitlab.internal.example/api/v4/projects")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "PRIVATE-TOKEN"), "gitlab-token")
  }

  func testOnlineAtomicPublishFailureRequiresNoPartialRecovery() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let imageURL = rootURL.appendingPathComponent("partial-cover.png")
    try makePNG().write(to: imageURL, options: .atomic)

    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      workbenchRemoteResponse(
        json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[]}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"markdown-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"image-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 500, json: #"{"message":"tree creation failed"}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        statusCode: 200,
        json: #"{"status":"building","message":"Partial publish deployment is still running"}"#)
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
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
      bodyMarkdown:
        "This body is intentionally long enough for partial online publishing failure coverage.",
      attachments: [attachment],
      repositoryPath: "content/posts/partial-failure.md"
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
    XCTAssertEqual(
      record.changedPaths, ["content/posts/partial-failure.md", "static/images/partial-cover.png"])
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
    let rootURL = try preparedGitRepositoryRoot(prefix: "CancelledRemoteLocalProject")
    defer { try? FileManager.default.removeItem(at: rootURL) }
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
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
      bodyMarkdown: "This body is intentionally long enough for cancellation coverage.",
      repositoryPath: "content/posts/cancelled-publish.md"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertEqual(requestCount, 1)
    XCTAssertFalse(store.isRemoteRepositoryPublishing)
    XCTAssertEqual(store.publishActionFeedback?.status, .warning)
    XCTAssertTrue(store.publishActionMessage?.contains("已中断") == true)
    XCTAssertTrue(store.releaseRecords.isEmpty)
  }

  func testBatchOnlineDirectPublishUsesGitHubAPIAndRecordsBatchRelease() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json: #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      workbenchRemoteResponse(
        json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[]}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"batch-one-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"batch-two-blob-sha"}"#),
      workbenchRemoteResponse(json: #"{"sha":"batch-tree-sha"}"#),
      workbenchRemoteResponse(
        json:
          #"{"sha":"batch-commit-sha","tree":{"sha":"batch-tree-sha"},"parents":[{"sha":"base-commit-sha"}]}"#
      ),
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
    // This test intentionally stops at the target-branch commit boundary.
    // Without deployment evidence the drafts must stay unpublished.
    profile.deploymentProvider = .custom
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
      title: "Batch One",
      slug: "batch-one",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum so batch online publishing can focus on GitHub API behavior for the first item."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Two",
      slug: "batch-two",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum so batch online publishing can focus on GitHub API behavior for the second item."
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
    XCTAssertEqual(
      result.changedPaths,
      [
        "content/posts/batch-one.md",
        "content/posts/batch-two.md",
      ])
    XCTAssertEqual(result.commitSHA, "batch-commit-sha")
    XCTAssertEqual(store.remoteRepositoryPublishResult, result)
    XCTAssertEqual(store.releaseRecords.first?.kind, .remoteDirectCommit)
    XCTAssertNil(store.releaseRecords.first?.draftID)
    XCTAssertEqual(
      store.releaseRecords.first?.batchItems.map(\.draftID), [firstDraft.id, secondDraft.id])
    XCTAssertEqual(
      store.releaseRecords.first?.batchItems.map(\.draftTitle), ["Batch One", "Batch Two"])
    XCTAssertEqual(
      store.releaseRecords.first?.batchItems.first?.changedPaths, ["content/posts/batch-one.md"])
    XCTAssertEqual(
      store.releaseRecords.first?.batchItems.last?.changedPaths, ["content/posts/batch-two.md"])
    XCTAssertTrue(store.releaseRecords.first?.title.contains("批量线上提交") == true)
    XCTAssertTrue(store.releaseRecords.first?.summary.contains("2 篇文章") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("批量线上直接提交完成") == true)
    XCTAssertEqual(store.publishActionFeedback?.status, .warning)
    XCTAssertEqual(store.drafts.map(\.status), [.draft, .draft])
    XCTAssertTrue(store.drafts.allSatisfy { !$0.draft })
    XCTAssertNil(store.deploymentStatusSnapshot(for: try XCTUnwrap(store.releaseRecords.first)))
    XCTAssertEqual(store.releaseLedger.entries.first?.status, .pendingDeployment)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("content/posts/batch-one.md").path
      ))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("content/posts/batch-two.md").path
      ))
    XCTAssertEqual(
      Set(store.drafts.compactMap { $0.repositoryPath }),
      Set(["content/posts/batch-one.md", "content/posts/batch-two.md"])
    )
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedPaths, ["config.toml"])
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedFileCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.importableRemoteArticleCount, 0)
    XCTAssertEqual(store.repositoryAutoSyncState.nonArticleRemoteChangedFileCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishProvider, .github)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishMode, .directCommit)
    XCTAssertEqual(
      store.repositoryAutoSyncState.lastRemotePublishPaths,
      [
        "content/posts/batch-one.md",
        "content/posts/batch-two.md",
      ])

    let requests = await transport.capturedRequests()
    XCTAssertEqual(
      requests.map(\.httpMethod),
      ["GET", "GET", "GET", "GET", "GET", "GET", "POST", "GET", "POST", "POST", "POST", "PATCH"])
    XCTAssertEqual(requests[0].url?.path, "/repos/owner/site")
    XCTAssertEqual(requests[1].url?.path, "/repos/owner/site/contents/content/posts/batch-one.md")
    XCTAssertEqual(requests[2].url?.path, "/repos/owner/site/contents/content/posts/batch-two.md")
    XCTAssertEqual(requests[3].url?.path, "/repos/owner/site/git/ref/heads/main")
    XCTAssertEqual(requests[9].url?.path, "/repos/owner/site/git/trees")
    XCTAssertEqual(requests[10].url?.path, "/repos/owner/site/git/commits")
    XCTAssertEqual(requests[11].url?.path, "/repos/owner/site/git/refs/heads/main")
    XCTAssertEqual(requests[6].value(forHTTPHeaderField: "Authorization"), "Bearer github-token")

    let commitBody = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try XCTUnwrap(requests[10].httpBody)) as? [String: Any])
    XCTAssertEqual(commitBody["message"] as? String, "Publish: 2 articles")
    XCTAssertEqual(commitBody["parents"] as? [String], ["base-commit-sha"])
  }

  func testBatchOnlineDirectPreflightAdoptsIdenticalDraftAndBlocksAllRemoteWritesForConflict()
    async throws
  {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let tokenStore = repositoryTokenStoreForTest()
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
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
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
        provider: .github,
        repositoryName: "owner/site",
        apiBaseURL: RepositoryProvider.github.defaultBaseURL,
        defaultBranch: "main",
        canRead: true,
        canWrite: true,
        message: "GitHub Token 具备仓库写入权限。"
      ))

    let identicalDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Identical",
      slug: "batch-identical",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum and exactly matches the already published remote Markdown."
    )
    let conflictedDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Conflict",
      slug: "batch-conflict",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum and differs from the existing remote Markdown."
    )
    store.setDrafts([identicalDraft, conflictedDraft])
    store.setSelectedDraftID(identicalDraft.id)

    let identicalPackage = store.publishingPackage(for: identicalDraft)
    let identicalContent = try XCTUnwrap(identicalPackage.markdownFile?.content)
    let identicalRemoteSHA = RemoteRepositoryPublishService().gitBlobSHA(
      for: Data(identicalContent.utf8)
    )
    await transport.replaceResponses([
      workbenchRemoteResponse(json: "{\"sha\":\"\(identicalRemoteSHA)\"}"),
      workbenchRemoteResponse(json: #"{"sha":"remote-conflict-sha"}"#),
    ])
    let initialReleaseRecordCount = store.releaseRecords.count

    let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    XCTAssertEqual(store.releaseRecords.count, initialReleaseRecordCount)
    XCTAssertEqual(store.publishActionFeedback?.status, .warning)
    XCTAssertTrue(store.publishActionMessage?.contains("远端写入前阻止") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("content/posts/batch-conflict.md") == true)
    XCTAssertTrue(store.publishActionMessage?.contains("已安全补认 1 个") == true)
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == identicalDraft.id })?.repositorySHA,
      identicalRemoteSHA
    )
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == identicalDraft.id })?.repositoryBinding?.remoteRevision,
      identicalRemoteSHA
    )
    XCTAssertEqual(
      store.publishingPackage(
        for: try XCTUnwrap(
          store.drafts.first(where: { $0.id == identicalDraft.id })
        )
      ).markdownFile?.expectedRemoteSHA,
      identicalRemoteSHA
    )
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == conflictedDraft.id })?.repositorySyncState(for: profile),
      .diverged
    )
    XCTAssertEqual(
      store.batchRemotePublishPreviewSnapshot?.remoteConflictPaths,
      ["content/posts/batch-conflict.md"]
    )

    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
    XCTAssertTrue(
      requests.allSatisfy { request in
        !["POST", "PUT", "PATCH", "DELETE"].contains(request.httpMethod ?? "")
      })
  }

  func testBatchOnlineAtomicFailureRequiresNoPartialRecovery() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-commit-sha"}}"#),
      workbenchRemoteResponse(
        json: #"{"sha":"base-commit-sha","tree":{"sha":"base-tree-sha"},"parents":[]}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"first-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(json: #"{"sha":"second-blob-sha"}"#),
      workbenchRemoteResponse(statusCode: 500, json: #"{"message":"tree creation failed"}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        statusCode: 200,
        json:
          #"{"status":"building","message":"Batch partial publish deployment is still running"}"#)
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
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum so batch partial online publishing records only completed files."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Partial Two",
      slug: "batch-partial-two",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum so the second remote write can fail after the first commit."
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
    XCTAssertEqual(
      record.changedPaths,
      ["content/posts/batch-partial-one.md", "content/posts/batch-partial-two.md"])
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

  func testBatchOnlinePublishStopsWhenAutomaticAccessCheckFails() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
    }
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(statusCode: 403, json: #"{"message":"Resource not accessible"}"#)
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

    let firstDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Permission One",
      slug: "batch-permission-one",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum so batch permission checks block before publishing."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Permission Two",
      slug: "batch-permission-two",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally longer than the preflight minimum so batch permission checks block every API call."
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)

    let initialReleaseRecordCount = store.releaseRecords.count
    let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy()
    let requests = await transport.capturedRequests()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    XCTAssertEqual(store.releaseRecords.count, initialReleaseRecordCount)
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(requests.first?.url?.path, "/repos/owner/site")
    XCTAssertFalse(requests.contains { $0.httpMethod != "GET" })
    XCTAssertTrue(store.publishActionMessage?.contains("仓库权限检查失败") == true)
  }

  func testBatchOnlinePublishRejectsFilesChangedDuringAutomaticAccessCheck() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
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
    profile.repositoryPublishStrategy = .direct
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Target Changes During Check",
      slug: "batch-target-before-check",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally long enough to prove the reviewed file list is rebound after an awaited access check."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    await store.refreshBatchPublishPlanAsync()
    let preview = try XCTUnwrap(store.batchRemotePublishPreviewSnapshot)
    let expectedTarget = RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview)

    let publishTask = Task {
      await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
        expectedChangedPaths: Set(preview.changedPaths),
        expectedTarget: expectedTarget
      )
    }
    await transport.waitUntilRequestArrives()
    draft.bodyMarkdown += "\n\nThe body changed while the permission request was waiting."
    store.setDrafts([draft])
    await transport.resume()
    let result = await publishTask.value
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertEqual(requestCount, 1)
    XCTAssertTrue(store.publishActionMessage?.contains("待发布文件已变化") == true)
  }

  func testBatchOnlinePublishRejectsRepositoryTargetChangedAfterConfirmation() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
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
    profile.repoName = "site-a"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    profile.markdownPathPattern = "content/posts/{slug}.md"
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Confirmed Target",
      slug: "confirmed-target",
      draft: false,
      bodyMarkdown:
        "This article body is intentionally long enough to verify that a reviewed batch cannot move to another repository."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    await store.refreshBatchPublishPlanAsync()
    let preview = try XCTUnwrap(store.batchRemotePublishPreviewSnapshot)
    let expectedTarget = RemoteRepositoryPublishTargetSnapshot(
      profile: profile,
      preview: preview
    )
    var laterGeneratedBranchPreview = preview
    laterGeneratedBranchPreview.branchName = "publish/batch-later"
    XCTAssertEqual(
      expectedTarget,
      RemoteRepositoryPublishTargetSnapshot(
        profile: profile,
        preview: laterGeneratedBranchPreview
      )
    )

    profile.repoName = "site-b"
    store.updateActiveProfile(profile)
    let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      expectedChangedPaths: Set(preview.changedPaths),
      expectedTarget: expectedTarget
    )
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertEqual(requestCount, 0)
    XCTAssertTrue(store.publishActionMessage?.contains("发布目标已变化") == true)
  }

  func testBatchOnlinePublishRejectsSamePathContentChangedAfterReviewBeforeNetwork() async throws {
    let rootURL = try preparedGitRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
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
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Reviewed Batch",
      slug: "reviewed-batch",
      draft: false,
      bodyMarkdown: "The original article body is long enough to pass the content checks and enter the batch review."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    await store.refreshBatchPublishPlanAsync()
    let plan = try XCTUnwrap(store.batchPublishPlan)
    let package = try XCTUnwrap(store.remotePublishPackage(for: plan))
    let preview = try XCTUnwrap(store.batchRemotePublishPreviewSnapshot)
    let review = BatchPublishReviewExpectation(plan: plan, package: package)
    XCTAssertTrue(review.matches(plan: plan, package: package))

    draft.bodyMarkdown += "\n\nThis unreviewed addition keeps the same repository path."
    store.setDrafts([draft])
    let result = await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
      expectedChangedPaths: Set(preview.changedPaths),
      expectedTarget: RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview),
      expectedReview: review
    )
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertEqual(requestCount, 0, "A stale review must be rejected before any network request")
    XCTAssertEqual(Set(store.batchRemotePublishPreviewSnapshot?.changedPaths ?? []), Set(preview.changedPaths))
    XCTAssertTrue(store.publishActionMessage?.contains("待发布文章或内容已变化") == true)
  }

  private func makePNG() throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, "public.png" as CFString, 1, nil
      )
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
  }

}
