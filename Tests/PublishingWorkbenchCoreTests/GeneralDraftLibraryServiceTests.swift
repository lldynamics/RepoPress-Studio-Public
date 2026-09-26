import Foundation
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class GeneralDraftLibraryServiceTests: XCTestCase {
  func testStoreCopiesArticleToAnotherPublishingSite() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let source = try XCTUnwrap(store.selectedDraft)
    let targetProfile = store.createProfile(named: "项目网站")

    let copied = try XCTUnwrap(store.copyDraft(source.id, toProfileID: targetProfile.id))

    XCTAssertEqual(copied.siteProfileID, targetProfile.id)
    XCTAssertEqual(copied.status, .draft)
    XCTAssertNil(copied.repositoryPath)
    XCTAssertNil(copied.repositorySHA)
    XCTAssertEqual(store.selectedDraftID, copied.id)
    XCTAssertEqual(store.selectedSection, .writing)
  }
}

final class ExternalDraftSourceCodingTests: XCTestCase {
  func testDecodesSnapshotsWrittenBeforeDetachedFolderSupport() throws {
    let mappingID = UUID()
    let payload = Data(
      """
      {
        "mappingID": "\(mappingID.uuidString)",
        "relativePath": "inbox/idea.md",
        "importedTitle": "旧来源",
        "importedFingerprint": "fingerprint"
      }
      """.utf8
    )

    let source = try JSONDecoder().decode(ExternalDraftSource.self, from: payload)

    XCTAssertEqual(source.mappingID, mappingID)
    XCTAssertNil(source.detachedFolderPath)
    XCTAssertFalse(source.isDetached)
  }
}

@MainActor
final class ExternalDraftFolderSyncTests: XCTestCase {
  func testFolderScanRefreshWritebackAndConflictPreserveBothVersions() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("external-draft-sync-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent("vault-output", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("note.md")
    try Data("# First\n\nSource body\n".utf8).write(to: file)

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: root.appendingPathComponent("workspace.json"))
    )
    XCTAssertTrue(store.connectExternalDraftFolder(folder))
    let first = await store.scanExternalDraftFolder()
    XCTAssertNil(first.errorMessage)
    XCTAssertEqual(first.addedCount, 1)
    let imported = try XCTUnwrap(store.drafts.first { $0.externalDraftSource != nil })
    XCTAssertTrue(imported.isGeneralDraft)
    XCTAssertEqual(imported.title, "First")
    store.synchronizeDraftBodyEditorBuffer(with: imported)
    let originalEditorRevision = store.draftBodyEditorBuffer(for: imported.id).revision
    XCTAssertTrue(store.connectExternalDraftFolder(folder))
    let repeatedScan = await store.scanExternalDraftFolder()
    XCTAssertEqual(repeatedScan.addedCount, 0)

    try Data("# First\n\nChanged outside first\n".utf8).write(to: file)
    let firstRefresh = await store.scanExternalDraftFolder()
    XCTAssertEqual(firstRefresh.refreshedCount, 1)
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: imported.id).bodyMarkdown,
      "# First\n\nChanged outside first\n"
    )
    XCTAssertGreaterThan(
      store.draftBodyEditorBuffer(for: imported.id).revision, originalEditorRevision)
    var staleEditor = imported
    staleEditor.summary = "Edited metadata"
    XCTAssertTrue(store.updateDraftFromEditor(staleEditor))
    XCTAssertEqual(
      store.draft(for: imported.id)?.bodyMarkdown,
      "# First\n\nChanged outside first\n"
    )

    try Data("# Second\n\nChanged outside\n".utf8).write(to: file)
    let refreshed = await store.scanExternalDraftFolder()
    XCTAssertEqual(refreshed.refreshedCount, 1)
    XCTAssertEqual(store.draft(for: imported.id)?.title, "Second")

    var edited = try XCTUnwrap(store.draft(for: imported.id))
    edited.bodyMarkdown = "# Second\n\nChanged in RepoPress\n"
    store.updateDraft(edited)
    XCTAssertTrue(store.flushPendingChanges())
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited.bodyMarkdown)

    edited = try XCTUnwrap(store.draft(for: imported.id))
    edited.bodyMarkdown = "# Second\n\nLocal unsaved change\n"
    store.updateDraft(edited)
    try Data("# Third\n\nConcurrent outside change\n".utf8).write(to: file)
    let conflict = await store.scanExternalDraftFolder()
    XCTAssertEqual(conflict.conflictCount, 1)
    XCTAssertEqual(store.draft(for: imported.id)?.bodyMarkdown, edited.bodyMarkdown)
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8),
      "# Third\n\nConcurrent outside change\n"
    )
    XCTAssertTrue(store.externalDraftConflicts.contains(imported.id))
    let resolved = await store.keepLocalCopyAndAcceptExternal(draftID: imported.id)
    XCTAssertTrue(resolved)
    XCTAssertEqual(
      store.draft(for: imported.id)?.bodyMarkdown,
      "# Third\n\nConcurrent outside change\n"
    )
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: imported.id).bodyMarkdown,
      "# Third\n\nConcurrent outside change\n"
    )
    XCTAssertTrue(
      store.drafts.contains {
        $0.externalDraftSource == nil && $0.bodyMarkdown == edited.bodyMarkdown
          && $0.title.contains("本地冲突副本")
      })
    XCTAssertEqual(store.pendingExternalDraftWriteCount, 0)

    store.disconnectExternalDraftFolder()
    XCTAssertNil(store.draft(for: imported.id)?.externalDraftSource)
    XCTAssertEqual(
      store.draft(for: imported.id)?.bodyMarkdown,
      "# Third\n\nConcurrent outside change\n"
    )
  }
}
