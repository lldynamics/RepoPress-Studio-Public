import Combine
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchSiteDraftFlushErrorTests: XCTestCase {
  func testSynchronousFlushReportsPathAndReasonAndRetryClearsError() async throws {
    let fixture = try await makeBoundSiteDraft(prefix: "flush-error-sync")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    var draft = try XCTUnwrap(fixture.store.selectedDraft)
    draft.bodyMarkdown = "应用内尚未写入的新正文"
    fixture.store.updateDraft(draft)

    let externalDocument = "---\ntitle: 外部编辑\n---\n\n外部文件内容\n"
    try externalDocument.write(to: fixture.destinationURL, atomically: true, encoding: .utf8)
    XCTAssertFalse(fixture.store.flushPendingChanges())

    XCTAssertEqual(
      try String(contentsOf: fixture.destinationURL, encoding: .utf8), externalDocument)
    XCTAssertEqual(try XCTUnwrap(fixture.store.selectedDraft).bodyMarkdown, "应用内尚未写入的新正文")
    XCTAssertTrue(
      fixture.store.siteDraftFileSaveFailureGroups.first?.details.contains(fixture.repositoryPath)
        == true)
    XCTAssertTrue(fixture.store.lastSaveError?.contains("其他软件或 Git 修改") == true)

    // Re-establish the trusted baseline without asking the app to overwrite
    // the externally edited document, then retry the pending app content.
    try fixture.initialDocument.write(to: fixture.destinationURL, atomically: true, encoding: .utf8)
    XCTAssertTrue(fixture.store.flushPendingChanges())
    XCTAssertNil(fixture.store.lastSaveError)
    XCTAssertTrue(
      try String(contentsOf: fixture.destinationURL, encoding: .utf8).contains("应用内尚未写入的新正文"))
  }

  func testSuccessfulAsyncRetryClearsPreviousFlushError() async throws {
    let fixture = try await makeBoundSiteDraft(prefix: "flush-error-async")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    var draft = try XCTUnwrap(fixture.store.selectedDraft)
    draft.bodyMarkdown = "第一次应用内修改"
    fixture.store.updateDraft(draft)
    let externalDocument = "---\ntitle: 外部编辑\n---\n\n异步重试前的外部内容\n"
    try externalDocument.write(to: fixture.destinationURL, atomically: true, encoding: .utf8)
    XCTAssertFalse(fixture.store.flushPendingChanges())
    XCTAssertNotNil(fixture.store.lastSaveError)
    XCTAssertEqual(
      try String(contentsOf: fixture.destinationURL, encoding: .utf8), externalDocument)

    try fixture.initialDocument.write(to: fixture.destinationURL, atomically: true, encoding: .utf8)
    draft = try XCTUnwrap(fixture.store.selectedDraft)
    draft.bodyMarkdown = "异步重试成功后的正文"
    fixture.store.updateDraft(draft)
    await fixture.store.waitForPendingSiteDraftFileWrites()
    // Known conflicts remain paused until the user explicitly retries.
    XCTAssertNotNil(fixture.store.lastSaveError)
    let didRetry = await fixture.store.retryPendingProjectFileWrites()
    XCTAssertTrue(didRetry)

    XCTAssertNil(fixture.store.lastSaveError)
    XCTAssertTrue(
      try String(contentsOf: fixture.destinationURL, encoding: .utf8).contains("异步重试成功后的正文"))
    await fixture.store.waitForPendingSave()
  }

  func testFlushWithoutRepositoryRootRemainsSafeAndHasNoSaveError() async throws {
    let fixture = try await makeBoundSiteDraft(prefix: "flush-error-no-root")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let store = fixture.store
    store.updateActiveProfile { $0.localRepositoryRootPath = "" }
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.bodyMarkdown = "仍保存在软件中"
    store.updateDraft(draft)

    XCTAssertTrue(store.flushPendingChanges())
    guard case .failed = store.siteDraftFileSaveStates[draft.id] else {
      return XCTFail("Expected a nonblocking missing-project failure for the bound draft")
    }
    XCTAssertNil(store.lastSaveError)
    XCTAssertEqual(try XCTUnwrap(store.selectedDraft).bodyMarkdown, "仍保存在软件中")
    XCTAssertEqual(
      try String(contentsOf: fixture.destinationURL, encoding: .utf8), fixture.initialDocument
    )
  }

  func testRemovingFailedWriteClearsErrorAndNotifiesActivityStatus() async throws {
    let fixture = try await makeBoundSiteDraft(prefix: "flush-error-observation")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let store = fixture.store
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.bodyMarkdown = "保留的应用内修改"
    store.updateDraft(draft)
    let externalDocument = "外部编辑器的修改"
    try externalDocument.write(to: fixture.destinationURL, atomically: true, encoding: .utf8)
    XCTAssertFalse(store.flushPendingChanges())

    let facade = WorkbenchActivityStatusFacade(store: store)
    XCTAssertNotNil(facade.lastSaveError)
    var changes = 0
    let observation = facade.objectWillChange.sink { changes += 1 }
    defer { observation.cancel() }
    store.cancelSiteDraftFileAutosave(for: draft.id)

    XCTAssertGreaterThan(changes, 0)
    XCTAssertNil(facade.lastSaveError)
    XCTAssertEqual(store.selectedDraft?.bodyMarkdown, draft.bodyMarkdown)
    XCTAssertEqual(
      try String(contentsOf: fixture.destinationURL, encoding: .utf8), externalDocument)
  }

  private struct BoundSiteDraftFixture {
    let rootURL: URL
    let store: WorkbenchStore
    let destinationURL: URL
    let repositoryPath: String
    let initialDocument: String
  }

  private func makeBoundSiteDraft(prefix: String) async throws -> BoundSiteDraftFixture {
    let rootURL = try temporaryDirectory(prefix: prefix)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: rootURL.appendingPathComponent("app-data/workbench.json"))
    )
    store.updateActiveProfile { profile in
      profile.localRepositoryRootPath = rootURL.path
      profile.markdownPathPattern = "content/posts/{slug}.md"
    }
    store.createDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "站点文件写入错误"
    draft.slug = prefix
    draft.bodyMarkdown = "初始正文"
    store.updateDraft(draft)
    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    let didWrite = await store.writeSiteDraftToProject(draftID: draftID)
    XCTAssertTrue(didWrite)
    await store.waitForPendingSiteDraftFileWrites()
    await store.waitForPendingSave()

    draft = try XCTUnwrap(store.selectedDraft)
    let repositoryPath = try XCTUnwrap(draft.repositoryPath)
    let destinationURL = rootURL.appendingPathComponent(repositoryPath)
    let initialDocument = try String(contentsOf: destinationURL, encoding: .utf8)
    return BoundSiteDraftFixture(
      rootURL: rootURL,
      store: store,
      destinationURL: destinationURL,
      repositoryPath: repositoryPath,
      initialDocument: initialDocument
    )
  }

  private func temporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: url.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: false
    )
    return url
  }
}

