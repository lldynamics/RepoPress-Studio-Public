import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class DraftLifecycleServiceTests: XCTestCase {
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

    versions = service.recordingVersion(
      of: changed,
      reason: .automatic,
      in: versions,
      at: firstDate.addingTimeInterval(DraftLifecycleService.automaticSnapshotInterval + 1)
    )
    XCTAssertEqual(versions.count, 2)
    XCTAssertEqual(versions.first?.draft.bodyMarkdown, "Second body")
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
