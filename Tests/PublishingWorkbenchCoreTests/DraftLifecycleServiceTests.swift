import CryptoKit
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DraftLifecycleServiceTests: XCTestCase {
  func testBatchProcessingVersionReasonCreatesRecoverableSnapshot() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftBatchVersion")
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Before batch",
      slug: "before-batch",
      bodyMarkdown: "Original body"
    )
    store.setDrafts([draft])

    let recordedCount = store.recordVersionsBeforeBatchProcessing(draftIDs: [draft.id])

    XCTAssertEqual(recordedCount, 1)
    let version = try XCTUnwrap(store.versions(for: draft.id).first)
    XCTAssertEqual(version.reason, .beforeBatchProcessing)
    XCTAssertEqual(version.reason.displayName, "批处理前")
    XCTAssertEqual(version.draft.bodyMarkdown, "Original body")
  }

  func testAutomaticVersionsAreDeduplicatedThrottledAndRetained() {
    let service = DraftLifecycleService()
    let profileID = UUID()
    let firstDate = Date(timeIntervalSince1970: 1_000)
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: "Original",
      slug: "original",
      bodyMarkdown: "First body"
    )

    var versions = service.recordingVersion(
      of: draft,
      reason: .automatic,
      in: [],
      at: firstDate
    )
    XCTAssertEqual(versions.count, 1)

    versions = service.recordingVersion(
      of: draft,
      reason: .automatic,
      in: versions,
      at: firstDate.addingTimeInterval(60)
    )
    XCTAssertEqual(versions.count, 1)

    var changed = draft
    changed.bodyMarkdown = "Second body"
    versions = service.recordingVersion(
      of: changed,
      reason: .automatic,
      in: versions,
      at: firstDate.addingTimeInterval(120)
    )
    XCTAssertEqual(versions.count, 1)

    var substantiallyChanged = changed
    substantiallyChanged.bodyMarkdown = String(repeating: "x", count: 600)
    versions = service.recordingVersion(
      of: substantiallyChanged,
      reason: .automatic,
      in: versions,
      at: firstDate.addingTimeInterval(180)
    )
    XCTAssertEqual(versions.count, 2)
    XCTAssertEqual(versions.first?.draft.bodyMarkdown.count, 600)

    versions = service.recordingVersion(
      of: substantiallyChanged,
      reason: .automatic,
      in: versions,
      at: firstDate.addingTimeInterval(DraftLifecycleService.automaticSnapshotInterval + 1)
    )
    XCTAssertEqual(versions.count, 2)
    XCTAssertEqual(versions.first?.draft.bodyMarkdown.count, 600)
  }

  func testEditingAndRestoringVersionPersistsAcrossReload() async throws {
    let persistenceURL = try temporaryPersistenceURL(prefix: "DraftVersionPersistence")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    let original = try XCTUnwrap(store.selectedDraft)
    var changed = original
    changed.title = "Changed title"
    changed.bodyMarkdown = "Changed body"

    store.updateDraft(changed)
    let baseline = try XCTUnwrap(store.versions(for: original.id).first)
    XCTAssertEqual(baseline.draft.title, original.title)
    XCTAssertEqual(baseline.draft.bodyMarkdown, original.bodyMarkdown)

    XCTAssertTrue(store.restoreDraftVersion(baseline.id))
    XCTAssertEqual(store.selectedDraft?.title, original.title)
    XCTAssertEqual(store.selectedDraft?.bodyMarkdown, original.bodyMarkdown)
    XCTAssertTrue(store.versions(for: original.id).contains { $0.reason == .beforeRestore })

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.selectedDraft?.title, original.title)
    XCTAssertFalse(reloaded.versions(for: original.id).isEmpty)
  }

  func testStoreRestoreKeepsCurrentRepositoryTrackingAndInternalStatus() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftVersionSafeRestore")
    let original = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "旧内容",
      slug: "old-content",
      bodyMarkdown: "旧正文",
      status: .draft,
      repositoryPath: "content/old.md",
      repositorySHA: "old-sha"
    )
    store.setDrafts([original])
    store.setSelectedDraftID(original.id)

    var current = original
    current.title = "当前内容"
    current.bodyMarkdown = "当前正文"
    current.status = .published
    current.repositoryPath = "content/current.md"
    current.repositorySHA = "current-sha"
    store.updateDraft(current)
    let originalVersion = try XCTUnwrap(store.versions(for: original.id).first)

    XCTAssertTrue(store.restoreDraftVersion(originalVersion.id))

    let restored = try XCTUnwrap(store.selectedDraft)
    XCTAssertEqual(restored.title, "旧内容")
    XCTAssertEqual(restored.bodyMarkdown, "旧正文")
    XCTAssertEqual(restored.status, .published)
    XCTAssertEqual(restored.repositoryPath, "content/current.md")
    XCTAssertEqual(restored.repositorySHA, "current-sha")
    XCTAssertTrue(store.versions(for: original.id).contains { $0.reason == .beforeRestore })
  }

  func testDeletingDraftMovesItToRecycleBinAndRestoreCancelsPendingCleanup() async throws {
    let persistenceURL = try temporaryPersistenceURL(prefix: "DraftRecyclePersistence")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    let profile = store.activeProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Published article",
      slug: "published-article",
      bodyMarkdown: "Body",
      repositoryPath: "content/posts/published.md",
      repositorySHA: "abc123"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    store.deleteDraft(id: draft.id)

    XCTAssertFalse(store.drafts.contains { $0.id == draft.id })
    XCTAssertEqual(store.recycledDrafts.map(\.id), [draft.id])
    XCTAssertEqual(store.pendingRepositoryCleanupRequests.map(\.repositoryPath), ["content/posts/published.md"])
    XCTAssertEqual(store.pendingRepositoryCleanupRequests.first?.expectedRemoteSHA, "abc123")
    XCTAssertTrue(store.pendingRemoteRepositoryCleanupRequests.isEmpty)
    XCTAssertFalse(store.pendingRepositoryCleanupRequests.first?.hasRemoteCleanupIntent == true)
    XCTAssertTrue(store.versions(for: draft.id).contains { $0.reason == .beforeDeletion })

    XCTAssertTrue(store.restoreRecycledDraft(draft.id))
    XCTAssertTrue(store.drafts.contains { $0.id == draft.id })
    XCTAssertFalse(store.recycledDrafts.contains { $0.id == draft.id })
    XCTAssertTrue(store.pendingRepositoryCleanupRequests.isEmpty)

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertTrue(reloaded.drafts.contains { $0.id == draft.id })
    XCTAssertTrue(reloaded.recycledDrafts.isEmpty)
  }

  func testRecycledDraftPreservesAllAIConversationsAcrossReloadAndRestore() async throws {
    let persistenceURL = try temporaryPersistenceURL(prefix: "DraftRecycleAIConversations")
    defer { try? FileManager.default.removeItem(at: persistenceURL.deletingLastPathComponent()) }
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(persistence: persistence)
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "AI conversation article",
      slug: "ai-conversation-article",
      bodyMarkdown: "Body"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.prepareAIChat(for: draft)
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .user, content: "First conversation")
    ])
    store.setAIChatConversationTitle("First", draft: draft)
    let firstConversationID = try XCTUnwrap(
      store.activeAIChatConversationID(for: draft.id)
    )
    let secondConversation = try XCTUnwrap(
      store.startNewAIChatConversation(draft: draft)
    )
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .user, content: "Second conversation")
    ])
    store.setAIChatConversationTitle("Second", draft: draft)

    store.deleteDraft(id: draft.id)
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: persistence)
    XCTAssertEqual(reloaded.recycledDrafts.map(\.id), [draft.id])
    XCTAssertEqual(
      Set(reloaded.aiChatConversations(for: draft.id).map(\.id)),
      Set([firstConversationID, secondConversation.id])
    )
    XCTAssertEqual(
      reloaded.activeAIChatConversationID(for: draft.id),
      secondConversation.id
    )

    XCTAssertTrue(reloaded.restoreRecycledDraft(draft.id))
    let restoredDraft = try XCTUnwrap(reloaded.drafts.first { $0.id == draft.id })
    reloaded.prepareAIChat(for: restoredDraft)

    XCTAssertEqual(reloaded.aiChatConversationTitle, "Second")
    XCTAssertEqual(reloaded.aiChatMessages.map(\.content), ["Second conversation"])
    XCTAssertTrue(reloaded.selectAIChatConversation(firstConversationID))
    XCTAssertEqual(reloaded.aiChatConversationTitle, "First")
    XCTAssertEqual(reloaded.aiChatMessages.map(\.content), ["First conversation"])
  }

  func testPermanentDeletionKeepsRepositoryCleanupRequestButRemovesVersions() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftPermanentDeletion")
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Delete forever",
      slug: "delete-forever",
      repositoryPath: "content/delete-forever.md",
      repositorySHA: "remote-version"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    store.deleteDraft(id: draft.id)
    XCTAssertFalse(store.versions(for: draft.id).isEmpty)
    XCTAssertTrue(store.permanentlyDeleteRecycledDraft(draft.id))

    XCTAssertTrue(store.recycledDrafts.isEmpty)
    XCTAssertTrue(store.versions(for: draft.id).isEmpty)
    XCTAssertEqual(store.pendingRepositoryCleanupRequests.first?.draftID, draft.id)
  }

  func testLocalRepositoryCleanupUsesSafeDeleteAndPersistsResolution() async throws {
    let rootURL = try temporaryDirectoryURL(prefix: "DraftRepositoryCleanup")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let articleURL = rootURL.appendingPathComponent("content/posts/article.md")
    try FileManager.default.createDirectory(
      at: articleURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "published".write(to: articleURL, atomically: true, encoding: .utf8)
    let persistenceURL = rootURL.appendingPathComponent("workbench.json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
    }
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Article",
      slug: "article",
      repositoryPath: "content/posts/article.md"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.deleteDraft(id: draft.id)
    let request = try XCTUnwrap(store.pendingRepositoryCleanupRequests.first)

    XCTAssertEqual(store.repositoryCleanupPreview(for: request.id)?.fileDiffs.first?.status, .deleted)
    XCTAssertNotNil(request.expectedContentSHA256)
    XCTAssertNotNil(request.expectedGitBlobSHA)
    XCTAssertTrue(store.performLocalRepositoryCleanup(request.id))
    XCTAssertFalse(FileManager.default.fileExists(atPath: articleURL.path))
    XCTAssertTrue(store.pendingRepositoryCleanupRequests.isEmpty)
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first?.status,
      DraftRepositoryCleanupStatus.completed
    )
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first?.remoteStatus,
      DraftRepositoryRemoteCleanupStatus.completed
    )

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(
      reloaded.draftRepositoryCleanupRequests.first?.status,
      DraftRepositoryCleanupStatus.completed
    )
    XCTAssertEqual(
      reloaded.draftRepositoryCleanupRequests.first?.remoteStatus,
      DraftRepositoryRemoteCleanupStatus.completed
    )
  }

  func testRecycleBinRecordsGeneratedDeleteEvidenceWhenLocalMarkdownIsMissing() throws {
    let rootURL = try temporaryDirectoryURL(prefix: "DraftGeneratedDeleteEvidence")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftGeneratedDeleteEvidenceStore")
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }
    let profile = store.activeProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Generated evidence",
      slug: "generated-evidence",
      bodyMarkdown: "Body that is still available in the draft.",
      repositoryPath: "content/posts/generated-evidence.md"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    store.deleteDraft(id: draft.id)

    let request = try XCTUnwrap(store.draftRepositoryCleanupRequests.first)
    let package = PublishPackageBuilder().build(draft: draft, profile: profile)
    let generatedMarkdown = try XCTUnwrap(
      package.files.first {
        $0.kind == .markdown && $0.repositoryPath == request.repositoryPath
      }?.content
    )
    let data = Data(generatedMarkdown.utf8)
    let expectedContentSHA256 = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    var blob = Data("blob \(data.count)\0".utf8)
    blob.append(data)
    let expectedGitBlobSHA = Insecure.SHA1.hash(data: blob)
      .map { String(format: "%02x", $0) }
      .joined()

    XCTAssertEqual(request.expectedContentSHA256, expectedContentSHA256)
    XCTAssertEqual(request.expectedGitBlobSHA, expectedGitBlobSHA)
  }

  func testRemoteCleanupCompletionMakesLocallyCompletedRequestLeavePendingQueue() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftRemoteCleanupResolution")
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Resolved article",
      slug: "resolved-article",
      repositoryPath: "content/posts/resolved.md",
      repositorySHA: "known-sha"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.deleteDraft(id: draft.id)
    let request = try XCTUnwrap(store.pendingRepositoryCleanupRequests.first)
    enqueueAllRemoteCleanupRequests(in: store)
    store.publishingStore.draftRepositoryCleanupRequests[0].status = .completed

    let updatedCount = store.publishingStore.recordRemoteRepositoryCleanupResult(
      requestIDs: Set([request.id]),
      result: RemoteRepositoryPublishResult(
        provider: .github,
        mode: .directCommit,
        branchName: "main",
        targetBranch: "main",
        changedPaths: [request.repositoryPath],
        commitSHA: "delete-commit"
      )
    )

    XCTAssertEqual(updatedCount, 1)
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first?.remoteStatus,
      .completed
    )
    XCTAssertTrue(store.pendingRepositoryCleanupRequests.isEmpty)
  }

  func testReviewCleanupUsesExplicitPendingPathsAndCompletesUnchangedPaths() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftReviewPathStates")
    let firstPath = "content/posts/review-first.md"
    let secondPath = "content/posts/review-second.md"
    let firstDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Review first",
      slug: "review-first",
      repositoryPath: firstPath,
      repositorySHA: "first-sha"
    )
    let secondDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Review second",
      slug: "review-second",
      repositoryPath: secondPath,
      repositorySHA: "second-sha"
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)
    store.deleteDraft(id: firstDraft.id)
    store.deleteDraft(id: secondDraft.id)
    enqueueAllRemoteCleanupRequests(in: store)

    let requests = store.draftRepositoryCleanupRequests
    var result = RemoteRepositoryPublishResult(
      provider: .github,
      mode: .reviewRequest,
      branchName: "cleanup/review-paths",
      targetBranch: "main",
      changedPaths: [firstPath, secondPath],
      commitSHA: "review-commit",
      reviewURL: "https://github.com/owner/site/pull/7"
    )
    result.reviewPendingPaths = [firstPath]

    let updatedCount = store.publishingStore.recordRemoteRepositoryCleanupResult(
      requestIDs: Set(requests.map(\.id)),
      result: result
    )

    XCTAssertEqual(updatedCount, 2)
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first(where: { $0.repositoryPath == firstPath })?.remoteStatus,
      .reviewRequested
    )
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first(where: { $0.repositoryPath == secondPath })?.remoteStatus,
      .completed
    )
    XCTAssertNil(
      store.draftRepositoryCleanupRequests.first(where: { $0.repositoryPath == secondPath })?.remoteReviewURL
    )
  }

  func testLegacyReviewCleanupResultUsesChangedPathsForReviewFallback() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftLegacyReviewPathStates")
    let changedPath = "content/posts/legacy-review-changed.md"
    let unchangedPath = "content/posts/legacy-review-unchanged.md"
    let changedDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Legacy changed",
      slug: "legacy-review-changed",
      repositoryPath: changedPath
    )
    let unchangedDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Legacy unchanged",
      slug: "legacy-review-unchanged",
      repositoryPath: unchangedPath
    )
    store.setDrafts([changedDraft, unchangedDraft])
    store.setSelectedDraftID(changedDraft.id)
    store.deleteDraft(id: changedDraft.id)
    store.deleteDraft(id: unchangedDraft.id)
    enqueueAllRemoteCleanupRequests(in: store)

    let requests = store.draftRepositoryCleanupRequests
    let result = RemoteRepositoryPublishResult(
      provider: .github,
      mode: .reviewRequest,
      branchName: "cleanup/legacy-review",
      targetBranch: "main",
      changedPaths: [changedPath],
      commitSHA: "legacy-review-commit",
      reviewURL: "https://github.com/owner/site/pull/8"
    )
    _ = store.publishingStore.recordRemoteRepositoryCleanupResult(
      requestIDs: Set(requests.map(\.id)),
      result: result
    )

    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first(where: { $0.repositoryPath == changedPath })?.remoteStatus,
      .reviewRequested
    )
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first(where: { $0.repositoryPath == unchangedPath })?.remoteStatus,
      .completed
    )
  }

  func testReviewWithdrawalRequeuesMatchingRequestAndAllowsRecycleRestore() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftReviewWithdrawalRecovery")
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Review withdrawal",
      slug: "review-withdrawal",
      repositoryPath: "content/posts/review-withdrawal.md",
      repositorySHA: "known-sha"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.deleteDraft(id: draft.id)
    let requestID = try XCTUnwrap(store.draftRepositoryCleanupRequests.first?.id)
    let reviewURL = "https://github.com/owner/site/pull/9"
    enqueueAllRemoteCleanupRequests(in: store)
    store.publishingStore.draftRepositoryCleanupRequests[0].remoteStatus = .reviewRequested
    store.publishingStore.draftRepositoryCleanupRequests[0].remoteReviewURL = reviewURL

    let restoredCount = store.publishingStore.restoreRemoteCleanupRequestsAfterReviewWithdrawal(
      reviewURLs: [reviewURL],
      profileID: store.activeProfileID
    )

    XCTAssertEqual(restoredCount, 1)
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first(where: { $0.id == requestID })?.remoteStatus,
      .pending
    )
    XCTAssertNil(
      store.draftRepositoryCleanupRequests.first(where: { $0.id == requestID })?.remoteReviewURL
    )
    XCTAssertTrue(store.restoreRecycledDraft(draft.id))
    XCTAssertFalse(store.draftRepositoryCleanupRequests.contains { $0.id == requestID })
  }

  func testAcknowledgeClosedRemoteReviewRequeuesRequestForRestoreOrRetry() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftReviewClosedAcknowledgement")
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Closed review",
      slug: "closed-review",
      repositoryPath: "content/posts/closed-review.md"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.deleteDraft(id: draft.id)
    let request = try XCTUnwrap(store.draftRepositoryCleanupRequests.first)
    enqueueAllRemoteCleanupRequests(in: store)
    store.publishingStore.draftRepositoryCleanupRequests[0].remoteStatus = .reviewRequested
    store.publishingStore.draftRepositoryCleanupRequests[0].remoteReviewURL =
      "https://github.com/owner/site/pull/10"
    store.publishingStore.draftRepositoryCleanupRequests[0].lastRemoteErrorMessage = "stale"

    XCTAssertTrue(
      store.publishingStore.acknowledgeRemoteCleanupReviewClosed(
        requestID: request.id,
        store: store
      )
    )
    XCTAssertEqual(store.draftRepositoryCleanupRequests.first?.remoteStatus, .pending)
    XCTAssertNil(store.draftRepositoryCleanupRequests.first?.remoteReviewURL)
    XCTAssertNil(store.draftRepositoryCleanupRequests.first?.lastRemoteErrorMessage)
    XCTAssertTrue(store.publishActionMessage?.contains("恢复文章或重新发起远端下线") == true)
    XCTAssertTrue(store.restoreRecycledDraft(draft.id))
    XCTAssertTrue(store.draftRepositoryCleanupRequests.isEmpty)
    XCTAssertFalse(
      store.publishingStore.acknowledgeRemoteCleanupReviewClosed(
        requestID: request.id,
        store: store
      )
    )
  }

  func testExpectedRemoteDeletionResolvesAllMatchingRequestsForSamePath() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftSamePathDeletion")
    let sharedPath = "content/posts/shared-path.md"
    let firstDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "First shared path",
      slug: "first-shared-path",
      repositoryPath: sharedPath,
      repositorySHA: "first-sha"
    )
    let secondDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Second shared path",
      slug: "second-shared-path",
      repositoryPath: sharedPath,
      repositorySHA: "second-sha"
    )
    store.setDrafts([firstDraft, secondDraft])
    store.setSelectedDraftID(firstDraft.id)
    store.deleteDraft(id: firstDraft.id)
    store.deleteDraft(id: secondDraft.id)
    enqueueAllRemoteCleanupRequests(in: store)
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.filter { $0.repositoryPath == sharedPath }.count,
      2
    )

    let didResolve = store.publishingStore.confirmExpectedRemoteRepositoryDeletion(
      profileID: store.activeProfileID,
      repositoryPath: sharedPath
    )

    XCTAssertTrue(didResolve)
    XCTAssertTrue(
      store.draftRepositoryCleanupRequests
        .filter { $0.repositoryPath == sharedPath }
        .allSatisfy { $0.remoteStatus == .completed }
    )
  }

  func testRecycleBinSoftLimitKeepsThe101stDraft() {
    let service = DraftLifecycleService()
    var recycledDrafts: [RecycledDraft] = []
    for index in 0...DraftLifecycleService.maximumRecycledDrafts {
      let draft = ArticleDraft(
        siteProfileID: UUID(),
        title: "Recycled \(index)",
        slug: "recycled-\(index)"
      )
      recycledDrafts = service.recycling(
        draft,
        existing: recycledDrafts,
        at: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    XCTAssertEqual(recycledDrafts.count, DraftLifecycleService.maximumRecycledDrafts + 1)
    XCTAssertTrue(recycledDrafts.contains { $0.draft.title == "Recycled 0" })
    XCTAssertTrue(recycledDrafts.contains { $0.draft.title == "Recycled 100" })
  }

  func testCleanupQueueSoftLimitKeepsThe201stUnfinishedRequest() {
    let service = DraftLifecycleService()
    var requests: [DraftRepositoryCleanupRequest] = []
    for index in 0...DraftLifecycleService.maximumRepositoryCleanupRequests {
      let draft = ArticleDraft(
        siteProfileID: UUID(),
        title: "Cleanup \(index)",
        slug: "cleanup-\(index)",
        repositoryPath: "content/posts/cleanup-\(index).md"
      )
      requests = service.cleanupRequest(
        for: draft,
        existing: requests,
        at: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    XCTAssertEqual(requests.count, DraftLifecycleService.maximumRepositoryCleanupRequests + 1)
    XCTAssertTrue(requests.contains { $0.repositoryPath == "content/posts/cleanup-0.md" })
    XCTAssertTrue(requests.contains { $0.repositoryPath == "content/posts/cleanup-200.md" })
  }

  func testKeepRepositoryFileExplainsRemoteCleanupContinues() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftKeepLocalFileCopy")
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Keep local",
      slug: "keep-local",
      repositoryPath: "content/posts/keep-local.md"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.deleteDraft(id: draft.id)
    let request = try XCTUnwrap(store.pendingRepositoryCleanupRequests.first)

    XCTAssertTrue(store.keepRepositoryFile(request.id))
    XCTAssertTrue(store.publishActionMessage?.contains("未发起远端下线") == true)
    XCTAssertEqual(store.draftRepositoryCleanupRequests.first?.status, .kept)
    XCTAssertEqual(store.draftRepositoryCleanupRequests.first?.remoteStatus, .completed)
  }

  func testRestoreBlocksDraftWhileUnpublishReviewIsAwaitingMerge() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftReviewRestoreBlock")
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Review pending",
      slug: "review-pending",
      repositoryPath: "content/posts/review-pending.md",
      repositorySHA: "known-sha"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.deleteDraft(id: draft.id)
    let request = try XCTUnwrap(store.pendingRepositoryCleanupRequests.first)
    enqueueAllRemoteCleanupRequests(in: store)
    _ = store.publishingStore.recordRemoteRepositoryCleanupResult(
      requestIDs: Set([request.id]),
      result: RemoteRepositoryPublishResult(
        provider: .github,
        mode: .reviewRequest,
        branchName: "cleanup/review-pending",
        targetBranch: "main",
        changedPaths: [request.repositoryPath],
        commitSHA: "review-commit",
        reviewURL: "https://github.com/owner/site/pull/1"
      )
    )

    XCTAssertFalse(store.restoreRecycledDraft(draft.id))
    XCTAssertTrue(store.recycledDrafts.contains { $0.id == draft.id })
    XCTAssertTrue(store.publishActionMessage?.contains("下线 PR/MR") == true)
  }

  func testBatchRemotePackageNeverIncludesPendingArticleDeletion() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "DraftCleanupBatchPackage")
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Batch delete",
      slug: "batch-delete",
      repositoryPath: "content/posts/batch-delete.md",
      repositorySHA: "known-sha"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.deleteDraft(id: draft.id)
    enqueueAllRemoteCleanupRequests(in: store)
    let requests = store.pendingRemoteRepositoryCleanupRequests
    let plan = BatchPublishPlan(
      profileID: store.activeProfileID,
      siteName: store.activeProfile.name,
      items: []
    )

    XCTAssertFalse(requests.isEmpty)
    XCTAssertNil(
      store.publishingStore.remotePublishPackage(for: plan, cleanupRequests: requests)
    )
  }

  func testLocalRepositoryCleanupPreservesFileChangedAfterConfirmationPreview() throws {
    let rootURL = try temporaryDirectoryURL(prefix: "DraftRepositoryCleanupConflict")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let articleURL = rootURL.appendingPathComponent("content/posts/article.md")
    try FileManager.default.createDirectory(
      at: articleURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "published".write(to: articleURL, atomically: true, encoding: .utf8)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json"))
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
    }
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Article",
      slug: "article",
      repositoryPath: "content/posts/article.md"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.deleteDraft(id: draft.id)
    let request = try XCTUnwrap(store.pendingRepositoryCleanupRequests.first)
    let preview = try XCTUnwrap(store.repositoryCleanupPreview(for: request.id))
    try "external editor content".write(to: articleURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(store.performLocalRepositoryCleanup(request.id, preview: preview))
    XCTAssertEqual(try String(contentsOf: articleURL, encoding: .utf8), "external editor content")
    XCTAssertEqual(store.pendingRepositoryCleanupRequests.map(\.id), [request.id])
    XCTAssertTrue(store.publishActionMessage?.contains("预览后已被外部修改") == true)
  }

  func testLegacyPendingCleanupWithoutExplicitRemoteIntentIsLocalOnly() throws {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Legacy local cleanup",
      slug: "legacy-local-cleanup",
      repositoryPath: "content/posts/legacy-local-cleanup.md"
    )
    var request = DraftRepositoryCleanupRequest(
      draft: draft,
      repositoryPath: "content/posts/legacy-local-cleanup.md"
    )
    request.remoteStatus = .pending
    let data = try JSONEncoder().encode(request)

    let decoded = try JSONDecoder().decode(DraftRepositoryCleanupRequest.self, from: data)

    XCTAssertFalse(decoded.hasRemoteCleanupIntent)
    XCTAssertFalse(decoded.needsRemoteCleanup)
    XCTAssertEqual(decoded.remoteStatus, .completed)
  }

  func testLegacyReviewURLPreservesRemoteReviewSafetyLock() throws {
    let draft = ArticleDraft(
      siteProfileID: UUID(),
      title: "Legacy review",
      slug: "legacy-review",
      repositoryPath: "content/posts/legacy-review.md"
    )
    var request = DraftRepositoryCleanupRequest(
      draft: draft,
      repositoryPath: "content/posts/legacy-review.md"
    )
    request.remoteStatus = .reviewRequested
    request.remoteReviewURL = "https://github.com/owner/site/pull/42"
    let data = try JSONEncoder().encode(request)

    let decoded = try JSONDecoder().decode(DraftRepositoryCleanupRequest.self, from: data)

    XCTAssertTrue(decoded.hasRemoteCleanupIntent)
    XCTAssertTrue(decoded.isAwaitingRemoteReview)
    XCTAssertEqual(decoded.remoteReviewURL, request.remoteReviewURL)
  }

  func testCleanupPackageCountsUniqueManifestPathsAndRejectsConflictingBaselines() throws {
    let profileID = UUID()
    let firstDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "First",
      slug: "first",
      repositoryPath: "content/posts/shared.md",
      repositorySHA: "shared-sha"
    )
    let duplicateDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "Duplicate",
      slug: "duplicate",
      repositoryPath: "content/posts/shared.md",
      repositorySHA: "shared-sha"
    )
    let secondPathDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "Second path",
      slug: "second-path",
      repositoryPath: "content/posts/second.md",
      repositorySHA: "second-sha"
    )
    let enqueuedAt = Date(timeIntervalSince1970: 10)
    let requests = try [firstDraft, duplicateDraft, secondPathDraft].map { draft in
      DraftRepositoryCleanupRequest(
        draft: draft,
        repositoryPath: try XCTUnwrap(draft.repositoryPath),
        remoteEnqueuedAt: enqueuedAt,
        remoteStatus: .pending
      )
    }
    let package = try XCTUnwrap(DraftLifecycleService().cleanupPackage(for: requests))

    XCTAssertEqual(package.files.count, 2)
    XCTAssertEqual(package.title, "下线 2 篇文章")

    var conflictingDraft = duplicateDraft
    conflictingDraft.repositorySHA = "different-sha"
    let conflictingRequest = DraftRepositoryCleanupRequest(
      draft: conflictingDraft,
      repositoryPath: "content/posts/shared.md",
      remoteEnqueuedAt: enqueuedAt,
      remoteStatus: .pending
    )
    XCTAssertNil(
      DraftLifecycleService().cleanupPackage(for: [requests[0], conflictingRequest])
    )
  }

  func testLegacySnapshotDecodesEmptyLifecycleCollections() throws {
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft.empty(profile: profile)],
      releaseRecords: []
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(snapshot)) as? [String: Any]
    )
    object["formatVersion"] = 3
    object.removeValue(forKey: "draftVersions")
    object.removeValue(forKey: "recycledDrafts")
    object.removeValue(forKey: "draftRepositoryCleanupRequests")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: legacyData)

    XCTAssertTrue(decoded.draftVersions.isEmpty)
    XCTAssertTrue(decoded.recycledDrafts.isEmpty)
    XCTAssertTrue(decoded.draftRepositoryCleanupRequests.isEmpty)
    XCTAssertEqual(decoded.formatVersion, WorkbenchSnapshot.currentFormatVersion)
  }

  private func enqueueAllRemoteCleanupRequests(in store: WorkbenchStore) {
    for index in store.publishingStore.draftRepositoryCleanupRequests.indices {
      store.publishingStore.draftRepositoryCleanupRequests[index].enqueueRemoteCleanup()
    }
  }
}