@MainActor
final class WorkbenchExplicitDraftSaveTests: XCTestCase {
  func testImmediateSaveWritesOnlyCurrentBoundDraftAndDoesNotRetryOtherFailure() async throws {
    let rootURL = try makeRepositoryRoot(prefix: "explicit-draft-save-scoped")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workspace.json")))
    store.updateActiveProfile {
      $0.localRepositoryRootPath = rootURL.path
      $0.markdownPathPattern = "content/posts/{slug}.md"
    }

    let current = try await makeBoundDraft(slug: "current", body: "当前初始正文", in: store, rootURL: rootURL)
    let other = try await makeBoundDraft(slug: "other", body: "其他初始正文", in: store, rootURL: rootURL)

    var failedOther = try XCTUnwrap(store.draft(for: other.id))
    failedOther.bodyMarkdown = "其他草稿尚未写入的正文"
    store.updateDraft(failedOther)
    let externallyChangedOther = "---\ntitle: 外部版本\n---\n\n其他草稿的外部版本\n"
    try externallyChangedOther.write(to: other.fileURL, atomically: true, encoding: .utf8)
    XCTAssertFalse(store.flushPendingSiteDraftFileWrites(targetDraftID: other.id))
    guard case .failed = store.siteDraftFileSaveStates[other.id] else {
      return XCTFail("Expected the unrelated draft to retain its failed write")
    }

    let currentBuffer = store.draftBodyEditorBuffer(for: current.id)
    _ = store.stageDraftBody(
      "当前草稿的立即保存正文",
      for: current.id,
      baseRevision: currentBuffer.revision
    )
    let otherBuffer = store.draftBodyEditorBuffer(for: other.id)
    _ = store.stageDraftBody(
      "其他窗口仍在编辑的内容", for: other.id, baseRevision: otherBuffer.revision)

    XCTAssertTrue(store.saveDraftImmediately(draftID: current.id))
    XCTAssertTrue(
      try String(contentsOf: current.fileURL, encoding: .utf8)
        .contains("当前草稿的立即保存正文"))
    XCTAssertEqual(try String(contentsOf: other.fileURL, encoding: .utf8), externallyChangedOther)
    XCTAssertTrue(store.draftBodyEditorBuffer(for: other.id).isDirty)
    XCTAssertEqual(store.draft(for: other.id)?.bodyMarkdown, failedOther.bodyMarkdown)
    let currentStatus = WorkbenchMarkdownEditorSaveStatusFeatureFacade(store: store, draftID: current.id)
    XCTAssertNil(currentStatus.saveFailure)
    XCTAssertEqual(currentStatus.shortSaveStatus, "已保存到项目")
    guard case .failed = store.siteDraftFileSaveStates[other.id] else {
      return XCTFail("The scoped save must not retry another draft's failed write")
    }
  }

