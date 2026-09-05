import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreRemotePublishingExternalFreshnessTests:
  WorkbenchStoreRemotePublishingTestCase
{
  func testPublishingRefreshFetchesExternalCommitWithoutChangingLocalHEADOrWorktree() async throws {
    let localRoot = try preparedGitRepositoryRoot(prefix: "ExternalFreshnessLocal")
    let bareRoot = try temporaryDirectoryURL(prefix: "ExternalFreshnessBare")
    let externalRoot = try temporaryDirectoryURL(prefix: "ExternalFreshnessWriter")
    defer {
      try? FileManager.default.removeItem(at: localRoot)
      try? FileManager.default.removeItem(at: bareRoot)
      try? FileManager.default.removeItem(at: externalRoot)
    }

    try git(["init", "--bare"], rootURL: bareRoot)
    try git(["remote", "add", "origin", bareRoot.path], rootURL: localRoot)
    try git(["push", "-u", "origin", "main"], rootURL: localRoot)
    try git(
      ["clone", "--branch", "main", bareRoot.path, externalRoot.path],
      rootURL: bareRoot.deletingLastPathComponent()
    )
    try git(["config", "user.email", "external@example.com"], rootURL: externalRoot)
    try git(["config", "user.name", "External Writer"], rootURL: externalRoot)
    try FileManager.default.createDirectory(
      at: externalRoot.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    let externalArticle = externalRoot.appendingPathComponent("content/posts/external.md")
    try "external update\n".write(to: externalArticle, atomically: true, encoding: .utf8)
    try git(["add", "content/posts/external.md"], rootURL: externalRoot)
    try git(["commit", "-m", "External publish"], rootURL: externalRoot)
    try git(["push", "origin", "main"], rootURL: externalRoot)

    let localHEAD = try git(["rev-parse", "HEAD"], rootURL: localRoot)
    let externalHEAD = try git(["rev-parse", "HEAD"], rootURL: externalRoot)
    let store = WorkbenchStore(persistence: try TestWorkbenchFactory.persistence())
    var profile = store.activeProfile
    profile.rememberLocalRepositoryRoot(localRoot)
    store.updateActiveProfile(profile)

    let result = await store.refreshRepositoryStateForPublishing()

    XCTAssertEqual(result?.status, .succeeded)
    XCTAssertEqual(try git(["rev-parse", "HEAD"], rootURL: localRoot), localHEAD)
    XCTAssertEqual(try git(["rev-parse", "origin/main"], rootURL: localRoot), externalHEAD)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: localRoot.appendingPathComponent("content/posts/external.md").path
      )
    )
  }

  func testSelectedPreparationStopsBeforeWriteWhenAnotherToolChangedRemoteFile() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "ExternalFreshnessConflict")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
    let store = try makeConfiguredStore(rootURL: rootURL, transport: transport)
    let draft = makeDraft(profile: store.activeProfile, slug: "external-conflict")
    var boundDraft = draft
    boundDraft.confirmRepositoryBinding(
      profile: store.activeProfile,
      repositoryPath: "content/posts/external-conflict.md",
      remoteRevision: "old-remote-sha",
      renderedContentDigest: boundDraft.renderedRepositoryContentDigest(
        profile: store.activeProfile)
    )
    let package = PublishPackageBuilder().build(draft: boundDraft, profile: store.activeProfile)
    let remoteContent = Data("edited by another tool".utf8).base64EncodedString()
    await transport.replaceResponses([
      workbenchRemoteResponse(
        json: #"{"sha":"new-remote-sha","content":"\#(remoteContent)","encoding":"base64"}"#
      ),
      workbenchRemoteResponse(
        json: #"{"content":"b2xkLWJhc2U=","encoding":"base64"}"#
      ),
    ])
    store.setDrafts([boundDraft])
    store.setSelectedDraftID(boundDraft.id)

    let result = await store.prepareSelectedDraftOnlinePublish(draftID: boundDraft.id)
    let requests = await transport.capturedRequests()

    XCTAssertFalse(result)
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
    XCTAssertEqual(store.releaseRecords.count, 0)
    XCTAssertEqual(
      store.remoteRepositoryConflictSession?.publishScope,
      .selectedDraft(boundDraft.id)
    )
    XCTAssertEqual(
      store.remoteRepositoryConflictSession?.conflicts.map(\.repositoryPath),
      [package.markdownPath]
    )
    XCTAssertEqual(store.publishActionFeedback?.status, .warning)
    XCTAssertTrue(store.publishActionMessage?.contains("其他软件已更新远端") == true)
  }

  func testSelectedPreparationAdoptsIdenticalRemoteContentWithoutWrite() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "ExternalFreshnessAdoption")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = RemoteRepositoryPublishService()
    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
    let store = try makeConfiguredStore(rootURL: rootURL, transport: transport)
    let draft = makeDraft(profile: store.activeProfile, slug: "external-adoption")
    let package = PublishPackageBuilder().build(draft: draft, profile: store.activeProfile)
    let content = Data((package.markdownFile?.content ?? "").utf8)
    let remoteSHA = service.gitBlobSHA(for: content)
    await transport.replaceResponses([
      workbenchRemoteResponse(
        json:
          #"{"sha":"\#(remoteSHA)","content":"\#(content.base64EncodedString())","encoding":"base64"}"#
      )
    ])
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let result = await store.prepareSelectedDraftOnlinePublish(draftID: draft.id)
    let requests = await transport.capturedRequests()
    let refreshedDraft = try XCTUnwrap(store.drafts.first)

    XCTAssertTrue(result)
    XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    XCTAssertEqual(refreshedDraft.repositorySHA, remoteSHA)
    XCTAssertEqual(refreshedDraft.repositoryBinding?.remoteRevision, remoteSHA)
    XCTAssertNil(store.remoteRepositoryConflictSession)
    XCTAssertTrue(store.releaseRecords.isEmpty)
    XCTAssertEqual(store.publishActionFeedback?.status, .success)
  }

  func testDirectPublishRefreshesConflictWhenRemoteChangesAfterPreflight() async throws {
    let rootURL = try preparedGitRepositoryRoot(prefix: "ExternalFreshnessSecondRace")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let transport = SequencedWorkbenchRemoteRepositoryTransport(responses: [])
    let store = try makeConfiguredStore(rootURL: rootURL, transport: transport)
    var draft = makeDraft(profile: store.activeProfile, slug: "external-second-race")
    draft.confirmRepositoryBinding(
      profile: store.activeProfile,
      repositoryPath: "content/posts/external-second-race.md",
      remoteRevision: "old-remote-sha",
      renderedContentDigest: draft.renderedRepositoryContentDigest(profile: store.activeProfile)
    )
    let package = PublishPackageBuilder().build(draft: draft, profile: store.activeProfile)
    let localContent = Data((package.markdownFile?.content ?? "").utf8).base64EncodedString()
    let remoteContent = Data("edited after confirmation".utf8).base64EncodedString()
    await transport.replaceResponses([
      workbenchRemoteResponse(
        json: #"{"sha":"old-remote-sha","content":"\#(localContent)","encoding":"base64"}"#
      ),
      workbenchRemoteResponse(
        json: #"{"sha":"new-remote-sha","content":"\#(remoteContent)","encoding":"base64"}"#
      ),
      workbenchRemoteResponse(
        json: #"{"sha":"new-remote-sha","content":"\#(remoteContent)","encoding":"base64"}"#
      ),
      workbenchRemoteResponse(
        json: #"{"sha":"old-remote-sha","content":"\#(localContent)","encoding":"base64"}"#
      ),
    ])
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setPublishPackage(package)

    let result = await store.publishSelectedDraftOnlineUsingPreferredStrategy()
    let requests = await transport.capturedRequests()

    XCTAssertNil(result)
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "GET", "GET"])
    XCTAssertTrue(store.releaseRecords.isEmpty)
    XCTAssertEqual(
      store.remoteRepositoryConflictSession?.publishScope,
      .selectedDraft(draft.id)
    )
    XCTAssertEqual(
      store.remoteRepositoryConflictSession?.conflicts.map(\.repositoryPath),
      [package.markdownPath]
    )
    XCTAssertEqual(store.publishActionFeedback?.status, .warning)
    XCTAssertTrue(store.publishActionMessage?.contains("确认发布后远端又发生了变化") == true)
  }

  private func makeConfiguredStore(
    rootURL: URL,
    transport: SequencedWorkbenchRemoteRepositoryTransport
  ) throws -> WorkbenchStore {
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
    try tokenStore.saveRepositoryToken("github-token", for: profile)
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
    return store
  }

  private func makeDraft(profile: SiteProfile, slug: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id,
      title: "External freshness (slug)",
      slug: slug,
      draft: false,
      bodyMarkdown: "This article is long enough to pass the online publish readiness checks."
    )
  }
}
