import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreRemotePublishingPermissionTests: WorkbenchStoreRemotePublishingTestCase {
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
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
            status: "M", path: "content/posts/online-review-preview.md", kind: .modified)
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
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
      bodyMarkdown:
        "This body is intentionally long enough to verify publishing with an invalid slug warning."
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
      bodyMarkdown:
        "This body is intentionally long enough for online publish preview token coverage."
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

  func testRemoteRepositoryPublishPreviewBlocksTokenAccessFailureWithoutReportingMissingToken()
    throws
  {
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
      bodyMarkdown:
        "This body is intentionally long enough for online publish preview Keychain failure coverage."
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
    XCTAssertTrue(
      preview.blockingIssues.contains { issue in
        issue.field == "repositoryToken"
          && issue.title == CoreL10n.text("Token 状态读取失败")
      })
    XCTAssertFalse(preview.accessSummary.contains(CoreL10n.text("未保存 Token")))
  }

  func testBatchRemoteRepositoryPublishPreviewBlocksTokenAccessFailureWithoutReportingMissingToken()
    throws
  {
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
      title: "Batch Keychain Failure",
      slug: "batch-keychain-failure",
      draft: false,
      bodyMarkdown:
        "This body is intentionally long enough for batch online publish preview Keychain failure coverage."
    )
    let secondDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Batch Keychain Failure Two",
      slug: "batch-keychain-failure-two",
      draft: false,
      bodyMarkdown:
        "This second body is intentionally long enough to make the Keychain failure preview a real batch publish plan."
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
    XCTAssertTrue(
      preview.blockingIssues.contains { issue in
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
      bodyMarkdown:
        "This body is intentionally long enough for online publish preview permission check coverage."
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
      bodyMarkdown:
        "This body is intentionally long enough for repository token permission cache invalidation coverage."
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
        json:
          #"{"full_name":"owner/site","default_branch":"main","permissions":{"push":true,"maintain":false,"admin":false}}"#
      )
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
      bodyMarkdown:
        "This body is intentionally long enough for persisted repository permission check coverage."
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let check = await store.checkRepositoryTokenAccess()

    XCTAssertEqual(check?.repositoryName, "owner/site")
    XCTAssertEqual(check?.targetBranch, "main")
    XCTAssertEqual(check?.publishStrategy, .direct)
    XCTAssertTrue(check?.canWrite == true)
    XCTAssertEqual(store.publishActionFeedback?.status, .success)
    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL),
      repositoryTokenStore: tokenStore
    )
    XCTAssertTrue(reloaded.repositoryTokenAvailability.hasToken)
    XCTAssertEqual(reloaded.activeRemoteRepositoryAccessCheck?.repositoryName, "owner/site")
    XCTAssertEqual(reloaded.activeRemoteRepositoryAccessCheck?.targetBranch, "main")
    XCTAssertEqual(reloaded.activeRemoteRepositoryAccessCheck?.publishStrategy, .direct)
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
      )
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
    defer { _ = try? tokenStore.deleteRepositoryToken(for: storeProfileForCleanup) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRepositoryReport(
      RepositoryScanReport(
        rootPath: rootURL.path,
        detectedKind: .zola,
        expectedKind: .zola,
        hasGitDirectory: true,
        contentRootExists: true,
        assetRootExists: true,
        markdownFileCount: 1,
        imageFileCount: 0,
        branchStatus: RepositoryBranchStatus(
          branchName: "production", upstreamName: "origin/production"),
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

  func testPermissionCheckDoesNotReplaceCompleteRepositoryConfigurationWithDetectedOrigin()
    async throws
  {
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [
      workbenchRemoteResponse(
        json: #"{"full_name":"detected/site","default_branch":"main","permissions":{"push":true}}"#
      )
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
    defer { _ = try? tokenStore.deleteRepositoryToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRepositoryReport(
      RepositoryScanReport(
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
    defer { _ = try? tokenStore.deleteRepositoryToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()
    store.setRepositoryReport(
      RepositoryScanReport(
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
      title: "Permission Recheck Failure",
      slug: "permission-recheck-failure",
      draft: false,
      bodyMarkdown:
        "This body proves a failed explicit recheck cannot retain an old write permission proof."
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
        preflightIssues: []
      )
    )
    XCTAssertTrue(store.remoteRepositoryPublishPreview(for: draft).canPublish)

    let check = await store.checkRepositoryTokenAccess()

    XCTAssertNil(check)
    XCTAssertNil(store.activeRemoteRepositoryAccessCheck)
    XCTAssertFalse(store.remoteRepositoryPublishPreview(for: draft).canPublish)
    XCTAssertEqual(store.publishActionFeedback?.status, .failure)
    XCTAssertNotNil(
      store.activityStatus.taskCenterItems.first { $0.kind == .gitPush }
    )
  }

  func testRepositoryPermissionCheckCancellationReleasesCheckingState() async throws {
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
    store.updateActiveProfile(profile)
    defer { try? tokenStore.deleteToken(for: profile) }
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    store.refreshRepositoryTokenAvailability()

    let check = await store.checkRepositoryTokenAccess()

    XCTAssertNil(check)
    XCTAssertFalse(store.isRemoteRepositoryChecking)
    XCTAssertNil(store.activeRemoteRepositoryAccessCheck)
    XCTAssertEqual(store.publishActionFeedback?.status, .warning)
    XCTAssertEqual(store.publishActionMessage, CoreL10n.text("仓库连接检查已中断。"))
  }

  func testRepositoryPermissionCheckDiscardsResultAfterRepositoryConfigurationChanges() async throws
  {
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
    let oldCheck = RemoteRepositoryAccessCheck(
      provider: .github,
      repositoryName: "owner/site",
      apiBaseURL: RepositoryProvider.github.defaultBaseURL,
      defaultBranch: "main",
      targetBranch: "main",
      publishStrategy: .direct,
      canRead: true,
      canWrite: true,
      message: "Old permission proof"
    )
    store.setRemoteRepositoryAccessCheck(oldCheck)
    store.publishingStore.batchRemotePublishPreviewSnapshot = RemoteRepositoryPublishPreview(
      provider: .github,
      repositoryName: "owner/site",
      mode: .directCommit,
      branchName: "main",
      targetBranch: "main",
      changedPaths: ["content/posts/old.md"],
      hasToken: true,
      accessCheck: oldCheck,
      blockingIssues: [],
      warningIssues: []
    )

    let checkTask = Task { await store.checkRepositoryTokenAccess() }
    await transport.waitUntilRequestArrives()
    XCTAssertNil(store.activeRemoteRepositoryAccessCheck)
    XCTAssertNil(store.batchRemotePublishPreviewSnapshot)
    let canPublishDuringRecheck = await store.ensureRemoteRepositoryWriteAccess(for: profile)
    XCTAssertFalse(canPublishDuringRecheck)
    XCTAssertNil(
      store.publishingStore.beginRemoteRepositoryMutation(profile: profile, store: store)
    )
    XCTAssertFalse(store.isRemoteRepositoryPublishing)
    var changedProfile = store.activeProfile
    changedProfile.repoName = "different-site"
    store.updateActiveProfile(changedProfile)
    await transport.resume()
    let check = await checkTask.value

    XCTAssertNil(check)
    XCTAssertNil(store.remoteRepositoryAccessCheck)
    XCTAssertFalse(store.isRemoteRepositoryChecking)
  }

  func testRepositoryPermissionCheckDoesNotStartDuringRemotePublish() async throws {
    let transport = CountingRemoteRepositoryTransport()
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      remoteRepositoryPublishService: RemoteRepositoryPublishService(transport: transport),
      repositoryTokenStore: repositoryTokenStoreForTest()
    )
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    store.updateActiveProfile(profile)

    let operation = try XCTUnwrap(
      store.publishingStore.beginRemoteRepositoryMutation(profile: profile, store: store)
    )
    defer {
      store.publishingStore.finishRemoteRepositoryMutation(operation, store: store)
    }

    let check = await store.checkRepositoryTokenAccess()
    let requestCount = await transport.requestCount()

    XCTAssertNil(check)
    XCTAssertFalse(store.isRemoteRepositoryChecking)
    XCTAssertEqual(requestCount, 0)
    XCTAssertEqual(
      store.publishActionMessage,
      CoreL10n.text("已有远端仓库操作正在运行，请等待完成。")
    )
  }

  func testRepositoryPermissionCheckBecomesStaleAfterBranchOrStrategyChanges() throws {
    let store = try TestWorkbenchFactory.makeStore()
    var profile = store.activeProfile
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = RepositoryProvider.github.defaultBaseURL
    profile.repoOwner = "owner"
    profile.repoName = "site"
    profile.branch = "main"
    profile.repositoryPublishStrategy = .direct
    store.updateActiveProfile(profile)
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
        provider: .github,
        repositoryName: "owner/site",
        apiBaseURL: RepositoryProvider.github.defaultBaseURL,
        defaultBranch: "main",
        targetBranch: "main",
        publishStrategy: .direct,
        canRead: true,
        canWrite: true,
        message: "Current permission proof"
      ))
    XCTAssertNotNil(store.activeRemoteRepositoryAccessCheck)

    profile.branch = "release"
    store.updateActiveProfile(profile)
    XCTAssertNil(store.activeRemoteRepositoryAccessCheck)
    XCTAssertTrue(store.hasStaleRemoteRepositoryAccessCheckForActiveProfile)

    profile.branch = "main"
    profile.repositoryPublishStrategy = .reviewRequest
    store.updateActiveProfile(profile)
    XCTAssertNil(store.activeRemoteRepositoryAccessCheck)
    XCTAssertTrue(store.hasStaleRemoteRepositoryAccessCheckForActiveProfile)
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
    store.setRemoteRepositoryAccessCheck(
      RemoteRepositoryAccessCheck(
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
      bodyMarkdown:
        "This body is intentionally long enough for stale repository owner access-check coverage."
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
      title: "Endpoint Switched",
      slug: "endpoint-switched",
      draft: false,
      bodyMarkdown:
        "This body is intentionally long enough for stale repository API endpoint access-check coverage."
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

  func testOnlinePublishRejectsAccessCheckBeforeAnyWriteRequest() async throws {
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
      bodyMarkdown:
        "This body is intentionally long enough so permission checks block before online API publishing.",
      repositoryPath: "content/posts/blocked-permission-check.md"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(store.publishingPackage(for: draft))

    let initialReleaseRecordCount = store.releaseRecords.count
    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let requests = await transport.capturedRequests()

    XCTAssertNil(result)
    XCTAssertNil(store.remoteRepositoryPublishResult)
    XCTAssertEqual(store.releaseRecords.count, initialReleaseRecordCount)
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(requests.first?.url?.path, "/repos/owner/site")
    XCTAssertFalse(requests.contains { $0.httpMethod != "GET" })
    XCTAssertNil(store.activeRemoteRepositoryAccessCheck)
    XCTAssertTrue(store.publishActionMessage?.contains("仓库权限检查失败") == true)
  }

}