  func testImmediateSaveLeavesUnboundDraftLocalAndPersistsItsEditorBuffer() throws {
    let rootURL = try makeRepositoryRoot(prefix: "explicit-draft-save-unbound")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workspace.json"))
    let store = WorkbenchStore(persistence: persistence)
    store.createDraft()
    let draft = try XCTUnwrap(store.selectedDraft)
    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    _ = store.stageDraftBody(
      "未绑定草稿只保存到工作台快照",
      for: draft.id,
      baseRevision: buffer.revision
    )

    XCTAssertTrue(store.saveDraftImmediately(draftID: draft.id))
    XCTAssertNil(store.draft(for: draft.id)?.repositoryPath)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("content/posts").path))
    XCTAssertEqual(
      try persistence.loadPrimarySnapshot().drafts.first(where: { $0.id == draft.id })?.bodyMarkdown,
      "未绑定草稿只保存到工作台快照"
    )
  }

  func testImmediateSavePreservesExternalConflictAndReturnsFalse() async throws {
    let rootURL = try makeRepositoryRoot(prefix: "explicit-draft-save-external-conflict")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let folderURL = rootURL.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    let fileURL = folderURL.appendingPathComponent("idea.md")
    try "# 初始\n\n外部初始正文\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let persistence = WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workspace.json"))
    let store = WorkbenchStore(persistence: persistence)
    XCTAssertTrue(store.connectExternalDraftFolder(folderURL))
    let scan = await store.scanExternalDraftFolder()
    XCTAssertEqual(scan.addedCount, 1)
    let draft = try XCTUnwrap(store.drafts.first { $0.externalDraftSource != nil })
    var edited = draft
    edited.bodyMarkdown = "# 初始\n\n软件中的修改\n"
    store.updateDraft(edited)
    let externalContents = "# 外部版本\n\n其他编辑器中的修改\n"
    try externalContents.write(to: fileURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(store.saveDraftImmediately(draftID: draft.id))
    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), externalContents)
    XCTAssertTrue(store.externalDraftConflicts.contains(draft.id))
    XCTAssertEqual(
      try persistence.loadPrimarySnapshot().drafts.first(where: { $0.id == draft.id })?.bodyMarkdown,
      edited.bodyMarkdown
    )
  }

  func testImmediateSaveRejectsMissingDraft() throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "explicit-draft-save-missing")

    XCTAssertFalse(store.saveDraftImmediately(draftID: UUID()))
  }

  func testImmediateSaveReportsCurrentProjectConflictWithoutOverwritingDisk() async throws {
    let rootURL = try makeRepositoryRoot(prefix: "explicit-draft-save-project-conflict")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workspace.json"))
    let store = WorkbenchStore(persistence: persistence)
    store.updateActiveProfile {
      $0.localRepositoryRootPath = rootURL.path
      $0.markdownPathPattern = "content/posts/{slug}.md"
    }
    let current = try await makeBoundDraft(slug: "current", body: "initial", in: store, rootURL: rootURL)
    let buffer = store.draftBodyEditorBuffer(for: current.id)
    _ = store.stageDraftBody("local edits", for: current.id, baseRevision: buffer.revision)
    let externalText = "External editor changed this file"
    try externalText.write(to: current.fileURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(store.saveDraftImmediately(draftID: current.id))
    XCTAssertEqual(try String(contentsOf: current.fileURL, encoding: .utf8), externalText)
    XCTAssertEqual(store.siteDraftFileSaveFailures[current.id]?.reason, .externalChange)
    XCTAssertEqual(
      try persistence.loadPrimarySnapshot().drafts.first(where: { $0.id == current.id })?.bodyMarkdown,
      "local edits"
    )
  }

  private func makeBoundDraft(
    slug: String,
    body: String,
    in store: WorkbenchStore,
    rootURL: URL
  ) async throws -> (id: UUID, fileURL: URL) {
    store.createDraft()
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = slug
    draft.slug = slug
    draft.bodyMarkdown = body
    store.updateDraft(draft)
    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    let didWrite = await store.writeSiteDraftToProject(draftID: draftID)
    XCTAssertTrue(didWrite)
    await store.waitForPendingSiteDraftFileWrites()
    let saved = try XCTUnwrap(store.draft(for: draftID))
    return (
      draftID,
      rootURL.appendingPathComponent(try XCTUnwrap(saved.repositoryPath))
    )
  }

  private func makeRepositoryRoot(prefix: String) throws -> URL {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: prefix)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: false
    )
    return rootURL
  }
}
