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
    XCTAssertTrue(store.performLocalRepositoryCleanup(request.id))
    XCTAssertFalse(FileManager.default.fileExists(atPath: articleURL.path))
    XCTAssertTrue(store.pendingRepositoryCleanupRequests.isEmpty)
    XCTAssertEqual(
      store.draftRepositoryCleanupRequests.first?.status,
      DraftRepositoryCleanupStatus.completed
    )

    await store.waitForPendingSave()
    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(
      reloaded.draftRepositoryCleanupRequests.first?.status,
      DraftRepositoryCleanupStatus.completed
    )
  }

  func testLocalRepositoryCleanupPreservesFileChangedAfterConfirmationPreview() throws {
    let rootURL = try temporaryDirectoryURL(prefix: "DraftRepositoryCleanupConflict")
    defer { try? FileManager.default.removeItem(at: rootURL) }
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
}
