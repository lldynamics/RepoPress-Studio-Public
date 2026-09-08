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
