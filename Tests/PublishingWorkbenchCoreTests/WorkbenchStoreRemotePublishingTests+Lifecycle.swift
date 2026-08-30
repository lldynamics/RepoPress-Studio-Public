import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreRemotePublishingLifecycleTests: WorkbenchStoreRemotePublishingTestCase {
  func testDirectRemoteWebsiteDraftSyncDoesNotMarkWorkflowPublished() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Website draft",
      slug: "website-draft",
      draft: true,
      bodyMarkdown: "This remains a website draft after explicit remote synchronization.",
      status: .ready
    )
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: "content/posts/website-draft.md",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let contentUpdatedAt = draft.updatedAt
    store.setDrafts([draft])

    store.markDraftsAsPublishedIfDirectRemoteCommit(
      mode: .directCommit,
      draftIDs: [draft.id]
    )
    store.publishingStore.confirmDirectRemotePublishLifecycle(
      packages: [package],
      result: RemoteRepositoryPublishResult(
        provider: .github,
        mode: .directCommit,
        branchName: "main",
        targetBranch: "main",
        changedPaths: [package.markdownPath],
        commitSHA: "commit-sha",
        remoteVersionsByPath: [package.markdownPath: "remote-sha"]
      )
    )

    let synchronized = try XCTUnwrap(store.drafts.first)
    XCTAssertTrue(synchronized.draft)
    XCTAssertEqual(synchronized.status, .ready)
    XCTAssertEqual(synchronized.repositorySyncState(for: profile), .synced)
    XCTAssertEqual(synchronized.updatedAt, contentUpdatedAt)
  }

  func testDirectRemotePublishNoOpPreservesKnownMarkdownVersionWhenLegacyResultIsSparse() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    store.updateActiveProfile(profile)
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "No-op baseline",
      slug: "no-op-baseline",
      bodyMarkdown: "The remote document already contains these exact bytes.",
      repositoryPath: "content/posts/no-op-baseline.md"
    )
    draft.confirmRepositoryBinding(
      profile: profile,
      repositoryPath: "content/posts/no-op-baseline.md",
      remoteRevision: "known-markdown-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let contentUpdatedAt = draft.updatedAt
    store.setDrafts([draft])

    store.publishingStore.confirmDirectRemotePublishLifecycle(
      packages: [package],
      result: RemoteRepositoryPublishResult(
        provider: .github,
        mode: .directCommit,
        branchName: "main",
        targetBranch: "main",
        changedPaths: [],
        commitSHA: nil,
        remoteVersionsByPath: nil
      )
    )

    let confirmed = try XCTUnwrap(store.drafts.first)
    XCTAssertEqual(confirmed.repositorySHA, "known-markdown-sha")
    XCTAssertEqual(confirmed.updatedAt, contentUpdatedAt)
    XCTAssertEqual(confirmed.repositoryBinding?.remoteRevision, "known-markdown-sha")
    XCTAssertEqual(
      PublishPackageBuilder().build(draft: confirmed, profile: profile).markdownFile?
        .expectedRemoteSHA,
      "known-markdown-sha"
    )
  }

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
    let contentUpdatedAt = draft.updatedAt
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
    XCTAssertEqual(confirmedDraft.updatedAt, contentUpdatedAt)
    let nextPackage = PublishPackageBuilder().build(draft: confirmedDraft, profile: profile)
    XCTAssertEqual(nextPackage.files.first { $0.kind == .image }?.expectedRemoteSHA, "image-sha")
  }

  func testOneStepUnpublishDeletesRemoteAndLocalMarkdownButKeepsImages() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "OneStepUnpublish")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let articleURL = rootURL.appendingPathComponent("content/posts/unpublish.md")
    let imageURL = rootURL.appendingPathComponent("static/images/shared.png")
    try FileManager.default.createDirectory(
      at: articleURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: imageURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "published markdown".write(to: articleURL, atomically: true, encoding: .utf8)
    try Data([1, 2, 3]).write(to: imageURL)

    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json: #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true}}"#),
      workbenchRemoteResponse(json: #"{"sha":"known-sha"}"#),
      workbenchRemoteResponse(json: #"{"content":null,"commit":{"sha":"delete-commit"}}"#),
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
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer { _ = try? tokenStore.deleteRepositoryToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Unpublish",
      slug: "unpublish",
      bodyMarkdown: "published markdown",
      repositoryPath: "content/posts/unpublish.md",
      repositorySHA: "known-sha"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let result = await store.unpublishDraft(id: draft.id)

    XCTAssertEqual(result?.commitSHA, "delete-commit")
    XCTAssertTrue(store.drafts.isEmpty)
    XCTAssertEqual(store.recycledDrafts.map(\.id), [draft.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: articleURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
    XCTAssertTrue(store.pendingRepositoryCleanupRequests.isEmpty)
    XCTAssertEqual(store.draftRepositoryCleanupRequests.first?.status, .completed)
    XCTAssertEqual(store.draftRepositoryCleanupRequests.first?.remoteStatus, .completed)
    XCTAssertNotNil(store.draftRepositoryCleanupRequests.first?.remoteEnqueuedAt)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "DELETE"])
  }

  func testUnpublishRequestUsesItsOwnProfileWhenAnotherSiteIsActive() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json:
          #"{"full_name":"owner/secondary-site","default_branch":"main","permissions":{"push":true}}"#
      ),
      workbenchRemoteResponse(json: #"{"sha":"known-sha"}"#),
      workbenchRemoteResponse(json: #"{"content":null,"commit":{"sha":"delete-commit"}}"#),
    ])
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "CrossProfileUnpublish"),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: tokenStore
    )
    let originalProfileID = store.activeProfileID
    let secondaryProfile = store.createProfile(named: "Secondary")
    var configuredSecondary = store.activeProfile
    configuredSecondary.repositoryProvider = .github
    configuredSecondary.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    configuredSecondary.repoOwner = "owner"
    configuredSecondary.repoName = "secondary-site"
    configuredSecondary.branch = "main"
    configuredSecondary.repositoryPublishStrategy = .direct
    store.updateActiveProfile(configuredSecondary)
    store.selectProfile(originalProfileID)
    defer { _ = try? tokenStore.deleteRepositoryToken(for: configuredSecondary) }
    try tokenStore.saveRepositoryToken("secondary-token", for: configuredSecondary)

    let draft = ArticleDraft(
      siteProfileID: secondaryProfile.id,
      title: "Secondary article",
      slug: "secondary-article",
      bodyMarkdown: "Published on the secondary site.",
      repositoryPath: "content/posts/secondary-article.md",
      repositorySHA: "known-sha"
    )
    store.setDrafts([draft])

    let result = await store.unpublishDraft(id: draft.id)

    XCTAssertEqual(store.activeProfileID, originalProfileID)
    XCTAssertEqual(result?.commitSHA, "delete-commit")
    XCTAssertEqual(store.draftRepositoryCleanupRequests.first?.remoteStatus, .completed)
    let requests = await transport.capturedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "DELETE"])
    XCTAssertTrue(
      requests.allSatisfy { request in
        request.url?.path.contains("/repos/owner/secondary-site") == true
      })
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
      bodyMarkdown:
        "This body is intentionally long enough so online API publish conflict handling is driven by upstream changes.",
      repositoryPath: "content/posts/online-direct-conflict.md"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setRepositoryReport(
      RepositoryScanReport(
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
          RepositoryChangedFile(
            status: "M", path: "content/posts/online-direct-conflict.md", kind: .modified)
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
    XCTAssertTrue(
      store.publishActionMessage?.contains("content/posts/online-direct-conflict.md") == true)

    let cachedPreview = try XCTUnwrap(store.remotePublishPreviewSnapshot)
    XCTAssertEqual(cachedPreview.changedPaths, preview.changedPaths)
    XCTAssertEqual(cachedPreview.remoteConflictPaths, preview.remoteConflictPaths)
  }

  func testOnlinePublishWithoutLocalProjectDoesNotCallRemoteTransport() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "RemoteRequiresLocalProject"),
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
    profile.localRepositoryRootPath = ""
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
      title: "Local checkout required",
      slug: "local-checkout-required",
      draft: false,
      bodyMarkdown:
        "This body is intentionally long enough so only project materialization blocks the remote call."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let requestCount = await transport.requestCount()

    XCTAssertNil(result)
    XCTAssertEqual(requestCount, 0)
    XCTAssertNil(store.drafts.first?.repositoryPath)
    XCTAssertNil(store.drafts.first?.repositoryBinding)
  }

  func testOnlinePublishRefreshesStaleProjectMarkdownBeforeFirstRemoteRequest() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "RemoteRefreshesStaleProjectFile")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let repositoryPath = "content/posts/refresh-stale-project.md"
    let markdownURL = rootURL.appendingPathComponent(repositoryPath)
    try FileManager.default.createDirectory(
      at: markdownURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "STALE_DISK_SENTINEL\n".write(to: markdownURL, atomically: true, encoding: .utf8)

    let transport = SequencedWorkbenchRemoteRepositoryTransport(
      responses: [
        workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
        workbenchRemoteResponse(
          json:
            #"{"content":{"path":"content/posts/refresh-stale-project.md","sha":"fresh-remote-sha"},"commit":{"sha":"fresh-commit-sha"}}"#
        ),
      ],
      inspectedLocalFileURL: markdownURL
    )
    let tokenStore = repositoryTokenStoreForTest()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(prefix: "RemoteRefreshesStaleProjectFile"),
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

    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Refresh stale project file",
      slug: "refresh-stale-project",
      draft: false,
      bodyMarkdown:
        "This current payload must replace stale project bytes before any remote request begins.",
      status: .ready,
      repositoryPath: repositoryPath
    )
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: repositoryPath,
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: profile)
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let localContentsAtFirstRequest = await transport.inspectedLocalFileContentsAtFirstRequest()

    XCTAssertEqual(result?.commitSHA, "fresh-commit-sha")
    XCTAssertTrue(
      localContentsAtFirstRequest?.contains("This current payload must replace") == true)
    XCTAssertFalse(localContentsAtFirstRequest?.contains("STALE_DISK_SENTINEL") == true)
    XCTAssertEqual(
      ArticleDraft.repositoryDocumentDigest(try String(contentsOf: markdownURL, encoding: .utf8)),
      store.drafts.first?.repositoryBinding?.projectFileContentDigest
    )
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

  func testOnlineDirectPublishAutomaticallyChecksAccessThenPublishes() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "OnlineDirectLocalProject")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let publishTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json: #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(
        json:
          #"{"content":{"path":"content/posts/online-direct-success.md","sha":"online-direct-content-sha"},"commit":{"sha":"online-direct-commit"}}"#
      ),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        statusCode: 200,
        json:
          #"{"status":"ok","message":"Site is live","branch":"main","commit_sha":"online-direct-commit"}"#
      )
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
    profile.rememberLocalRepositoryRoot(rootURL)
    store.updateActiveProfile(profile)
    defer {
      try? tokenStore.deleteToken(for: profile)
    }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
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
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("content/posts/online-direct-success.md").path
      ))
    XCTAssertEqual(store.drafts.first?.repositorySyncState(for: profile), .synced)
    let record = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(record.kind, .remoteDirectCommit)
    XCTAssertEqual(store.deploymentStatusSnapshot(for: record)?.level, .success)
    XCTAssertEqual(store.releaseLedger.entries.first?.status, .succeeded)
    XCTAssertEqual(
      store.repositoryAutoSyncState.remoteChangedPaths, ["content/posts/remote-only.md"])
    XCTAssertEqual(store.repositoryAutoSyncState.remoteChangedFileCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.importableRemoteArticleCount, 1)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishProvider, .github)
    XCTAssertEqual(store.repositoryAutoSyncState.lastRemotePublishMode, .directCommit)
    XCTAssertEqual(
      store.repositoryAutoSyncState.lastRemotePublishPaths,
      ["content/posts/online-direct-success.md"])
    XCTAssertTrue(store.repositoryAutoSyncState.message.contains("已从远端同步队列移除 1 个同路径项"))
    XCTAssertTrue(store.repositoryAutoSyncReviewMarkdown.contains("## 最近线上写入"))
    XCTAssertTrue(
      store.repositoryAutoSyncReviewMarkdown.contains("- content/posts/online-direct-success.md"))

    let publishRequests = await publishTransport.capturedRequests()
    XCTAssertEqual(publishRequests.map(\.httpMethod), ["GET", "GET", "PUT"])
    XCTAssertEqual(publishRequests.first?.url?.path, "/repos/owner/site")
    XCTAssertEqual(publishRequests.filter { $0.httpMethod != "GET" }.count, 1)
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertEqual(deploymentRequests.count, 1)
    XCTAssertEqual(deploymentRequests.first?.url?.absoluteString, "https://status.example.com/site")
  }

  func testOnlineReviewPublishWaitsForMergeWithoutDeploymentStatusRefresh() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "OnlineReviewLocalProject")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let publishTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(json: #"{"object":{"sha":"base-sha"}}"#),
      workbenchRemoteResponse(
        json: #"{"ref":"refs/heads/publish/online-review-20260829","object":{"sha":"base-sha"}}"#),
      workbenchRemoteResponse(statusCode: 404, json: #"{"message":"not found"}"#),
      workbenchRemoteResponse(
        json:
          #"{"content":{"path":"content/posts/online-review.md"},"commit":{"sha":"review-commit-sha"}}"#
      ),
      workbenchRemoteResponse(json: #"{"html_url":"https://github.com/owner/site/pull/12"}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        statusCode: 200, json: #"{"status":"ok","message":"Main site is still live"}"#)
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

    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Online Review",
      date: fixedDate(),
      slug: "online-review",
      draft: false,
      bodyMarkdown:
        "This body is intentionally long enough for online review publishing to create a PR without deployment verification."
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
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("content/posts/online-review.md").path
      ))
    XCTAssertEqual(store.drafts.first?.repositorySyncState(for: profile), .awaitingReview)

    let publishRequests = await publishTransport.capturedRequests()
    XCTAssertEqual(publishRequests.map(\.httpMethod), ["GET", "POST", "GET", "PUT", "POST"])
    let deploymentRequests = await deploymentTransport.capturedRequests()
    XCTAssertEqual(deploymentRequests.count, 0)
  }

  func testRemoteRollbackCreatesRollbackRecordFromReleaseHistory() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json:
          #"{"sha":"published-sha","tree":{"sha":"published-tree"},"parents":[{"sha":"parent-sha"}]}"#
      ),
      workbenchRemoteResponse(
        json:
          #"{"sha":"parent-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"grandparent-sha"}]}"#
      ),
      workbenchRemoteResponse(json: #"{"object":{"sha":"published-sha"}}"#),
      workbenchRemoteResponse(
        json:
          #"{"sha":"rollback-sha","tree":{"sha":"parent-tree"},"parents":[{"sha":"published-sha"}]}"#
      ),
      workbenchRemoteResponse(json: #"{"object":{"sha":"rollback-sha"}}"#),
    ])
    let deploymentTransport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        statusCode: 200,
        json:
          #"{"status":"ok","message":"Rollback commit is live","branch":"main","commit_sha":"rollback-sha"}"#
      )
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
    XCTAssertEqual(
      deploymentRequests.first?.url?.absoluteString, "https://status.example.com/rollback")
  }

  func testRemoteReviewWithdrawalCreatesReleaseRecordFromReleaseHistory() async throws {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json: #"{"state":"closed","html_url":"https://github.com/owner/site/pull/9"}"#)
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
    XCTAssertEqual(
      store.remoteRepositoryReviewWithdrawalResult?.reviewURL,
      "https://github.com/owner/site/pull/9")
    XCTAssertEqual(store.publishActionMessage, CoreL10n.format("线上 Review 已撤回：#%@", "9"))
    let withdrawalRecord = try XCTUnwrap(store.releaseRecords.first)
    XCTAssertEqual(withdrawalRecord.kind, .remoteReviewWithdrawal)
    XCTAssertEqual(withdrawalRecord.reviewURL, "https://github.com/owner/site/pull/9")
    XCTAssertEqual(withdrawalRecord.branchName, "publish/review-me")
    XCTAssertEqual(withdrawalRecord.targetBranch, "main")
    XCTAssertEqual(store.releaseRecords.dropFirst().first?.id, original.id)
    XCTAssertEqual(store.activeProfileReleaseLedger.entries.first?.status, .reviewWithdrawn)

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
        json:
          #"{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/pulls/pulls#create-a-pull-request"}"#
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
    XCTAssertTrue(
      store.releaseRecords.first?.summary.contains("Pull requests: Read and write") == true)
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

}
