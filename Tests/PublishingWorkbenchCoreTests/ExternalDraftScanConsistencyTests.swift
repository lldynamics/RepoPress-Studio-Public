import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class ExternalDraftScanConsistencyTests: XCTestCase {
  func testSaveAfterScanReadCannotBeRevertedByOldSnapshot() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.store
    let id = fixture.draft.id
    let newBody = "# Note\n\nSaved while scanning\n"
    let summary = await store.scanExternalDraftFolder { folder in
      let oldFiles = try ExternalDraftFolderService().scan(rootURL: folder)
      await MainActor.run {
        guard var draft = store.draft(for: id) else { return XCTFail("missing draft") }
        draft.bodyMarkdown = newBody
        store.updateDraft(draft)
        XCTAssertTrue(store.flushPendingChanges())
      }
      return oldFiles
    }
    XCTAssertNil(summary.errorMessage)
    XCTAssertEqual(summary.refreshedCount, 0)
    XCTAssertEqual(summary.conflictCount, 0)
    XCTAssertEqual(store.draft(for: id)?.bodyMarkdown, newBody)
    XCTAssertEqual(store.draftBodyEditorBuffer(for: id).bodyMarkdown, newBody)
    XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), newBody)
    let rescanned = await store.scanExternalDraftFolder()
    XCTAssertEqual(rescanned.refreshedCount, 0)
    XCTAssertFalse(store.externalDraftConflicts.contains(id))
  }

  func testEditDuringScanIsNotMisreportedAsExternalConflict() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.store
    let id = fixture.draft.id
    let newBody = "# Note\n\nNew local edit\n"
    let summary = await store.scanExternalDraftFolder { folder in
      let oldFiles = try ExternalDraftFolderService().scan(rootURL: folder)
      await MainActor.run {
        guard var draft = store.draft(for: id) else { return XCTFail("missing draft") }
        draft.bodyMarkdown = newBody
        store.updateDraft(draft)
      }
      return oldFiles
    }
    XCTAssertEqual(summary.conflictCount, 0)
    XCTAssertEqual(store.draft(for: id)?.bodyMarkdown, newBody)
    XCTAssertTrue(store.flushPendingChanges())
    XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), newBody)
  }

  func testDeletedDraftIsNotReimportedFromInFlightScan() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = fixture.store
    let id = fixture.draft.id
    let summary = await store.scanExternalDraftFolder { folder in
      let oldFiles = try ExternalDraftFolderService().scan(rootURL: folder)
      await MainActor.run { store.deleteDraft(id: id) }
      return oldFiles
    }
    XCTAssertEqual(summary.addedCount, 0)
    XCTAssertNil(store.draft(for: id))
    XCTAssertFalse(store.drafts.contains { $0.externalDraftSource?.relativePath == "note.md" })
  }

  private func makeFixture() async throws -> (
    root: URL, file: URL, store: WorkbenchStore, draft: ArticleDraft
  ) {
    let root = try TestWorkbenchFactory.temporaryDirectoryURL(prefix: "external-scan-consistency")
    let folder = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("note.md")
    try Data("# Note\n\nInitial body\n".utf8).write(to: file)
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workbench.json"))
    )
    XCTAssertTrue(store.connectExternalDraftFolder(folder))
    let summary = await store.scanExternalDraftFolder()
    XCTAssertEqual(summary.addedCount, 1)
    let draft = try XCTUnwrap(store.drafts.first { $0.externalDraftSource != nil })
    store.synchronizeDraftBodyEditorBuffer(with: draft)
    return (root, file, store, draft)
  }
}
