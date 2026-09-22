import Combine
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchMarkdownEditorSaveCompletionTests: XCTestCase {
  private func makeStore() -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("editor-save-completion-\(UUID().uuidString).json")
    return WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
  }

  private func makeSiteDraft(in store: WorkbenchStore, title: String) -> ArticleDraft {
    var draft = ArticleDraft.empty(profile: store.activeProfile)
    draft.title = title
    draft.repositoryPath = "content/posts/\(draft.id.uuidString).md"
    return draft
  }

  func testInitialStateDoesNotEmitACompletionEvent() {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "初始状态")
    store.setDrafts([draft])

    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testTrackedSiteDraftPendingToSavedEmitsExactlyOneCompletionEvent() {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "项目草稿")
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    store.siteDraftFileSaveStates[draft.id] = .pending(repositoryPath: "content/posts/test.md")
    store.siteDraftFileSaveStates[draft.id] = .saved(
      repositoryPath: "content/posts/test.md",
      savedAt: Date()
    )
    XCTAssertEqual(facade.saveCompletionRevision, 1)

    store.siteDraftFileSaveStates[draft.id] = .saved(
      repositoryPath: "content/posts/test.md",
      savedAt: Date().addingTimeInterval(1)
    )
    XCTAssertEqual(facade.saveCompletionRevision, 1)
  }

  func testTrackedSiteDraftPendingToFailureDoesNotEmitACompletionEvent() {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "失败草稿")
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    store.siteDraftFileSaveStates[draft.id] = .pending(repositoryPath: "content/posts/failure.md")
    store.siteDraftFileSaveStates[draft.id] = .failed(
      repositoryPath: "content/posts/failure.md",
      message: "写入失败"
    )

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testProjectSaveFailureRetainsItsReasonAndOffersRetry() throws {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "失败草稿")
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )
    store.siteDraftFileSaveStates[draft.id] = .failed(
      repositoryPath: "content/posts/failure.md",
      message: "磁盘空间不足"
    )

    let failure = try XCTUnwrap(facade.saveFailure)
    XCTAssertEqual(failure.scope, .project)
    XCTAssertEqual(failure.message, "磁盘空间不足")
    XCTAssertTrue(failure.canRetry)
  }

  func testApplicationSaveFailureIsKeptSeparateFromProjectWriteFailures() throws {
    let store = makeStore()
    let draft = ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )
    store.recordPersistenceSaveFailed(
      NSError(domain: "SaveFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法写入工作台"])
    )

    let failure = try XCTUnwrap(facade.saveFailure)
    XCTAssertEqual(failure.scope, .application)
    XCTAssertEqual(failure.message, "无法写入工作台")
    XCTAssertTrue(failure.canRetry)
    XCTAssertEqual(facade.shortSaveStatus, "保存到软件失败")
  }

  func testVisibleSaveStatusDistinguishesProjectConflictAndFollowsDraftSwitch() {
    let store = makeStore()
    let first = makeSiteDraft(in: store, title: "冲突文章")
    let second = makeSiteDraft(in: store, title: "已保存文章")
    store.setDrafts([first, second])
    store.siteDraftFileSaveStates[first.id] = .failed(repositoryPath: first.repositoryPath!, message: "文件已变化")
    store.siteDraftFileSaveFailures[first.id] = SiteDraftFileSaveFailure(
      draftID: first.id, profile: store.activeProfile, repositoryPath: first.repositoryPath!,
      error: SiteDraftFileStoreError.projectFileChangedExternally(first.repositoryPath!)
    )
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(store: store, draftID: first.id)
    XCTAssertTrue(facade.hasProjectFileConflict)
    XCTAssertEqual(facade.shortSaveStatus, "项目文件冲突")
    facade.trackDraft(second.id)
    XCTAssertFalse(facade.hasProjectFileConflict)
    XCTAssertEqual(facade.shortSaveStatus, "已保存到项目")
  }

  func testMissingDraftSaveFailureDoesNotOfferRetry() throws {
    let store = makeStore()
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: UUID()
    )
    store.recordPersistenceSaveFailed(
      NSError(domain: "SaveFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法写入工作台"])
    )

    let failure = try XCTUnwrap(facade.saveFailure)
    XCTAssertEqual(failure.scope, .application)
    XCTAssertFalse(failure.canRetry)
  }

  func testUnrelatedSiteDraftTransitionsDoNotEmitACompletionEvent() {
    let store = makeStore()
    let trackedDraft = makeSiteDraft(in: store, title: "当前草稿")
    let otherDraft = makeSiteDraft(in: store, title: "其他草稿")
    store.setDrafts([trackedDraft, otherDraft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: trackedDraft.id
    )

    store.siteDraftFileSaveStates[otherDraft.id] = .pending(
      repositoryPath: "content/posts/other.md")
    store.siteDraftFileSaveStates[otherDraft.id] = .saved(
      repositoryPath: "content/posts/other.md",
      savedAt: Date()
    )

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testGlobalPersistenceSuccessDoesNotEmitForASiteDraft() {
    let store = makeStore()
    let draft = makeSiteDraft(in: store, title: "项目草稿")
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    store.persistenceStore.markUnsavedChanges()
    store.persistenceStore.recordSuccess()

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testTrackingACleanDraftResetsTheSaveBaselineWithoutAnEvent() {
    let store = makeStore()
    let dirtyDraft = makeSiteDraft(in: store, title: "正在保存")
    let cleanDraft = makeSiteDraft(in: store, title: "已保存")
    store.setDrafts([dirtyDraft, cleanDraft])
    store.siteDraftFileSaveStates[dirtyDraft.id] = .pending(
      repositoryPath: "content/posts/dirty.md")
    store.siteDraftFileSaveStates[cleanDraft.id] = .saved(
      repositoryPath: "content/posts/clean.md",
      savedAt: Date()
    )
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: dirtyDraft.id
    )

    facade.trackDraft(cleanDraft.id)

    XCTAssertEqual(facade.saveCompletionRevision, 0)
  }

  func testGeneralDraftGlobalPendingToSavedEmitsOneCompletionEvent() {
    let store = makeStore()
    let draft = ArticleDraft.emptyGeneralDraft(editingProfile: store.activeProfile)
    store.setDrafts([draft])
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )

    store.persistenceStore.markUnsavedChanges()
    store.persistenceStore.recordSuccess()

    XCTAssertEqual(facade.saveCompletionRevision, 1)
  }

  func testExplicitProjectRetryFlushesNewestBodyAndKeepsClickedArticleAfterTrackingChanges()
    async throws
  {
    let fixture = try await makeProjectFixture(prefix: "editor-save-retry")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let first = try await fixture.addDraft(slug: "retry-first", body: "初始正文")

    fixture.store.createDraft()
    var second = try XCTUnwrap(fixture.store.selectedDraft)
    second.slug = "retry-second"
    second.title = "不应被重试写入的文章"
    second.bodyMarkdown = "第二篇只保存在软件中的正文"
    fixture.store.updateDraft(second)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    XCTAssertNil(second.repositoryPath)

    try FileManager.default.removeItem(at: fixture.repositoryURL.appendingPathComponent(".git"))
    var failedDraft = try XCTUnwrap(fixture.store.drafts.first { $0.id == first.id })
    failedDraft.bodyMarkdown = "Git 根目录丢失时未写入的正文"
    fixture.store.updateDraft(failedDraft)
    let didWriteWithoutGitMarker = await fixture.store.writeSiteDraftToProject(
      draftID: first.id)
    XCTAssertFalse(didWriteWithoutGitMarker)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    guard case .some(.failed) = fixture.store.siteDraftFileSaveStates[first.id] else {
      return XCTFail("Expected the missing Git marker to produce a real project-file failure")
    }
    XCTAssertNotNil(fixture.store.siteDraftFileSaveFailures[first.id])

    try FileManager.default.createDirectory(
      at: fixture.repositoryURL.appendingPathComponent(".git"),
      withIntermediateDirectories: true
    )
    let newestBody = "重试必须提交的最新编辑器正文"
    let staged = try XCTUnwrap(
      fixture.store.stageDraftBody(
        newestBody,
        for: first.id,
        baseRevision: fixture.store.draftBodyEditorBuffer(for: first.id).revision
      )
    )
    XCTAssertTrue(staged.wasAccepted)

    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: fixture.store,
      draftID: first.id
    )
    let saved = expectation(description: "clicked article is saved by the explicit retry")
    let saveStateObservation = fixture.store.$siteDraftFileSaveStates
      .dropFirst()
      .filter { states in
        guard case .some(.saved) = states[first.id] else { return false }
        return true
      }
      .prefix(1)
      .sink { _ in saved.fulfill() }
    defer { saveStateObservation.cancel() }

    facade.retrySave()
    facade.trackDraft(second.id)

    await fulfillment(of: [saved], timeout: 5)
    await fixture.store.waitForPendingSiteDraftFileWrites()

    XCTAssertTrue(
      try String(contentsOf: fixture.documentURL(for: first), encoding: .utf8)
        .contains(newestBody)
    )
    XCTAssertNil(fixture.store.siteDraftFileSaveFailures[first.id])
    XCTAssertNil(fixture.store.drafts.first { $0.id == second.id }?.repositoryPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.documentURL(for: second).path))
    XCTAssertNil(fixture.store.siteDraftFileSaveStates[second.id])
    await fixture.store.waitForPendingSave()
  }

  func testExplicitProjectRetryRetainsExternalFileConflictProtection() async throws {
    let fixture = try await makeProjectFixture(prefix: "editor-save-retry-conflict")
    defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
    let draft = try await fixture.addDraft(slug: "conflict", body: "初始正文")
    let documentURL = fixture.documentURL(for: draft)

    var localDraft = draft
    localDraft.bodyMarkdown = "应用内尚未写入的修改"
    fixture.store.updateDraft(localDraft)
    var externalDraft = draft
    externalDraft.bodyMarkdown = "外部编辑器写入的内容"
    let externalDocument = FrontMatterRenderer().renderDocument(
      draft: externalDraft,
      profile: fixture.store.activeProfile
    )
    try externalDocument.write(to: documentURL, atomically: true, encoding: .utf8)

    let didWriteOverExternalDocument = await fixture.store.writeSiteDraftToProject(
      draftID: draft.id)
    XCTAssertFalse(didWriteOverExternalDocument)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    let facade = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: fixture.store,
      draftID: draft.id
    )
    XCTAssertTrue(facade.hasProjectFileConflict)

    let retryFailed = expectation(description: "explicit retry keeps the external conflict")
    let saveStateObservation = fixture.store.$siteDraftFileSaveStates
      .dropFirst()
      .filter { states in
        guard case .some(.failed) = states[draft.id] else { return false }
        return true
      }
      .prefix(1)
      .sink { _ in retryFailed.fulfill() }
    defer { saveStateObservation.cancel() }

    facade.retrySave()

    await fulfillment(of: [retryFailed], timeout: 5)
    await fixture.store.waitForPendingSiteDraftFileWrites()

    XCTAssertEqual(try String(contentsOf: documentURL, encoding: .utf8), externalDocument)
    XCTAssertTrue(facade.hasProjectFileConflict)
    XCTAssertEqual(facade.saveFailure?.scope, .project)
    guard case .some(.failed) = fixture.store.siteDraftFileSaveStates[draft.id] else {
      return XCTFail("Expected external conflict to remain observable after explicit retry")
    }
    await fixture.store.waitForPendingSave()
  }

  @MainActor
  private struct ProjectFixture {
    let baseURL: URL
    let repositoryURL: URL
    let store: WorkbenchStore

    func documentURL(for draft: ArticleDraft) -> URL {
      repositoryURL.appendingPathComponent(
        draft.repositoryPath ?? store.activeProfile.markdownPath(for: draft)
      )
    }

    func addDraft(slug: String, body: String) async throws -> ArticleDraft {
      store.createDraft()
      var draft = try XCTUnwrap(store.selectedDraft)
      draft.slug = slug
      draft.title = slug
      draft.bodyMarkdown = body
      store.updateDraft(draft)
      let didWrite = await store.writeSiteDraftToProject(draftID: draft.id)
      XCTAssertTrue(didWrite)
      await store.waitForPendingSiteDraftFileWrites()
      return try XCTUnwrap(store.drafts.first { $0.id == draft.id })
    }
  }

  private func makeProjectFixture(prefix: String) async throws -> ProjectFixture {
    let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(prefix)-\(UUID().uuidString)"
    )
    let repositoryURL = baseURL.appendingPathComponent("repository")
    try FileManager.default.createDirectory(
      at: repositoryURL.appendingPathComponent(".git"),
      withIntermediateDirectories: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: baseURL.appendingPathComponent("app-data/workbench.json")
      ),
      safeMode: true
    )
    store.updateActiveProfile {
      $0.localRepositoryRootPath = repositoryURL.path
      $0.markdownPathPattern = "content/posts/{slug}.md"
    }
    await store.waitForPendingSave()
    return ProjectFixture(baseURL: baseURL, repositoryURL: repositoryURL, store: store)
  }
}
